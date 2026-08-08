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

    NSTextField* _connectionStatusField;
    NSButton* _experimentalModeButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _experimentalMode = YES;
    _hidInputBuffer = calloc(kWiimoteInputBufferSize, sizeof(uint8_t));

    _connectionStatusField = [NSTextField labelWithString:@"Bluetooth: initializing…"];
    _connectionStatusField.alignment = NSTextAlignmentCenter;
    _connectionStatusField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _connectionStatusField.textColor = [NSColor secondaryLabelColor];
    _connectionStatusField.lineBreakMode = NSLineBreakByWordWrapping;
    _connectionStatusField.usesSingleLineMode = NO;
    _connectionStatusField.maximumNumberOfLines = 2;
    _connectionStatusField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_connectionStatusField];

    _experimentalModeButton = [NSButton checkboxWithTitle:@"Maintain HID session (experimental)"
                                                     target:self
                                                     action:@selector(experimentalModeChanged:)];
    _experimentalModeButton.state = NSControlStateValueOn;
    _experimentalModeButton.font = [NSFont systemFontOfSize:11];
    _experimentalModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_experimentalModeButton];

    [NSLayoutConstraint activateConstraints:@[
        [_connectionStatusField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_connectionStatusField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_connectionStatusField.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-10],
        [_connectionStatusField.heightAnchor constraintGreaterThanOrEqualToConstant:30],
        [_experimentalModeButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [_experimentalModeButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
        [_experimentalModeButton.bottomAnchor constraintEqualToAnchor:_connectionStatusField.topAnchor constant:-6],
    ]];

    self.searchStatusField.stringValue = @"Searching for Wii Remotes…";
    [self.progressIndicator startAnimation:self];
    [self setConnectionStatus:@"Bluetooth: preparing physical HID monitor…"];
    [self setupHIDManager];
}

- (void)viewDidAppear {
    [super viewDidAppear];

    self.view.window.contentMinSize = NSMakeSize(520, 280);

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

- (void)setConnectionStatus:(NSString*)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_connectionStatusField.stringValue = status;
        self->_connectionStatusField.toolTip = status;
    });
}

- (void)experimentalModeChanged:(NSButton*)sender {
    _experimentalMode = sender.state == NSControlStateValueOn;

    if (!_experimentalMode) {
        [_hidConnectionTimer invalidate];
        _hidConnectionTimer = nil;
        [self closeHIDDevice];
        [self setConnectionStatus:@"HID: experimental monitoring disabled"];
        return;
    }

    [self setConnectionStatus:@"HID: experimental monitoring enabled"];
    [self attachExistingHIDDeviceIfAvailable];
    if (_hidDevice == NULL && _pairedDevice != nil) {
        [self beginWaitingForHIDDevice];
    }
}

#pragma mark - Physical IOHID session

- (void)setupHIDManager {
    if (_hidManager != NULL) {
        return;
    }

    _hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_hidManager == NULL) {
        [self setConnectionStatus:@"HID: could not create IOHIDManager"];
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
        return;
    }

    if (!_experimentalMode || ![self isPhysicalWiimoteHIDDevice:device]) {
        return;
    }

    [self openHIDDevice:device];
}

- (void)attachExistingHIDDeviceIfAvailable {
    if (!_experimentalMode || _pairedDevice == nil || _hidManager == NULL || _hidDevice != NULL) {
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
    if (result != kIOReturnSuccess) {
        [self setConnectionStatus:[NSString stringWithFormat:@"HID: physical device found, open failed • %@",
                                   WiimoteIOReturnDescription(result)]];
        return;
    }

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
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_hidDevice != device) {
            return;
        }

        const uint8_t requestStatus[] = {0x15, 0x00};
        IOReturn statusResult = [self sendHIDReportID:0x15 bytes:requestStatus length:sizeof(requestStatus)];
        if (statusResult == kIOReturnSuccess) {
            [self setConnectionStatus:@"HID: reports sent • waiting for first packet…"];
        } else {
            [self setConnectionStatus:[NSString stringWithFormat:@"HID: status request failed • %@",
                                       WiimoteIOReturnDescription(statusResult)]];
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
        return;
    }

    if (!_receivedHIDReport) {
        _receivedHIDReport = YES;
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
    if (!_experimentalMode || _pairedDevice == nil || _hidDevice != NULL) {
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
    if (!_experimentalMode || _pairedDevice == nil || _hidDevice != NULL) {
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
    [self registerDisconnectNotificationForDevice:device];
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
        [self setConnectionStatus:@"Bluetooth: powered off"];
        [self showFatalErrorAlertWithTitle:@"Bluetooth Unavailable"
                                      text:@"Please turn Bluetooth on before running WiimotePair."];
    } else if (state == CBManagerStateUnsupported || state == CBManagerStateUnknown) {
        [self showFatalErrorAlertWithTitle:@"Unknown Bluetooth Error"
                                      text:@"CBCentralManager is in an invalid state. Relaunch WiimotePair and try again."];
    } else if (state == CBManagerStatePoweredOn) {
        [self setupHIDManager];
        [self attachExistingHIDDeviceIfAvailable];

        if (_deviceInquiry == nil) {
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
    [self showPairingResultAlertWithTitle:@"Paired"
                                     text:@"The Wii Remote was paired. WiimotePair is waiting for the physical HID device and the first input report."];
}

@end
