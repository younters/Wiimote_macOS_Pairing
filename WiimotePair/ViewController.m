// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ViewController.h"

#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>

static const CFIndex kWiimoteInputBufferSize = 64;
static NSString* const kGCSyntheticDeviceKey = @"GCSyntheticDevice";

typedef NS_ENUM(NSInteger, WiimoteConnectionState) {
    WiimoteConnectionStatePreparing,
    WiimoteConnectionStateSearching,
    WiimoteConnectionStateConnecting,
    WiimoteConnectionStateConnected,
    WiimoteConnectionStateInUseByAnotherApp,
    WiimoteConnectionStateDisconnected,
    WiimoteConnectionStateFailed,
};

static NSString* WiimoteIOReturnDescription(IOReturn error) {
    const char* message = mach_error_string(error);
    if (message == NULL) {
        message = "unknown error";
    }

    return [NSString stringWithFormat:@"0x%08x (%s)", (unsigned int)error, message];
}

static NSString* NormalizedBluetoothAddress(NSString* address) {
    if (address == nil) {
        return nil;
    }

    NSString* normalized = [[address stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
    return normalized;
}

static NSNumber* HIDNumberProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return nil;
    }
    return (__bridge NSNumber*)value;
}

static NSString* HIDStringProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return nil;
    }
    return (__bridge NSString*)value;
}

@interface ViewController ()
- (void)hidDeviceMatched:(IOHIDDeviceRef)device result:(IOReturn)result;
- (void)hidDeviceRemoved:(IOHIDDeviceRef)device result:(IOReturn)result;
- (void)hidInputReportFromDevice:(IOHIDDeviceRef)device
                          result:(IOReturn)result
                        reportID:(uint32_t)reportID
                          length:(CFIndex)length;
@end

static void HIDDeviceMatchedCallback(void* context, IOReturn result, void* sender, IOHIDDeviceRef device) {
    @autoreleasepool {
        ViewController* controller = (__bridge ViewController*)context;
        [controller hidDeviceMatched:device result:result];
    }
}

static void HIDDeviceRemovedCallback(void* context, IOReturn result, void* sender, IOHIDDeviceRef device) {
    @autoreleasepool {
        ViewController* controller = (__bridge ViewController*)context;
        [controller hidDeviceRemoved:device result:result];
    }
}

static void HIDInputReportCallback(void* context,
                                   IOReturn result,
                                   void* sender,
                                   IOHIDReportType type,
                                   uint32_t reportID,
                                   uint8_t* report,
                                   CFIndex reportLength) {
    @autoreleasepool {
        ViewController* controller = (__bridge ViewController*)context;
        [controller hidInputReportFromDevice:(IOHIDDeviceRef)sender
                                      result:result
                                    reportID:reportID
                                      length:reportLength];
    }
}

@implementation ViewController {
    CBCentralManager* _centralManager;
    IOBluetoothDeviceInquiry* _deviceInquiry;
    IOBluetoothDevicePair* _devicePair;
    IOBluetoothDevice* _pairedDevice;
    IOBluetoothUserNotification* _disconnectNotification;

    IOHIDManagerRef _hidManager;
    IOHIDDeviceRef _hidDevice;
    uint8_t* _hidInputBuffer;
    NSTimer* _hidConnectionTimer;
    BOOL _receivedHIDReport;
    BOOL _experimentalMode;

    NSImageView* _stateImageView;
    NSProgressIndicator* _progressIndicator;
    NSTextField* _stateTitleField;
    NSTextField* _stateMessageField;
    NSTextField* _bluetoothStatusField;
    NSTextField* _hidStatusField;
    NSButton* _pairAnotherButton;
    NSButton* _detailsButton;
    NSScrollView* _detailsScrollView;
    NSTextView* _detailsTextView;
    NSMutableArray<NSString*>* _diagnosticEntries;
    NSMutableSet<NSString*>* _completedRemoteAddresses;
    BOOL _detailsVisible;
    WiimoteConnectionState _connectionState;
    BOOL _hidOwnedByAnotherApp;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _experimentalMode = YES;
    _hidInputBuffer = calloc(kWiimoteInputBufferSize, sizeof(uint8_t));

    _diagnosticEntries = [NSMutableArray array];
    _completedRemoteAddresses = [NSMutableSet set];
    [self buildInterface];
    [self transitionToState:WiimoteConnectionStatePreparing];
    [self setConnectionStatus:@"Bluetooth: preparing physical HID monitor…"];
    [self setupHIDManager];
}

- (void)viewDidAppear {
    [super viewDidAppear];

    self.view.window.contentMinSize = NSMakeSize(520, 330);
    self.view.window.contentMaxSize = NSMakeSize(720, 540);

    if (_centralManager == nil) {
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
}

- (void)showAlertWithTitle:(NSString*)title text:(NSString*)text callback:(void (^)(void))callback {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = text;
    [alert addButtonWithTitle:@"OK"];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        callback();
    }];
}

- (void)showPairingResultAlertWithTitle:(NSString*)title text:(NSString*)text {
    [self showAlertWithTitle:title text:text callback:^{
        if (self->_pairedDevice == nil && self->_deviceInquiry != nil) {
            [self->_deviceInquiry clearFoundDevices];
            [self->_deviceInquiry start];
        }
    }];
}

- (void)showFatalErrorAlertWithTitle:(NSString*)title text:(NSString*)text {
    [self showAlertWithTitle:title text:text callback:^{
        [NSApp terminate:self];
    }];
}

- (NSTextField*)labelWithText:(NSString*)text font:(NSFont*)font color:(NSColor*)color {
    NSTextField* label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildInterface {
    _stateImageView = [[NSImageView alloc] init];
    _stateImageView.image = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right"
                                      accessibilityDescription:@"Searching"];
    _stateImageView.contentTintColor = NSColor.controlAccentColor;
    _stateImageView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:38 weight:NSFontWeightRegular];
    _stateImageView.translatesAutoresizingMaskIntoConstraints = NO;

    _progressIndicator = [[NSProgressIndicator alloc] init];
    _progressIndicator.style = NSProgressIndicatorStyleSpinning;
    _progressIndicator.controlSize = NSControlSizeSmall;
    _progressIndicator.indeterminate = YES;
    _progressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressIndicator startAnimation:self];

    _stateTitleField = [self labelWithText:@"Preparing Bluetooth…"
                                      font:[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold]
                                     color:NSColor.labelColor];
    _stateMessageField = [self labelWithText:@"WiimotePair is getting ready."
                                        font:[NSFont systemFontOfSize:13]
                                       color:NSColor.secondaryLabelColor];

    _bluetoothStatusField = [self labelWithText:@"●  Bluetooth Preparing"
                                           font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
                                          color:NSColor.secondaryLabelColor];
    _hidStatusField = [self labelWithText:@"●  HID Preparing"
                                     font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
                                    color:NSColor.secondaryLabelColor];

    NSStackView* statusStack = [NSStackView stackViewWithViews:@[_bluetoothStatusField, _hidStatusField]];
    statusStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusStack.spacing = 22;
    statusStack.alignment = NSLayoutAttributeCenterY;
    statusStack.distribution = NSStackViewDistributionFillEqually;
    statusStack.translatesAutoresizingMaskIntoConstraints = NO;

    _detailsButton = [NSButton buttonWithTitle:@"Show Details"
                                        target:self
                                        action:@selector(toggleDetails:)];
    _detailsButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    _detailsButton.font = [NSFont systemFontOfSize:12];
    _detailsButton.toolTip = @"Show Bluetooth and HID diagnostic messages";
    _detailsButton.translatesAutoresizingMaskIntoConstraints = NO;

    _pairAnotherButton = [NSButton buttonWithTitle:@"Pair Another Remote"
                                             target:self
                                             action:@selector(pairAnotherRemote:)];
    _pairAnotherButton.bezelStyle = NSBezelStyleRounded;
    _pairAnotherButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _pairAnotherButton.toolTip = @"Keep the current remote paired and search for another one";
    _pairAnotherButton.hidden = YES;
    _pairAnotherButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView* actionStack = [NSStackView stackViewWithViews:@[_pairAnotherButton, _detailsButton]];
    actionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionStack.spacing = 10;
    actionStack.alignment = NSLayoutAttributeCenterY;
    actionStack.translatesAutoresizingMaskIntoConstraints = NO;

    _detailsTextView = [[NSTextView alloc] init];
    _detailsTextView.editable = NO;
    _detailsTextView.selectable = YES;
    _detailsTextView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    _detailsTextView.textColor = NSColor.secondaryLabelColor;
    _detailsTextView.backgroundColor = NSColor.clearColor;
    _detailsTextView.textContainerInset = NSMakeSize(8, 8);

    _detailsScrollView = [[NSScrollView alloc] init];
    _detailsScrollView.documentView = _detailsTextView;
    _detailsScrollView.hasVerticalScroller = YES;
    _detailsScrollView.borderType = NSBezelBorder;
    _detailsScrollView.hidden = YES;
    _detailsScrollView.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView* view in @[_stateImageView, _progressIndicator, _stateTitleField, _stateMessageField,
                           statusStack, actionStack, _detailsScrollView]) {
        [self.view addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_stateImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:30],
        [_stateImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_stateImageView.widthAnchor constraintEqualToConstant:48],
        [_stateImageView.heightAnchor constraintEqualToConstant:48],
        [_progressIndicator.topAnchor constraintEqualToAnchor:_stateImageView.bottomAnchor constant:7],
        [_progressIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_stateTitleField.topAnchor constraintEqualToAnchor:_progressIndicator.bottomAnchor constant:12],
        [_stateTitleField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [_stateTitleField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [_stateMessageField.topAnchor constraintEqualToAnchor:_stateTitleField.bottomAnchor constant:9],
        [_stateMessageField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:42],
        [_stateMessageField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-42],
        [_stateMessageField.heightAnchor constraintGreaterThanOrEqualToConstant:42],
        [statusStack.topAnchor constraintEqualToAnchor:_stateMessageField.bottomAnchor constant:16],
        [statusStack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [statusStack.widthAnchor constraintLessThanOrEqualToConstant:390],
        [actionStack.topAnchor constraintEqualToAnchor:statusStack.bottomAnchor constant:16],
        [actionStack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_detailsScrollView.topAnchor constraintEqualToAnchor:actionStack.bottomAnchor constant:12],
        [_detailsScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_detailsScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_detailsScrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-18],
    ]];
}

- (IBAction)pairAnotherRemote:(id)sender {
    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [_disconnectNotification unregister];
    _disconnectNotification = nil;

    NSString* previousRemote = _pairedDevice.name ?: @"Wii Remote";
    NSString* previousAddress = NormalizedBluetoothAddress(_pairedDevice.addressString);
    if (previousAddress.length > 0) {
        [_completedRemoteAddresses addObject:previousAddress];
    }
    [self closeHIDDevice];
    _pairedDevice = nil;
    _hidOwnedByAnotherApp = NO;

    if (_deviceInquiry == nil) {
        _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
        _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
    } else {
        [_deviceInquiry stop];
        [_deviceInquiry clearFoundDevices];
    }

    [self transitionToState:WiimoteConnectionStateSearching];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: %@ handed off • searching for another remote",
                               previousRemote]];
    [_deviceInquiry start];
}

- (void)toggleDetails:(id)sender {
    _detailsVisible = !_detailsVisible;
    _detailsScrollView.hidden = !_detailsVisible;
    _detailsButton.title = _detailsVisible ? @"Hide Details" : @"Show Details";

    NSRect frame = self.view.window.frame;
    CGFloat targetHeight = _detailsVisible ? 500 : 330;
    CGFloat delta = targetHeight - self.view.window.contentLayoutRect.size.height;
    frame.origin.y -= delta;
    frame.size.height += delta;
    [self.view.window setFrame:frame display:YES animate:YES];
}

- (IBAction)searchAgain:(id)sender {
    if (_deviceInquiry == nil) {
        _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
        _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
    } else {
        [_deviceInquiry stop];
        [_deviceInquiry clearFoundDevices];
    }

    _pairedDevice = nil;
    _hidOwnedByAnotherApp = NO;
    [_completedRemoteAddresses removeAllObjects];
    [self closeHIDDevice];
    [self transitionToState:WiimoteConnectionStateSearching];
    [self setConnectionStatus:@"Bluetooth: searching again…"];
    [_deviceInquiry start];
}

- (void)transitionToState:(WiimoteConnectionState)state {
    _connectionState = state;
    _pairAnotherButton.hidden = !(state == WiimoteConnectionStateConnected ||
                                  state == WiimoteConnectionStateInUseByAnotherApp);

    if (state == WiimoteConnectionStateConnected) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                          accessibilityDescription:@"Connected"];
        _stateImageView.contentTintColor = NSColor.systemGreenColor;
        _stateTitleField.stringValue = @"Wii Remote Connected";
        _stateMessageField.stringValue = [NSString stringWithFormat:@"%@ is connected and ready to use.",
                                           _pairedDevice.name ?: @"Your controller"];
        _bluetoothStatusField.stringValue = @"●  Bluetooth Connected";
        _hidStatusField.stringValue = @"●  HID Ready";
        _bluetoothStatusField.textColor = NSColor.systemGreenColor;
        _hidStatusField.textColor = NSColor.systemGreenColor;
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStateInUseByAnotherApp) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                          accessibilityDescription:@"Connected and in use"];
        _stateImageView.contentTintColor = NSColor.systemGreenColor;
        _stateTitleField.stringValue = @"Wii Remote Connected";
        _stateMessageField.stringValue = @"The controller is ready and currently in use by Dolphin or another application.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Connected";
        _hidStatusField.stringValue = @"●  HID In Use";
        _bluetoothStatusField.textColor = NSColor.systemGreenColor;
        _hidStatusField.textColor = NSColor.systemGreenColor;
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStateFailed) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill"
                                          accessibilityDescription:@"Connection issue"];
        _stateImageView.contentTintColor = NSColor.systemOrangeColor;
        _stateTitleField.stringValue = @"Connection Issue";
        _stateMessageField.stringValue = @"WiimotePair could not finish the connection. Open Details for diagnostic information.";
        _hidStatusField.stringValue = @"●  HID Needs Attention";
        _hidStatusField.textColor = NSColor.systemOrangeColor;
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStateDisconnected) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"gamecontroller"
                                          accessibilityDescription:@"Controller disconnected"];
        _stateImageView.contentTintColor = NSColor.secondaryLabelColor;
        _stateTitleField.stringValue = @"Wii Remote Disconnected";
        _stateMessageField.stringValue = @"Press A, 1, or another regular button to reconnect. Do not press SYNC.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Waiting";
        _hidStatusField.stringValue = @"●  HID Disconnected";
        _bluetoothStatusField.textColor = NSColor.secondaryLabelColor;
        _hidStatusField.textColor = NSColor.secondaryLabelColor;
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStateConnecting) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"gamecontroller.fill"
                                          accessibilityDescription:@"Connecting controller"];
        _stateImageView.contentTintColor = NSColor.controlAccentColor;
        _stateTitleField.stringValue = @"Connecting Wii Remote…";
        _stateMessageField.stringValue = @"Keep the controller close to your Mac while the HID session starts.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Connected";
        _hidStatusField.stringValue = @"●  HID Connecting";
        _bluetoothStatusField.textColor = NSColor.systemGreenColor;
        _hidStatusField.textColor = NSColor.secondaryLabelColor;
        _progressIndicator.hidden = NO;
    } else if (state == WiimoteConnectionStatePreparing) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right"
                                          accessibilityDescription:@"Preparing Bluetooth"];
        _stateImageView.contentTintColor = NSColor.controlAccentColor;
        _stateTitleField.stringValue = @"Preparing Bluetooth…";
        _stateMessageField.stringValue = @"WiimotePair is getting ready.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Preparing";
        _hidStatusField.stringValue = @"●  HID Preparing";
        _bluetoothStatusField.textColor = NSColor.secondaryLabelColor;
        _hidStatusField.textColor = NSColor.secondaryLabelColor;
        _progressIndicator.hidden = NO;
    } else {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right"
                                          accessibilityDescription:@"Searching for Wii Remotes"];
        _stateImageView.contentTintColor = NSColor.controlAccentColor;
        _stateTitleField.stringValue = @"Searching for Wii Remotes…";
        _stateMessageField.stringValue = @"Press the red SYNC button inside the battery compartment. Do not press any other buttons.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Ready";
        _hidStatusField.stringValue = @"●  HID Monitoring";
        _bluetoothStatusField.textColor = NSColor.systemGreenColor;
        _hidStatusField.textColor = NSColor.secondaryLabelColor;
        _progressIndicator.hidden = NO;
    }
}

- (void)setConnectionStatus:(NSString*)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
        NSString* entry = [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:NSDate.date], status];
        [self->_diagnosticEntries addObject:entry];
        if (self->_diagnosticEntries.count > 100) {
            [self->_diagnosticEntries removeObjectAtIndex:0];
        }
        self->_detailsTextView.string = [self->_diagnosticEntries componentsJoinedByString:@"\n"];
        [self->_detailsTextView scrollToEndOfDocument:nil];
    });
}

#pragma mark - Physical IOHID session

- (void)setupHIDManager {
    if (_hidManager != NULL) {
        return;
    }

    _hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_hidManager == NULL) {
        [self setConnectionStatus:@"HID: could not create IOHIDManager"];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }

    NSArray* matches = @[
        @{
            @kIOHIDVendorIDKey: @0x057e,
            @kIOHIDProductIDKey: @0x0306,
            kGCSyntheticDeviceKey: @NO,
        },
        @{
            @kIOHIDVendorIDKey: @0x057e,
            @kIOHIDProductIDKey: @0x0330,
            kGCSyntheticDeviceKey: @NO,
        },
    ];

    IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)matches);
    void* context = (__bridge void*)self;
    IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, HIDDeviceMatchedCallback, context);
    IOHIDManagerRegisterDeviceRemovalCallback(_hidManager, HIDDeviceRemovedCallback, context);
    IOHIDManagerScheduleWithRunLoop(_hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn result = IOHIDManagerOpen(_hidManager, kIOHIDOptionsTypeNone);
    if (result == kIOReturnExclusiveAccess) {
        // The manager can still receive matching callbacks when another app has
        // exclusively opened a different compatible controller.
        [self setConnectionStatus:@"HID: monitor ready • another compatible controller is in use"];
    } else if (result != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: manager open failed • %@",
                                   WiimoteIOReturnDescription(result)]];
        [self transitionToState:WiimoteConnectionStateFailed];
    }
}

- (BOOL)isPhysicalWiimoteHIDDevice:(IOHIDDeviceRef)device {
    if (device == NULL) {
        return NO;
    }

    CFTypeRef syntheticValue = IOHIDDeviceGetProperty(device, (__bridge CFStringRef)kGCSyntheticDeviceKey);
    if (syntheticValue == kCFBooleanTrue) {
        return NO;
    }

    NSNumber* vendorID = HIDNumberProperty(device, CFSTR(kIOHIDVendorIDKey));
    NSNumber* productID = HIDNumberProperty(device, CFSTR(kIOHIDProductIDKey));
    if (vendorID.unsignedIntegerValue != 0x057e ||
        (productID.unsignedIntegerValue != 0x0306 && productID.unsignedIntegerValue != 0x0330)) {
        return NO;
    }

    if (_pairedDevice == nil) {
        return NO;
    }

    NSString* targetAddress = NormalizedBluetoothAddress(_pairedDevice.addressString);
    NSString* serialNumber = NormalizedBluetoothAddress(HIDStringProperty(device, CFSTR(kIOHIDSerialNumberKey)));
    if (targetAddress.length > 0 && serialNumber.length > 0 && ![targetAddress isEqualToString:serialNumber]) {
        return NO;
    }

    BOOL targetIsTR = [_pairedDevice.name containsString:@"-TR"];
    if (targetIsTR && productID.unsignedIntegerValue != 0x0330) {
        return NO;
    }
    if (!targetIsTR && productID.unsignedIntegerValue != 0x0306) {
        return NO;
    }

    return YES;
}

- (void)hidDeviceMatched:(IOHIDDeviceRef)device result:(IOReturn)result {
    if (result != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: device detection error • %@",
                                   WiimoteIOReturnDescription(result)]];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }

    if (!_experimentalMode || ![self isPhysicalWiimoteHIDDevice:device]) {
        return;
    }

    [self openHIDDevice:device];
}

- (void)attachExistingHIDDeviceIfAvailable {
    if (!_experimentalMode || _hidOwnedByAnotherApp || _pairedDevice == nil || _hidManager == NULL || _hidDevice != NULL) {
        return;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(_hidManager);
    if (devices == NULL) {
        return;
    }

    for (id candidate in (__bridge NSSet*)devices) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)candidate;
        if ([self isPhysicalWiimoteHIDDevice:device]) {
            [self openHIDDevice:device];
            break;
        }
    }
    CFRelease(devices);
}

- (void)openHIDDevice:(IOHIDDeviceRef)device {
    if (device == NULL || device == _hidDevice) {
        return;
    }

    [self closeHIDDevice];
    IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (result == kIOReturnExclusiveAccess) {
        _hidOwnedByAnotherApp = YES;
        [_hidConnectionTimer invalidate];
        _hidConnectionTimer = nil;
        [self setConnectionStatus:@"HID: physical device is in use by another application"];
        [self transitionToState:WiimoteConnectionStateInUseByAnotherApp];
        return;
    }
    if (result != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: physical device found, open failed • %@",
                                   WiimoteIOReturnDescription(result)]];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }

    _hidOwnedByAnotherApp = NO;
    _hidDevice = (IOHIDDeviceRef)CFRetain(device);
    _receivedHIDReport = NO;
    memset(_hidInputBuffer, 0, kWiimoteInputBufferSize);
    IOHIDDeviceRegisterInputReportCallback(_hidDevice,
                                           _hidInputBuffer,
                                           kWiimoteInputBufferSize,
                                           HIDInputReportCallback,
                                           (__bridge void*)self);

    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [self transitionToState:WiimoteConnectionStateConnecting];
    [self setConnectionStatus:@"HID: physical device open • initializing reports…"];
    [self sendInitialReportsToHIDDevice:_hidDevice];
}

- (IOReturn)sendHIDReportID:(CFIndex)reportID bytes:(const uint8_t*)bytes length:(CFIndex)length {
    if (_hidDevice == NULL || bytes == NULL || length == 0) {
        return kIOReturnNotOpen;
    }

    return IOHIDDeviceSetReport(_hidDevice, kIOHIDReportTypeOutput, reportID, bytes, length);
}

- (void)sendInitialReportsToHIDDevice:(IOHIDDeviceRef)device {
    const uint8_t playerOneLED[] = {0x11, 0x10};
    const uint8_t reportMode[] = {0x12, 0x04, 0x30};

    IOReturn ledResult = [self sendHIDReportID:0x11 bytes:playerOneLED length:sizeof(playerOneLED)];
    IOReturn modeResult = [self sendHIDReportID:0x12 bytes:reportMode length:sizeof(reportMode)];
    if (ledResult != kIOReturnSuccess || modeResult != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: initialization failed • LED %@ • mode %@",
                                   WiimoteIOReturnDescription(ledResult),
                                   WiimoteIOReturnDescription(modeResult)]];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_hidDevice != device) {
            return;
        }

        const uint8_t requestStatus[] = {0x15, 0x00};
        IOReturn statusResult = [self sendHIDReportID:0x15 bytes:requestStatus length:sizeof(requestStatus)];
        if (statusResult == kIOReturnSuccess) {
            if (self->_receivedHIDReport) {
                [self setConnectionStatus:@"HID: status request sent • input already confirmed"];
            } else {
                [self setConnectionStatus:@"HID: reports sent • waiting for first packet…"];
            }
        } else {
            [self setConnectionStatus:[NSString stringWithFormat:@"HID: status request failed • %@",
                                       WiimoteIOReturnDescription(statusResult)]];
            if (!self->_receivedHIDReport) {
                [self transitionToState:WiimoteConnectionStateFailed];
            }
        }
    });
}

- (void)hidInputReportFromDevice:(IOHIDDeviceRef)device
                          result:(IOReturn)result
                        reportID:(uint32_t)reportID
                          length:(CFIndex)length {
    if (device != _hidDevice) {
        return;
    }

    if (result != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: input read failed • %@",
                                   WiimoteIOReturnDescription(result)]];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }

    if (!_receivedHIDReport) {
        _receivedHIDReport = YES;
        [self transitionToState:WiimoteConnectionStateConnected];
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: connected and receiving • report 0x%02x • %ld bytes",
                                   reportID,
                                   (long)length]];
    }
}

- (void)hidDeviceRemoved:(IOHIDDeviceRef)device result:(IOReturn)result {
    if (device != _hidDevice) {
        return;
    }

    [self closeHIDDevice];
    [self transitionToState:WiimoteConnectionStateDisconnected];
    [self setConnectionStatus:@"HID: device removed • press a button to reconnect"];
    [self beginWaitingForHIDDevice];
}

- (void)closeHIDDevice {
    if (_hidDevice == NULL) {
        return;
    }

    IOHIDDeviceRegisterInputReportCallback(_hidDevice, _hidInputBuffer, kWiimoteInputBufferSize, NULL, NULL);
    IOHIDDeviceClose(_hidDevice, kIOHIDOptionsTypeNone);
    CFRelease(_hidDevice);
    _hidDevice = NULL;
    _receivedHIDReport = NO;
}

- (void)beginWaitingForHIDDevice {
    if (!_experimentalMode || _hidOwnedByAnotherApp || _pairedDevice == nil || _hidDevice != NULL) {
        return;
    }

    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(hidConnectionTimerFired:)
                                                          userInfo:nil
                                                           repeats:YES];
    [self attachExistingHIDDeviceIfAvailable];
}

- (void)hidConnectionTimerFired:(NSTimer*)timer {
    if (!_experimentalMode || _hidOwnedByAnotherApp || _pairedDevice == nil || _hidDevice != NULL) {
        [timer invalidate];
        if (_hidConnectionTimer == timer) {
            _hidConnectionTimer = nil;
        }
        return;
    }

    [self attachExistingHIDDeviceIfAvailable];
    if (_hidDevice == NULL) {
        NSString* aclState = _pairedDevice.isConnected ? @"ACL connected" : @"ACL disconnected";
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: waiting for physical device • %@", aclState]];
    }
}

#pragma mark - Bluetooth lifecycle

- (void)registerDisconnectNotificationForDevice:(IOBluetoothDevice*)device {
    [_disconnectNotification unregister];
    _disconnectNotification = [device registerForDisconnectNotification:self
                                                                  selector:@selector(deviceDisconnected:device:)];
}

- (void)preparePairedDevice:(IOBluetoothDevice*)device statusPrefix:(NSString*)prefix {
    _pairedDevice = device;
    _hidOwnedByAnotherApp = NO;
    [self registerDisconnectNotificationForDevice:device];
    [self transitionToState:WiimoteConnectionStateConnecting];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: %@ • waiting for physical HID", prefix]];
    [self attachExistingHIDDeviceIfAvailable];
    if (_hidDevice == NULL) {
        [self beginWaitingForHIDDevice];
    }
}

- (void)deviceDisconnected:(IOBluetoothUserNotification*)notification device:(IOBluetoothDevice*)device {
    if (device != _pairedDevice) {
        return;
    }

    [self closeHIDDevice];
    _hidOwnedByAnotherApp = NO;
    [self transitionToState:WiimoteConnectionStateDisconnected];
    [self setConnectionStatus:@"Bluetooth: ACL disconnected • press a Wii Remote button"];
    [self beginWaitingForHIDDevice];
}

- (void)dealloc {
    [_hidConnectionTimer invalidate];
    [_disconnectNotification unregister];
    [self closeHIDDevice];

    if (_hidManager != NULL) {
        IOHIDManagerRegisterDeviceMatchingCallback(_hidManager, NULL, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(_hidManager, NULL, NULL);
        IOHIDManagerUnscheduleFromRunLoop(_hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(_hidManager, kIOHIDOptionsTypeNone);
        CFRelease(_hidManager);
        _hidManager = NULL;
    }

    free(_hidInputBuffer);
    _hidInputBuffer = NULL;
    _devicePair.delegate = nil;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(nonnull CBCentralManager*)centralManager {
    CBManagerState state = centralManager.state;

    if (state == CBManagerStateUnauthorized) {
        [self transitionToState:WiimoteConnectionStateFailed];
        [self showFatalErrorAlertWithTitle:@"Bluetooth Permission Denied"
                                      text:@"WiimotePair is not allowed to access Bluetooth. Please allow WiimotePair to access Bluetooth in Privacy & Security."];
    } else if (state == CBManagerStatePoweredOff) {
        if (_deviceInquiry != nil) {
            [_deviceInquiry stop];
            _deviceInquiry = nil;
        }

        if (_devicePair != nil) {
            [_devicePair stop];
            _devicePair = nil;
        }

        [self closeHIDDevice];
        [self transitionToState:WiimoteConnectionStateFailed];
        [self setConnectionStatus:@"Bluetooth: powered off"];
        [self showFatalErrorAlertWithTitle:@"Bluetooth Unavailable"
                                      text:@"Please turn Bluetooth on before running WiimotePair."];
    } else if (state == CBManagerStateUnsupported || state == CBManagerStateUnknown) {
        [self transitionToState:WiimoteConnectionStateFailed];
        [self showFatalErrorAlertWithTitle:@"Unknown Bluetooth Error"
                                      text:@"CBCentralManager is in an invalid state. Relaunch WiimotePair and try again."];
    } else if (state == CBManagerStatePoweredOn) {
        [self setupHIDManager];
        [self attachExistingHIDDeviceIfAvailable];

        if (_deviceInquiry == nil) {
            if (_pairedDevice == nil) {
                [self transitionToState:WiimoteConnectionStateSearching];
            }
            _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
            _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
            [_deviceInquiry start];
        }
    }
}

#pragma mark - IOBluetoothDeviceInquiryDelegate

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device {
    if (![device.name containsString:@"Nintendo RVL-CNT-01"]) {
        [_deviceInquiry clearFoundDevices];
        return;
    }

    NSString* discoveredAddress = NormalizedBluetoothAddress(device.addressString);
    if (discoveredAddress.length > 0 && [_completedRemoteAddresses containsObject:discoveredAddress]) {
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: ignoring previously handed-off remote • %@",
                                   device.name ?: discoveredAddress]];
        return;
    }

    [_deviceInquiry stop];

    if (device.isPaired) {
        [self preparePairedDevice:device
                    statusPrefix:[NSString stringWithFormat:@"already paired • %@", device.name ?: @"Wii Remote"]];
        return;
    }

    _devicePair = [IOBluetoothDevicePair pairWithDevice:device];
    _devicePair.delegate = self;
    [_devicePair setUserDefinedPincode:true];

    IOReturn pairResult = [_devicePair start];
    if (pairResult != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(pairResult);
        [self transitionToState:WiimoteConnectionStateFailed];
        [self showPairingResultAlertWithTitle:@"Pairing Error"
                                         text:[NSString stringWithFormat:@"An error occurred while starting the pairing process: \"%s\".", pairResultString]];
    }
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry*)sender error:(IOReturn)error aborted:(BOOL)aborted {
    if (!aborted && _pairedDevice == nil) {
        [sender clearFoundDevices];
        [sender start];
    }
}

#pragma mark - IOBluetoothDevicePairDelegate

- (void)devicePairingPINCodeRequest:(id)sender {
    IOBluetoothDevicePair* pair = (IOBluetoothDevicePair*)sender;
    IOBluetoothDevice* device = [sender device];
    IOBluetoothHostController* controller = [IOBluetoothHostController defaultController];
    NSString* controllerAddressStr = [controller addressAsString];

    BluetoothDeviceAddress controllerAddress;
    IOBluetoothNSStringToDeviceAddress(controllerAddressStr, &controllerAddress);

    BluetoothPINCode code;
    memset(&code, 0, sizeof(code));
    for (int i = 0; i < 6; i++) {
        code.data[i] = controllerAddress.data[5 - i];
    }

    uint64_t key = 0;
    memcpy(&key, code.data, 6);
    [[IOBluetoothCoreBluetoothCoordinator sharedInstance] pairPeer:[device classicPeer]
                                                            forType:[pair currentPairingType]
                                                            withKey:@(key)];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    IOBluetoothDevicePair* completedPair = (IOBluetoothDevicePair*)sender;
    IOBluetoothDevice* pairedDevice = [completedPair device];

    if (error != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(error);
        [self transitionToState:WiimoteConnectionStateFailed];
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: pairing failed • %@",
                                   WiimoteIOReturnDescription(error)]];
        [_devicePair stop];
        _devicePair = nil;
        [self showPairingResultAlertWithTitle:@"Pairing Error"
                                         text:[NSString stringWithFormat:@"An error occurred while attempting to pair: \"%s\".", pairResultString]];
        return;
    }

    // Do not call -stop here. IOBluetoothDevicePair.stop disconnects an already
    // connected device, which aborts the HID handshake of RVL-CNT-01-TR remotes.
    [self preparePairedDevice:pairedDevice
                statusPrefix:[NSString stringWithFormat:@"paired • %@", pairedDevice.name ?: @"Wii Remote"]];
}

@end
