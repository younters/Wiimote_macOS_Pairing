// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ViewController.h"
#import "RemotePolicy.h"

#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>
#import <objc/runtime.h>

static const CFIndex kWiimoteInputBufferSize = 64;
static NSString* const kGCSyntheticDeviceKey = @"GCSyntheticDevice";

typedef NS_ENUM(NSInteger, WiimoteConnectionState) {
    WiimoteConnectionStatePreparing,
    WiimoteConnectionStatePaused,
    WiimoteConnectionStateReadyToPair,
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

// Several legacy IOBluetooth entry points still exist but do nothing on newer macOS.
// Detect only known immediate-success machine-code stubs; other implementations are unverified.
static BOOL ExplicitAuthenticationIsKnownNoop(void) {
    Method method = class_getInstanceMethod(IOBluetoothDevice.class, @selector(requestAuthentication));
    if (!method) return YES;
    const unsigned char* bytes = (const unsigned char*)method_getImplementation(method);
#if defined(__arm64__)
    const unsigned char stub[] = {0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6};
    return memcmp(bytes, stub, sizeof(stub)) == 0;
#elif defined(__x86_64__)
    const unsigned char stub[] = {0x31, 0xc0, 0xc3};
    return memcmp(bytes, stub, sizeof(stub)) == 0;
#else
    return NO;
#endif
}

static NSString* NormalizedBluetoothAddress(NSString* address) {
    return RemoteAddress(address);
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
    NSPopUpButton* _remotePicker;
    NSPopUpButton* _pairingModePicker;
    NSButton* _guidedPairButton;
    NSTextField* _attemptStatusField;
    NSTextField* _buttonsField;
    IOBluetoothDevice* _guidedDevice;
    BOOL _guidedPreparing;
    BOOL _guidedReady;
    BOOL _guidedSession;
    WiimotePairingPINMode _attemptPINMode;
    NSTimer* _attemptProgressTimer;
    NSButton* _pairAnotherButton;
    NSButton* _detailsButton;
    NSButton* _copyLogButton;
    NSScrollView* _detailsScrollView;
    NSTextView* _detailsTextView;
    NSMutableArray<NSString*>* _diagnosticEntries;
    NSMutableSet<NSString*>* _completedRemoteAddresses;
    BOOL _detailsVisible;
    WiimoteConnectionState _connectionState;
    BOOL _hidOwnedByAnotherApp;
    BOOL _manualTarget;
    NSString* _explicitAddress;
    NSButton* _addressButton;
    NSTimer* _autoPairTimer;
    NSArray<NSString*>* _autoTargets;
    NSUInteger _autoTargetIndex;
    BOOL _autoPairPaused;
    BOOL _inquiryRunning;
    NSDate* _inquiryDeadline;
    BOOL _discoveryDue;
    BOOL _preferRememberedOnStart;
    BOOL _pairingInProgress;
    BOOL _pairHadPINRequest;
    NSMutableSet<NSString*>* _noPINFailures;
    IOBluetoothDevice* _pendingPairDevice;
    NSTimer* _attemptTimer;
    NSString* _attemptStage;
    NSData* _lastInputReport;
    NSUInteger _inputChangesLogged;
    uint16_t _lastButtons;
    NSUInteger _buttonChanges;
    NSString* _lastHIDWaitMessage;
    NSUInteger _hidSession;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _experimentalMode = YES;
    _hidInputBuffer = calloc(kWiimoteInputBufferSize, sizeof(uint8_t));

    _diagnosticEntries = [NSMutableArray array];
    _completedRemoteAddresses = [NSMutableSet set];
    _noPINFailures = [NSMutableSet set];
    [self buildInterface];
    NSMenuItem* remotes = [[NSMenuItem alloc] initWithTitle:@"Remotes" action:nil keyEquivalent:@""];
    remotes.submenu = [[NSMenu alloc] initWithTitle:@"Remotes"];
    NSMenuItem* importItem = [remotes.submenu addItemWithTitle:@"Import Remotes…" action:@selector(importRemotes:) keyEquivalent:@"i"];
    importItem.target = self;
    NSMenuItem* exportItem = [remotes.submenu addItemWithTitle:@"Export Remotes…" action:@selector(exportRemotes:) keyEquivalent:@"e"];
    exportItem.target = self;
    [NSApp.mainMenu addItem:remotes];
    [self transitionToState:WiimoteConnectionStatePreparing];
    [self setConnectionStatus:@"Bluetooth: preparing physical HID monitor…"];
    [self setConnectionStatus:ExplicitAuthenticationIsKnownNoop() ?
        @"Compatibility: legacy explicit-authentication API is a no-op on this runtime; using the existing system pairing agent" :
        @"Compatibility: explicit-authentication API is unverified on this runtime; using the existing system pairing agent"];
    [self setupHIDManager];
    _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
}

- (void)viewDidAppear {
    [super viewDidAppear];

    self.view.window.contentMinSize = NSMakeSize(640, 480);
    self.view.window.contentMaxSize = NSMakeSize(900, 800);
    [self.view.window setContentSize:NSMakeSize(640, _detailsVisible ? 700 : 480)];

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
        if (!self->_manualTarget && self->_pairedDevice == nil && self->_deviceInquiry != nil) {
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

    _addressButton = [NSButton buttonWithTitle:@"Stop Auto Pair" target:self action:@selector(toggleAutoPairing:)];
    _addressButton.bezelStyle = NSBezelStyleRounded;
    _addressButton.font = [NSFont systemFontOfSize:12];
    NSStackView* actionStack = [NSStackView stackViewWithViews:@[_pairAnotherButton, _addressButton, _detailsButton]];
    actionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionStack.spacing = 10;
    actionStack.alignment = NSLayoutAttributeCenterY;
    actionStack.translatesAutoresizingMaskIntoConstraints = NO;

    _remotePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_remotePicker addItemWithTitle:@"Discover or import a remote first"];
    [_remotePicker setAccessibilityLabel:@"Remote to pair"];
    _remotePicker.target = self;
    _remotePicker.action = @selector(pairingSelectionChanged:);
    _pairingModePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_pairingModePicker addItemsWithTitles:@[@"Red SYNC · Save pairing", @"1 + 2 · Guest PIN"]];
    [_pairingModePicker setAccessibilityLabel:@"Pairing mode"];
    _pairingModePicker.target = self;
    _pairingModePicker.action = @selector(pairingSelectionChanged:);
    _guidedPairButton = [NSButton buttonWithTitle:@"Prepare Pairing" target:self action:@selector(guidedPair:)];
    _guidedPairButton.bezelStyle = NSBezelStyleRounded;
    _guidedPairButton.enabled = NO;
    NSStackView* selectionStack = [NSStackView stackViewWithViews:@[_remotePicker, _pairingModePicker]];
    selectionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    selectionStack.spacing = 10;
    selectionStack.translatesAutoresizingMaskIntoConstraints = NO;
    _guidedPairButton.translatesAutoresizingMaskIntoConstraints = NO;
    _attemptStatusField = [self labelWithText:@"Automatic pairing uses red SYNC. Prepare a remote for a timed attempt."
                                      font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor];
    _buttonsField = [self labelWithText:@"Buttons: waiting for controller input"
                                font:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium] color:NSColor.secondaryLabelColor];

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

    _copyLogButton = [NSButton buttonWithTitle:@"Copy Diagnostics" target:self action:@selector(copyDiagnostics:)];
    _copyLogButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    _copyLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    _copyLogButton.hidden = YES;
    [self.view addSubview:_copyLogButton];

    for (NSView* view in @[_stateImageView, _progressIndicator, _stateTitleField, _stateMessageField,
                           statusStack, actionStack, selectionStack, _guidedPairButton, _attemptStatusField, _buttonsField, _detailsScrollView]) {
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
        [selectionStack.topAnchor constraintEqualToAnchor:actionStack.bottomAnchor constant:18],
        [selectionStack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [selectionStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [selectionStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_remotePicker.widthAnchor constraintEqualToConstant:265],
        [_guidedPairButton.topAnchor constraintEqualToAnchor:selectionStack.bottomAnchor constant:10],
        [_guidedPairButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_attemptStatusField.topAnchor constraintEqualToAnchor:_guidedPairButton.bottomAnchor constant:10],
        [_attemptStatusField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_attemptStatusField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_buttonsField.topAnchor constraintEqualToAnchor:_attemptStatusField.bottomAnchor constant:8],
        [_buttonsField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_buttonsField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_detailsScrollView.topAnchor constraintEqualToAnchor:_buttonsField.bottomAnchor constant:12],
        [_detailsScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_detailsScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_detailsScrollView.bottomAnchor constraintEqualToAnchor:_copyLogButton.topAnchor constant:-6],
        [_copyLogButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_copyLogButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
    ]];
}

- (void)refreshRemotePicker {
    NSString* selected = _remotePicker.selectedItem.representedObject;
    [_remotePicker removeAllItems];
    for (NSString* address in _autoTargets) {
        NSString* normalized = RemoteAddress(address);
        if (!normalized) continue;
        IOBluetoothDevice* device = [IOBluetoothDevice deviceWithAddressString:normalized];
        NSString* state = device.isConnected && device.isPaired ? @"connected" : device.isPaired ? @"saved" : @"new";
        [_remotePicker addItemWithTitle:[NSString stringWithFormat:@"%@ · %@", normalized, state]];
        _remotePicker.lastItem.representedObject = normalized;
        if ([normalized isEqual:selected]) [_remotePicker selectItem:_remotePicker.lastItem];
    }
    if (_remotePicker.numberOfItems == 0) [_remotePicker addItemWithTitle:@"Discover or import a remote first"];
    _guidedPairButton.enabled = _autoTargets.count > 0 && !_pairingInProgress && _centralManager.state == CBManagerStatePoweredOn;
}

- (void)pairingSelectionChanged:(id)sender {
    if (_pairingInProgress || _guidedPreparing) return;
    _guidedReady = NO;
    _guidedPreparing = NO;
    _guidedDevice = nil;
    _guidedPairButton.title = @"Prepare Pairing";
    if (_guidedSession) {
        [self transitionToState:WiimoteConnectionStatePaused];
        _attemptStatusField.stringValue = @"Selection changed · choose Prepare Pairing before pressing the remote buttons";
    }
}

- (void)armGuidedPairing {
    if (!_guidedPreparing || _guidedDevice == nil) return;
    _guidedPreparing = NO;
    _guidedReady = YES;
    _guidedPairButton.title = @"Pair Now";
    _remotePicker.enabled = YES;
    _pairingModePicker.enabled = YES;
    _addressButton.enabled = YES;
    _guidedPairButton.enabled = YES;
    [self transitionToState:WiimoteConnectionStateReadyToPair];
    _attemptStatusField.stringValue = [NSString stringWithFormat:@"Prepared: %@ · discovery stopped", RemoteAddress(_guidedDevice.addressString)];
    if (_guidedDevice.isPaired) {
        _stateMessageField.stringValue = @"This remote is already paired. Press A to wake it, then click Pair Now. Its existing pairing will be preserved.";
    }
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: guided target prepared • %@ • %@", _guidedDevice.addressString,
                               _pairingModePicker.indexOfSelectedItem == 1 ? @"guest 1+2" : @"red SYNC"]];
}

- (void)guidedPair:(id)sender {
    if (_centralManager.state != CBManagerStatePoweredOn || _pairingInProgress) return;
    if (_guidedReady && _guidedDevice != nil) {
        _guidedReady = NO;
        _autoPairPaused = YES;
        _attemptPINMode = _pairingModePicker.indexOfSelectedItem == 1 ? WiimotePairingPINModeGuestOnePlusTwo : WiimotePairingPINModeRedSync;
        _manualTarget = YES;
        _explicitAddress = RemoteAddress(_guidedDevice.addressString);
        [self updateHIDMatching];
        _guidedPairButton.title = @"Prepare Pairing";
        [self selectDeviceForPairing:_guidedDevice];
        return;
    }
    NSString* address = RemoteAddress(_remotePicker.selectedItem.representedObject);
    if (!address) return;
    [self stopAutoPairing];
    [self resetPairingAttempt];
    _autoPairPaused = YES;
    _manualTarget = YES;
    NSString* previous = RemoteAddress(_pairedDevice.addressString);
    if (previous) [_completedRemoteAddresses addObject:previous];
    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [_disconnectNotification unregister];
    _disconnectNotification = nil;
    [self closeHIDDevice];
    _pairedDevice = nil;
    _hidOwnedByAnotherApp = NO;
    _guidedDevice = [IOBluetoothDevice deviceWithAddressString:address];
    _guidedSession = YES;
    _guidedPreparing = YES;
    _remotePicker.enabled = NO;
    _pairingModePicker.enabled = NO;
    _addressButton.enabled = NO;
    _guidedPairButton.enabled = NO;
    _attemptStatusField.stringValue = @"Preparing selected remote · stopping discovery before your SYNC window";
    IOReturn result = _deviceInquiry ? [_deviceInquiry stop] : kIOReturnNotPermitted;
    if (result == kIOReturnNotPermitted) {
        _inquiryRunning = NO;
        [self armGuidedPairing];
    } else if (result != kIOReturnSuccess) {
        _guidedPreparing = NO;
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: could not prepare target • %@", WiimoteIOReturnDescription(result)]];
        [self transitionToState:WiimoteConnectionStateFailed];
    }
}

- (void)updateAttemptProgress:(NSTimer*)timer {
    if (timer != _attemptProgressTimer) return;
    if (_attemptTimer == nil) {
        [timer invalidate];
        _attemptProgressTimer = nil;
        return;
    }
    NSInteger seconds = MAX(0, (NSInteger)ceil([_attemptTimer.fireDate timeIntervalSinceNow]));
    NSString* phase = _pairHadPINRequest ? @"Authenticating" : _pairedDevice ? @"Waiting for input" : @"Connecting";
    _attemptStatusField.stringValue = [NSString stringWithFormat:@"%@ · %@ · %ld s remaining", phase,
                                      _explicitAddress ?: @"selected remote", (long)seconds];
}

- (void)resetPairingAttempt {
    [_attemptTimer invalidate];
    _attemptTimer = nil;
    _pendingPairDevice = nil;
    [_attemptProgressTimer invalidate];
    _attemptProgressTimer = nil;
    _remotePicker.enabled = YES;
    _pairingModePicker.enabled = YES;
    _guidedPairButton.enabled = _autoTargets.count > 0 && !_guidedPreparing && _centralManager.state == CBManagerStatePoweredOn;
    _addressButton.enabled = YES;
    _pairingInProgress = NO;
    // A completed pair must never be stopped: macOS is still using its HID link.
    BOOL unfinished = _devicePair != nil && _pairedDevice == nil;
    _devicePair.delegate = nil;
    if (unfinished) [_devicePair stop];
    _devicePair = nil;
}

- (void)stopAutoPairing {
    [_autoPairTimer invalidate];
    _autoPairTimer = nil;
    _addressButton.title = @"Start Auto Pair";
}

- (void)startAutoPairing {
    if (_autoPairTimer != nil || _centralManager.state != CBManagerStatePoweredOn || _pairingInProgress || _attemptTimer != nil || _guidedPreparing) return;
    _autoPairPaused = NO;
    _guidedPreparing = NO;
    _guidedReady = NO;
    _guidedSession = NO;
    _guidedDevice = nil;
    _guidedPairButton.title = @"Prepare Pairing";
    NSMutableOrderedSet* addresses = [NSMutableOrderedSet orderedSet];
    NSArray* saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"KnownRemoteAddresses"] ?: @[];
    for (id value in saved) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString* address = RemoteAddress(value);
        if (address != nil) [addresses addObject:address];
    }
    for (IOBluetoothDevice* device in [IOBluetoothDevice pairedDevices]) {
        NSString* address = RemoteAddress(device.addressString);
        if ([device.name containsString:@"Nintendo RVL-CNT-01"] && address != nil)
            [addresses addObject:address];
    }
    _autoTargets = addresses.array;
    [self refreshRemotePicker];
    _autoTargetIndex = 0;
    _discoveryDue = !(_preferRememberedOnStart || [[NSUserDefaults standardUserDefaults] boolForKey:@"PreferRememberedOnNextLaunch"]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PreferRememberedOnNextLaunch"];
    _preferRememberedOnStart = NO;
    _addressButton.title = @"Stop Auto Pair";
    _autoPairTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(autoPairTimerFired:) userInfo:nil repeats:YES];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: auto pairing enabled • %lu remembered remotes • press SYNC", (unsigned long)_autoTargets.count]];
    [self autoPairTimerFired:_autoPairTimer];
}

- (void)toggleAutoPairing:(id)sender {
    if (_autoPairTimer != nil) {
        _autoPairPaused = YES;
        _guidedPreparing = NO;
        _guidedReady = NO;
        [self stopAutoPairing];
        [self resetPairingAttempt];
        _manualTarget = YES; // Prevent inquiry completion from restarting discovery.
        [_deviceInquiry stop];
        [self setConnectionStatus:@"Bluetooth: automatic pairing paused"];
        if (!_receivedHIDReport && !_hidOwnedByAnotherApp) [self transitionToState:WiimoteConnectionStatePaused];
    } else {
        [self startAutoPairing];
    }
}

- (void)autoPairTimerFired:(NSTimer*)timer {
    if (timer != _autoPairTimer || _centralManager.state != CBManagerStatePoweredOn ||
        _pairingInProgress || _attemptTimer != nil || _receivedHIDReport || _hidOwnedByAnotherApp) return;
    if (_pairedDevice.isConnected) {
        [self attachExistingHIDDeviceIfAvailable];
        return;
    }
    if (_inquiryRunning) {
        if (_inquiryDeadline != nil && [_inquiryDeadline timeIntervalSinceNow] <= 0) {
            _inquiryDeadline = [NSDate dateWithTimeIntervalSinceNow:45];
            [self setConnectionStatus:@"Discovery: scan/name lookup exceeded 45 seconds • stopping before retry"];
            IOReturn result = [_deviceInquiry stop];
            if (result == kIOReturnNotPermitted) {
                _inquiryRunning = NO;
                _discoveryDue = NO;
            } else if (result != kIOReturnSuccess) {
                [self setConnectionStatus:[NSString stringWithFormat:@"Discovery: stop failed • %@", WiimoteIOReturnDescription(result)]];
            }
        }
        return;
    }
    NSString* target = nil;
    if (!_discoveryDue) {
        NSMutableSet* connected = [NSMutableSet set];
        for (NSString* address in _autoTargets) {
            IOBluetoothDevice* candidate = [IOBluetoothDevice deviceWithAddressString:address];
            if (candidate.isPaired && candidate.isConnected) [connected addObject:address];
        }
        target = NextUnconnectedRemote(_autoTargets, _completedRemoteAddresses, connected, &_autoTargetIndex);
    }
    if (target == nil) {
        [self resetPairingAttempt];
        [_hidConnectionTimer invalidate];
        _hidConnectionTimer = nil;
        [_disconnectNotification unregister];
        _disconnectNotification = nil;
        [self closeHIDDevice];
        _pairedDevice = nil;
        _manualTarget = NO;
        _explicitAddress = nil;
        [self updateHIDMatching];
        if (_deviceInquiry == nil) {
            _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
            _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
            _deviceInquiry.inquiryLength = 10;
            _deviceInquiry.updateNewDeviceNames = YES;
        }
        [_deviceInquiry clearFoundDevices];
        _inquiryRunning = YES;
        _inquiryDeadline = [NSDate dateWithTimeIntervalSinceNow:45];
        IOReturn result = [_deviceInquiry start];
        if (result != kIOReturnSuccess && result != kIOReturnBusy) _inquiryRunning = NO;
        [self transitionToState:WiimoteConnectionStateSearching];
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: scanning for new remotes • press SYNC • start %@", WiimoteIOReturnDescription(result)]];
        return;
    }
    // Give new devices a full discovery cycle between remembered-target attempts.
    _discoveryDue = YES;
    IOBluetoothDevice* device = [IOBluetoothDevice deviceWithAddressString:target];
    if (device == nil) return;
    [self resetPairingAttempt];
    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [_disconnectNotification unregister];
    _disconnectNotification = nil;
    [self closeHIDDevice];
    _pairedDevice = nil;
    _manualTarget = YES;
    _explicitAddress = target;
    [self updateHIDMatching];
    [self setConnectionStatus:@"Bluetooth: automatic connection attempt • press SYNC if the remote is asleep"];
    [self selectDeviceForPairing:device];
}

- (void)selectDeviceForPairing:(IOBluetoothDevice*)device {
    _pairingInProgress = YES;
    _pairHadPINRequest = NO;
    _addressButton.enabled = !_guidedSession;
    if (!_guidedSession) _attemptPINMode = WiimotePairingPINModeRedSync;
    _guidedPairButton.enabled = NO;
    _remotePicker.enabled = NO;
    _pairingModePicker.enabled = NO;
    _pendingPairDevice = device;
    _attemptStage = @"stopping discovery";
    [self transitionToState:WiimoteConnectionStateConnecting];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: selected %@ • name %@ • %@",
                               device.addressString, device.name.length > 0 ? device.name : @"unknown",
                               _guidedSession ? (_attemptPINMode == WiimotePairingPINModeGuestOnePlusTwo ? @"guided temporary 1+2" : @"guided red SYNC") : @"automatic red SYNC"]];
    [_attemptTimer invalidate];
    _attemptTimer = [NSTimer scheduledTimerWithTimeInterval:(_guidedSession ? 20 : 30) target:self selector:@selector(attemptTimedOut:) userInfo:nil repeats:NO];
    [_attemptProgressTimer invalidate];
    _attemptProgressTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateAttemptProgress:) userInfo:nil repeats:YES];
    [self updateAttemptProgress:_attemptProgressTimer];
    IOReturn stopResult = _deviceInquiry ? [_deviceInquiry stop] : kIOReturnNotPermitted;
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: inquiry stop returned %@", WiimoteIOReturnDescription(stopResult)]];
    // Successful stop completes asynchronously. Pair only after its delegate callback.
    if (stopResult == kIOReturnNotPermitted) {
        [self startPendingPairing];
    } else if (stopResult != kIOReturnSuccess) {
        [self resetPairingAttempt];
        [self transitionToState:WiimoteConnectionStateFailed];
    }
}

- (void)startPendingPairing {
    IOBluetoothDevice* device = _pendingPairDevice;
    if (device == nil) return;
    _pendingPairDevice = nil;
    _attemptStage = @"pairing start";
    if (device.isPaired) {
        _pairingInProgress = NO;
        [self preparePairedDevice:device statusPrefix:@"target already paired"];
        if (_manualTarget && !device.isConnected) {
            _attemptStage = @"reconnecting paired target";
            IOReturn result = [device openConnection:self withPageTimeout:0 authenticationRequired:YES];
            [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: reconnect start returned %@", WiimoteIOReturnDescription(result)]];
            if (result != kIOReturnSuccess) {
                [_attemptTimer invalidate];
                _attemptTimer = nil;
                [self transitionToState:WiimoteConnectionStateFailed];
            }
        }
        return;
    }
    _devicePair = [IOBluetoothDevicePair pairWithDevice:device];
    if (_devicePair == nil) {
        [self setConnectionStatus:@"Bluetooth: could not create pairing object"];
        [self resetPairingAttempt];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }
    if (![_devicePair respondsToSelector:@selector(setUserDefinedPincode:)]) {
        [self setConnectionStatus:@"Bluetooth: this macOS version does not expose the required binary-PIN API"];
        [self resetPairingAttempt];
        [self stopAutoPairing];
        _autoPairPaused = YES;
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }
    _pairHadPINRequest = NO;
    _devicePair.delegate = self;
    [_devicePair setUserDefinedPincode:true];
    IOReturn result = [_devicePair start];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: pairing start for %@ returned %@", device.addressString, WiimoteIOReturnDescription(result)]];
    if (result != kIOReturnSuccess) {
        [self resetPairingAttempt];
        [self transitionToState:WiimoteConnectionStateFailed];
    }
}

- (void)connectionComplete:(IOBluetoothDevice*)device status:(IOReturn)status {
    if (_pairingInProgress && device == _devicePair.device) {
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: pairing connection callback • %@", WiimoteIOReturnDescription(status)]];
        return; // Pairing success and validated input remain separate requirements.
    }
    if (device != _pairedDevice || _receivedHIDReport || (_autoPairPaused && !_guidedSession)) return;
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: reconnect completed • %@", WiimoteIOReturnDescription(status)]];
    if (status == kIOReturnSuccess) {
        _attemptStage = @"reconnected; waiting for physical HID";
        [self attachExistingHIDDeviceIfAvailable];
    } else {
        [_attemptTimer invalidate];
        _attemptTimer = nil;
        [self transitionToState:WiimoteConnectionStateFailed];
    }
}

- (void)attemptTimedOut:(NSTimer*)timer {
    if (timer != _attemptTimer) return;
    _attemptTimer = nil;
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: attempt deadline reached • last stage: %@ • ACL %@",
                               _attemptStage ?: @"unknown", _pairedDevice.isConnected ? @"connected" : @"not confirmed"]];
    [self resetPairingAttempt];
    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [_disconnectNotification unregister];
    _disconnectNotification = nil;
    [self closeHIDDevice];
    _pairedDevice = nil;
    // An ACL without validated input must not block discovery of other remotes.
    [self transitionToState:WiimoteConnectionStateFailed];
}

- (IBAction)pairAnotherRemote:(id)sender {
    [self stopAutoPairing];
    [self resetPairingAttempt];
    _manualTarget = NO;
    _explicitAddress = nil;
    [self updateHIDMatching];
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

    [self transitionToState:WiimoteConnectionStateSearching];
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: %@ handed off • auto pairing another remote", previousRemote]];
    _preferRememberedOnStart = YES;
    [self startAutoPairing];
}

- (void)importRemotes:(id)sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = @"Import Discovered Remotes";
    panel.message = @"Choose a JSON discovery result or an exported remote profile. No pairing keys are imported.";
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSNumber* size = nil;
        [panel.URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSData* data = size.unsignedLongLongValue <= 1024 * 1024 ? [NSData dataWithContentsOfURL:panel.URL] : nil;
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray* imported = ProfileAddresses(object);
        if (imported.count == 0) {
            [self showAlertWithTitle:@"No Wii Remotes Found" text:@"Choose a completed discovery JSON or a remote profile exported by this app." callback:^{}];
            return;
        }
        NSMutableOrderedSet* merged = [NSMutableOrderedSet orderedSetWithArray:imported];
        [merged addObjectsFromArray:self->_autoTargets ?: @[]];
        self->_autoTargets = merged.array;
        [self refreshRemotePicker];
        [[NSUserDefaults standardUserDefaults] setObject:self->_autoTargets forKey:@"KnownRemoteAddresses"];
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: imported %lu remote identities • press SYNC to pair on this Mac", (unsigned long)imported.count]];
        if (!self->_receivedHIDReport && !self->_hidOwnedByAnotherApp && !self->_pairingInProgress) {
            [self stopAutoPairing];
            [self resetPairingAttempt];
            self->_manualTarget = YES;
            [self->_deviceInquiry stop];
            self->_preferRememberedOnStart = YES;
            [self startAutoPairing];
        }
    }];
}

- (void)exportRemotes:(id)sender {
    NSMutableArray* devices = [NSMutableArray array];
    for (NSString* address in _autoTargets) {
        NSString* valid = RemoteAddress(address);
        if (valid) [devices addObject:@{@"address": valid, @"name": @"Nintendo RVL-CNT-01"}];
    }
    if (devices.count == 0) {
        [self showAlertWithTitle:@"No Remotes to Export" text:@"Discover or import a remote first." callback:^{}];
        return;
    }
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"Wiimote-remotes.json";
    panel.message = @"Import this file on your other Mac, then press SYNC to pair there. It contains device addresses, not pairing keys.";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"schema": @1, @"status": @"complete", @"source": @"wiimotepair-profile", @"devices": devices} options:NSJSONWritingPrettyPrinted error:nil];
        NSError* error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])
            [self showAlertWithTitle:@"Export Failed" text:error.localizedDescription ?: @"Could not write the profile." callback:^{}];
        else [self setConnectionStatus:@"Bluetooth: remote profile exported"];
    }];
}

- (void)copyDiagnostics:(id)sender {
    NSString* version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString* header = [NSString stringWithFormat:@"WiimotePair %@ • %@\n", version, NSProcessInfo.processInfo.operatingSystemVersionString];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[header stringByAppendingString:[_diagnosticEntries componentsJoinedByString:@"\n"]] forType:NSPasteboardTypeString];
}

- (void)toggleDetails:(id)sender {
    _detailsVisible = !_detailsVisible;
    _detailsScrollView.hidden = !_detailsVisible;
    _copyLogButton.hidden = !_detailsVisible;
    _detailsButton.title = _detailsVisible ? @"Hide Details" : @"Show Details";

    NSRect frame = self.view.window.frame;
    CGFloat targetHeight = _detailsVisible ? 700 : 480;
    CGFloat delta = targetHeight - self.view.window.contentLayoutRect.size.height;
    frame.origin.y -= delta;
    frame.size.height += delta;
    [self.view.window setFrame:frame display:YES animate:YES];
}

- (IBAction)searchAgain:(id)sender {
    [self stopAutoPairing];
    [self resetPairingAttempt];
    [_hidConnectionTimer invalidate];
    _hidConnectionTimer = nil;
    [_disconnectNotification unregister];
    _disconnectNotification = nil;
    [self closeHIDDevice];
    _pairedDevice = nil;
    _hidOwnedByAnotherApp = NO;
    [_completedRemoteAddresses removeAllObjects];
    [self startAutoPairing];
}

- (void)transitionToState:(WiimoteConnectionState)state {
    _connectionState = state;
    if (state != WiimoteConnectionStateConnecting && !_pairingInProgress && !_guidedPreparing) {
        _addressButton.enabled = YES;
        _remotePicker.enabled = YES;
        _pairingModePicker.enabled = YES;
        _guidedPairButton.enabled = _autoTargets.count > 0 && _centralManager.state == CBManagerStatePoweredOn;
    }
    if (state == WiimoteConnectionStateConnected || state == WiimoteConnectionStateFailed ||
        state == WiimoteConnectionStatePaused || state == WiimoteConnectionStateDisconnected) {
        [_attemptProgressTimer invalidate];
        _attemptProgressTimer = nil;
        if (state == WiimoteConnectionStateConnected) _attemptStatusField.stringValue = @"Pairing completed · controller input confirmed";
        if (state == WiimoteConnectionStateFailed) _attemptStatusField.stringValue = @"Attempt ended · see Details for the last completed step";
    }
    _pairAnotherButton.hidden = !(state == WiimoteConnectionStateConnected ||
                                  state == WiimoteConnectionStateInUseByAnotherApp);

    if (state == WiimoteConnectionStateReadyToPair) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"hand.tap" accessibilityDescription:@"Ready to pair"];
        _stateImageView.contentTintColor = NSColor.controlAccentColor;
        _stateTitleField.stringValue = @"Ready for Your Remote";
        _stateMessageField.stringValue = _pairingModePicker.indexOfSelectedItem == 1 ?
            @"Turn the remote off, press 1 + 2 together, then click Pair Now while its LEDs blink. The remote uses guest mode; macOS may still remember its identity." :
            @"Press the red SYNC button once, then click Pair Now while its LEDs blink. You have about 20 seconds.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Ready";
        _hidStatusField.stringValue = @"●  Input Waiting";
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStatePaused) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"pause.circle" accessibilityDescription:@"Paused"];
        _stateTitleField.stringValue = @"Automatic Pairing Paused";
        _attemptStatusField.stringValue = @"Automatic attempts paused · prepare a selected remote or resume auto pairing";
        _stateMessageField.stringValue = @"Choose Start Auto Pair to resume looking for your remotes.";
        _bluetoothStatusField.stringValue = @"●  Bluetooth Paused";
        _hidStatusField.stringValue = @"●  HID Waiting";
        _bluetoothStatusField.textColor = NSColor.secondaryLabelColor;
        _hidStatusField.textColor = NSColor.secondaryLabelColor;
        _progressIndicator.hidden = YES;
    } else if (state == WiimoteConnectionStateConnected) {
        _stateImageView.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                          accessibilityDescription:@"Connected"];
        _stateImageView.contentTintColor = NSColor.systemGreenColor;
        _stateTitleField.stringValue = @"Wii Remote Connected";
        _stateMessageField.stringValue = [NSString stringWithFormat:@"%@ is connected and ready to use.\n%@",
                                           _pairedDevice.name ?: @"Your controller", RemoteAddress(_pairedDevice.addressString) ?: @""];
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
        _stateMessageField.stringValue = @"Another application owns the HID device. WiimotePair cannot verify its input while that application is using it.";
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
        _stateMessageField.stringValue = _autoPairTimer ? @"The remote did not finish connecting. Automatic pairing will keep trying. Press SYNC to wake an unpaired remote." : @"The connection could not finish. Open Details for diagnostic information.";
        _bluetoothStatusField.stringValue = _pairedDevice.isConnected ? @"●  Bluetooth Connected" : @"●  Bluetooth Waiting";
        _bluetoothStatusField.textColor = _pairedDevice.isConnected ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
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
        _stateMessageField.stringValue = @"Keep the controller close to your Mac while the connection starts.";
        _bluetoothStatusField.stringValue = _pairedDevice.isConnected ? @"●  Bluetooth Connected" : @"●  Bluetooth Connecting";
        _hidStatusField.stringValue = @"●  HID Connecting";
        _bluetoothStatusField.textColor = _pairedDevice.isConnected ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
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
        _attemptStatusField.stringValue = @"Discovering remotes · Prepare Pairing stops discovery for a timed attempt";
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
        formatter.dateFormat = @"HH:mm:ss.SSS";
        NSString* entry = [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:NSDate.date], status];
        [self->_diagnosticEntries addObject:entry];
        if (self->_diagnosticEntries.count > 500) {
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

    [self updateHIDMatching];
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

- (void)updateHIDMatching {
    if (_hidManager == NULL) return;
    NSMutableArray* matches = [@[
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
    ] mutableCopy];

    if (_manualTarget && _explicitAddress.length > 0) {
        // Observed clone identity. Bind the exception to the selected address,
        // transport and product name; never accept arbitrary zero-ID HID devices.
        [matches addObject:@{
            @kIOHIDVendorIDKey: @0,
            @kIOHIDProductIDKey: @0,
            @kIOHIDSerialNumberKey: _explicitAddress,
            @kIOHIDTransportKey: @"Bluetooth",
            @kIOHIDProductKey: @"Nintendo RVL-CNT-01",
            kGCSyntheticDeviceKey: @NO,
        }];
    }
    IOHIDManagerSetDeviceMatchingMultiple(_hidManager, (__bridge CFArrayRef)matches);
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
    if (_manualTarget && [_explicitAddress isEqualToString:RemoteAddress(_pairedDevice.addressString)] &&
        IsObservedClone(vendorID, productID, HIDStringProperty(device, CFSTR(kIOHIDSerialNumberKey)),
                        _explicitAddress, HIDStringProperty(device, CFSTR(kIOHIDTransportKey)),
                        HIDStringProperty(device, CFSTR(kIOHIDProductKey)), syntheticValue == kCFBooleanTrue)) return YES;
    if (vendorID.unsignedIntegerValue != 0x057e ||
        (productID.unsignedIntegerValue != 0x0306 && productID.unsignedIntegerValue != 0x0330)) {
        return NO;
    }

    if (_pairedDevice == nil) {
        return NO;
    }

    NSString* targetAddress = NormalizedBluetoothAddress(_pairedDevice.addressString);
    NSString* serialNumber = NormalizedBluetoothAddress(HIDStringProperty(device, CFSTR(kIOHIDSerialNumberKey)));
    // Explicit-address tests must not claim an unrelated HID device with no identity.
    if (_manualTarget && (serialNumber.length == 0 || ![targetAddress isEqualToString:serialNumber])) return NO;
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
        [_attemptTimer invalidate];
        _attemptTimer = nil;
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

    _attemptStage = @"HID open; waiting for input";
    _lastInputReport = nil;
    _inputChangesLogged = 0;
    _buttonChanges = 0;
    _lastButtons = 0;
    _hidSession++;
    [self setConnectionStatus:[NSString stringWithFormat:@"HID: opening VID %@ PID %@ serial %@",
                               HIDNumberProperty(device, CFSTR(kIOHIDVendorIDKey)),
                               HIDNumberProperty(device, CFSTR(kIOHIDProductIDKey)),
                               HIDStringProperty(device, CFSTR(kIOHIDSerialNumberKey)) ?: @"unknown"]];
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

    NSUInteger session = _hidSession;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_hidDevice != device || self->_hidSession != session) {
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

    if (length <= 0 || length > kWiimoteInputBufferSize) return;
    // Log a bounded set of changing reports for the selected Wii HID only.
    NSData* packet = [NSData dataWithBytes:_hidInputBuffer length:(NSUInteger)length];
    if (_inputChangesLogged < 12 && ![packet isEqualToData:_lastInputReport]) {
        NSMutableString* hex = [NSMutableString string];
        for (NSUInteger i = 0; i < (NSUInteger)length; i++) [hex appendFormat:@"%02x ", _hidInputBuffer[i]];
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: input sample %lu • report 0x%02x • %@", (unsigned long)++_inputChangesLogged, reportID, hex]];
        _lastInputReport = packet;
    }
    uint16_t buttons;
    if (!ReadButtons(reportID, _hidInputBuffer, (NSUInteger)length, &buttons)) return;
    if (_receivedHIDReport && buttons != _lastButtons) {
        _buttonChanges++;
        if (_buttonChanges <= 32) [self setConnectionStatus:[NSString stringWithFormat:@"HID: %@ • buttons 0x%04x • change %lu", WiimoteButtonNames(buttons), buttons, (unsigned long)_buttonChanges]];
    }
    _buttonsField.stringValue = [@"Buttons: " stringByAppendingString:WiimoteButtonNames(buttons)];
    _lastButtons = buttons;
    if (!_receivedHIDReport) {
        [_attemptTimer invalidate];
        _attemptTimer = nil;
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
    _buttonsField.stringValue = @"Buttons: waiting for controller input";
    if (_hidDevice == NULL) {
        return;
    }

    IOHIDDeviceRegisterInputReportCallback(_hidDevice, _hidInputBuffer, kWiimoteInputBufferSize, NULL, NULL);
    IOHIDDeviceClose(_hidDevice, kIOHIDOptionsTypeNone);
    CFRelease(_hidDevice);
    _hidDevice = NULL;
    _hidSession++;
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
        NSString* message = [NSString stringWithFormat:@"HID: waiting for physical device • %@", aclState];
        if (![message isEqualToString:_lastHIDWaitMessage]) [self setConnectionStatus:message];
        _lastHIDWaitMessage = message;
    }
}

#pragma mark - Bluetooth lifecycle

- (void)registerDisconnectNotificationForDevice:(IOBluetoothDevice*)device {
    [_disconnectNotification unregister];
    _disconnectNotification = [device registerForDisconnectNotification:self
                                                                  selector:@selector(deviceDisconnected:device:)];
}

- (void)preparePairedDevice:(IOBluetoothDevice*)device statusPrefix:(NSString*)prefix {
    _lastHIDWaitMessage = nil;
    _attemptStage = @"paired; waiting for physical HID";
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
    [_attemptProgressTimer invalidate];
    [_autoPairTimer invalidate];
    [_attemptTimer invalidate];
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

    if (state == CBManagerStateUnauthorized || state == CBManagerStatePoweredOff || state == CBManagerStateUnsupported) {
        _guidedReady = NO;
        _guidedPreparing = NO;
        _guidedSession = NO;
        _guidedDevice = nil;
        _guidedPairButton.title = @"Prepare Pairing";
        [self resetPairingAttempt];
        [_deviceInquiry stop];
        _deviceInquiry = nil;
        _inquiryRunning = NO;
        [_hidConnectionTimer invalidate];
        _hidConnectionTimer = nil;
        [_disconnectNotification unregister];
        _disconnectNotification = nil;
        [self closeHIDDevice];
        _pairedDevice = nil;
        _hidOwnedByAnotherApp = NO;
        [self transitionToState:WiimoteConnectionStateFailed];
        _stateMessageField.stringValue = state == CBManagerStateUnauthorized ? @"Allow WiimotePair in System Settings → Privacy & Security → Bluetooth." : @"Turn on Bluetooth to resume automatic pairing.";
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: unavailable • manager state %ld", (long)state]];
    } else if (state == CBManagerStatePoweredOn) {
        [self refreshRemotePicker];
        if (_autoPairPaused && !_receivedHIDReport && !_hidOwnedByAnotherApp) [self transitionToState:WiimoteConnectionStatePaused];
        [self setupHIDManager];
        [self attachExistingHIDDeviceIfAvailable];

        if (!_autoPairPaused) {
            if (_autoPairTimer == nil) [self startAutoPairing];
            else [self autoPairTimerFired:_autoPairTimer];
        }
    }
}

#pragma mark - IOBluetoothDeviceInquiryDelegate

- (void)deviceInquiryStarted:(IOBluetoothDeviceInquiry*)sender {
    if (sender == _deviceInquiry) [self setConnectionStatus:@"Discovery: inquiry-started callback"];
}

- (void)deviceInquiryUpdatingDeviceNamesStarted:(IOBluetoothDeviceInquiry*)sender devicesRemaining:(uint32_t)remaining {
    if (sender == _deviceInquiry)
        [self setConnectionStatus:[NSString stringWithFormat:@"Discovery: resolving %u device names", remaining]];
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device {
    if (sender != _deviceInquiry || _autoPairPaused || _manualTarget || _pairingInProgress || _pairedDevice != nil) return;
    [self setConnectionStatus:[NSString stringWithFormat:@"Discovery: %@ • name %@ • class 0x%06x", device.addressString,
                               device.name.length ? device.name : @"pending", (unsigned int)device.classOfDevice]];
    if (![device.name containsString:@"Nintendo RVL-CNT-01"]) {
        return; // Name may arrive later via deviceInquiryDeviceNameUpdated.
    }

    NSString* discoveredAddress = NormalizedBluetoothAddress(device.addressString);
    if (discoveredAddress == nil) return;
    if ((device.isPaired && device.isConnected) || [_completedRemoteAddresses containsObject:discoveredAddress]) {
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: skipping connected or handed-off remote • %@",
                                   device.name ?: discoveredAddress]];
        return;
    }

    _manualTarget = YES;
    _explicitAddress = discoveredAddress;
    [self updateHIDMatching];
    NSMutableOrderedSet* remembered = [NSMutableOrderedSet orderedSetWithArray:_autoTargets ?: @[]];
    if (discoveredAddress.length > 0) [remembered addObject:discoveredAddress];
    _autoTargets = remembered.array;
    [self refreshRemotePicker];
    [[NSUserDefaults standardUserDefaults] setObject:_autoTargets forKey:@"KnownRemoteAddresses"];
    [self selectDeviceForPairing:device];
}

- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device devicesRemaining:(uint32_t)remaining {
    [self deviceInquiryDeviceFound:sender device:device];
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry*)sender error:(IOReturn)error aborted:(BOOL)aborted {
    if (sender != _deviceInquiry) return;
    _inquiryRunning = NO;
    _discoveryDue = NO;
    [self setConnectionStatus:[NSString stringWithFormat:@"Discovery: cycle finished • %lu devices • %@ • aborted %d",
                               (unsigned long)sender.foundDevices.count, WiimoteIOReturnDescription(error), aborted]];
    if (_guidedPreparing) {
        [self armGuidedPairing];
        return;
    }
    if (_pendingPairDevice != nil) {
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: inquiry finished • %@ • aborted %d", WiimoteIOReturnDescription(error), aborted]];
        [self startPendingPairing];
        return;
    }
    // The five-second scheduler starts the next cycle; no back-to-back inquiry loop.
}

#pragma mark - IOBluetoothDevicePairDelegate

- (void)devicePairingStarted:(id)sender {
    if (sender != _devicePair) return;
    _attemptStage = @"pairing started";
    [self setConnectionStatus:@"Bluetooth: pairing-started callback"];
}

- (void)devicePairingConnecting:(id)sender {
    if (sender != _devicePair) return;
    _attemptStage = @"connecting baseband";
    [self setConnectionStatus:@"Bluetooth: connecting baseband callback"];
}

- (void)devicePairingConnected:(id)sender {
    if (sender != _devicePair) return;
    _attemptStage = @"baseband connected; awaiting authentication";
    [self setConnectionStatus:@"Bluetooth: baseband-connected callback"];
}

- (void)devicePairingPINCodeRequest:(id)sender {
    if (sender != _devicePair) return;
    _pairHadPINRequest = YES;
    _attemptStatusField.stringValue = @"Authenticating · PIN requested by the remote";
    _attemptStage = @"binary PIN requested";
    [self setConnectionStatus:(_attemptPINMode == WiimotePairingPINModeGuestOnePlusTwo ? @"Bluetooth: PIN requested • guest remote-address strategy (key omitted)" : @"Bluetooth: PIN requested • red-SYNC host-address strategy (key omitted)")];
    IOBluetoothDevicePair* pair = (IOBluetoothDevicePair*)sender;
    IOBluetoothDevice* device = [sender device];
    IOBluetoothHostController* controller = [IOBluetoothHostController defaultController];
    NSString* controllerAddressStr = [controller addressAsString];

    NSData* pin = WiimotePairingPIN(_attemptPINMode, controllerAddressStr, device.addressString);
    if (pin.length != 6) {
        [self setConnectionStatus:@"Bluetooth: cannot obtain a valid address for the selected PIN mode"];
        [self resetPairingAttempt];
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }
    uint64_t key = 0;
    memcpy(&key, pin.bytes, 6);
    Class coordinatorClass = NSClassFromString(@"IOBluetoothCoreBluetoothCoordinator");
    id coordinator = [coordinatorClass respondsToSelector:@selector(sharedInstance)] ? [coordinatorClass sharedInstance] : nil;
    if (![coordinator respondsToSelector:@selector(pairPeer:forType:withKey:)] ||
        ![device respondsToSelector:@selector(classicPeer)] || ![pair respondsToSelector:@selector(currentPairingType)]) {
        [self setConnectionStatus:@"Bluetooth: required binary-PIN service is unavailable"];
        [self resetPairingAttempt];
        [self stopAutoPairing];
        _autoPairPaused = YES;
        [self transitionToState:WiimoteConnectionStateFailed];
        return;
    }
    [coordinator pairPeer:[device classicPeer]
                                                            forType:[pair currentPairingType]
                                                            withKey:@(key)];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    if (sender != _devicePair) return;
    _pairingInProgress = NO;
    [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: pairing-finished callback • code 0x%08x", (unsigned int)error]];
    IOBluetoothDevicePair* completedPair = (IOBluetoothDevicePair*)sender;
    IOBluetoothDevice* pairedDevice = [completedPair device];

    if (error != kIOReturnSuccess) {
        if (_receivedHIDReport) {
            [self setConnectionStatus:@"Bluetooth: late pairing error while input is active; monitoring the physical connection"];
            return;
        }
        NSString* address = RemoteAddress(pairedDevice.addressString);
        if (!_pairHadPINRequest && address != nil && ![_noPINFailures containsObject:address]) {
            [_noPINFailures addObject:address];
            [self setConnectionStatus:@"Bluetooth: no PIN callback • authentication was not confirmed"];
        }
        NSString* pairResultString = error > 0 && error <= 0xff ?
            [NSString stringWithFormat:@"Bluetooth status 0x%02x", (unsigned int)error] : WiimoteIOReturnDescription(error);
        [self transitionToState:WiimoteConnectionStateFailed];
        [self setConnectionStatus:[NSString stringWithFormat:@"Bluetooth: pairing failed • %@",
                                   pairResultString]];
        [self resetPairingAttempt];
        if (_autoPairTimer == nil && !_guidedSession) [self showPairingResultAlertWithTitle:@"Pairing Error"
                                         text:[NSString stringWithFormat:@"Pairing failed: %@.", pairResultString]];
        return;
    }

    if (_receivedHIDReport) {
        [self setConnectionStatus:@"Bluetooth: late successful pairing callback • input already confirmed"];
        [self transitionToState:WiimoteConnectionStateConnected];
        return;
    }
    // Do not call -stop here. IOBluetoothDevicePair.stop disconnects an already
    // connected device, which aborts the HID handshake of RVL-CNT-01-TR remotes.
    [self preparePairedDevice:pairedDevice
                statusPrefix:[NSString stringWithFormat:@"paired • %@", pairedDevice.name ?: @"Wii Remote"]];
}

@end
