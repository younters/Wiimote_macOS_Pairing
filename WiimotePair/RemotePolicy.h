// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

// Strict canonical form for persisted identities, HID serials, and target comparison.
static inline NSString* RemoteAddress(NSString* value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString* address = [[[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                         stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
    if (address.length != 17) return nil;
    NSCharacterSet* hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    for (NSUInteger i = 0; i < address.length; i++) {
        unichar c = [address characterAtIndex:i];
        if (i % 3 == 2 ? c != ':' : ![hex characterIsMember:c]) return nil;
    }
    if ([address isEqualToString:@"00:00:00:00:00:00"] || [address isEqualToString:@"FF:FF:FF:FF:FF:FF"]) return nil;
    return address;
}

typedef NS_ENUM(NSUInteger, WiimotePairingPINMode) {
    // Red SYNC button: the controller expects the host adapter address in reverse byte order.
    WiimotePairingPINModeRedSync = 0,
    // 1+2 guest pairing: the controller address is used instead.
    WiimotePairingPINModeGuestOnePlusTwo = 1,
};

// Returns the six binary PIN bytes used by the selected pairing mode. This is binary data,
// not the printable address string. Only the address selected by the mode is required.
static inline NSData* WiimotePairingPIN(WiimotePairingPINMode mode, NSString* hostAddress,
                                       NSString* remoteAddress) {
    NSString* selected = nil;
    switch (mode) {
        case WiimotePairingPINModeRedSync:
            selected = RemoteAddress(hostAddress);
            break;
        case WiimotePairingPINModeGuestOnePlusTwo:
            selected = RemoteAddress(remoteAddress);
            break;
        default:
            return nil;
    }
    if (selected == nil) return nil;

    NSArray<NSString*>* components = [selected componentsSeparatedByString:@":"];
    if (components.count != 6) return nil;
    uint8_t pin[6];
    for (NSUInteger i = 0; i < 6; i++) {
        unsigned int byte = 0;
        if (![[NSScanner scannerWithString:components[5 - i]] scanHexInt:&byte] || byte > UINT8_MAX) return nil;
        pin[i] = (uint8_t)byte;
    }
    return [NSData dataWithBytes:pin length:sizeof(pin)];
}

// Names the core-button mask in report-byte order. Zero represents a complete release.
static inline NSString* WiimoteButtonNames(uint16_t buttons) {
    static const struct {
        uint16_t mask;
        __unsafe_unretained NSString* name;
    } known[] = {
        {0x0001, @"Two"}, {0x0002, @"One"}, {0x0004, @"B"}, {0x0008, @"A"},
        {0x0010, @"Minus"}, {0x0080, @"Home"}, {0x0100, @"Left"}, {0x0200, @"Right"},
        {0x0400, @"Down"}, {0x0800, @"Up"}, {0x1000, @"Plus"},
    };
    if (buttons == 0) return @"Released";

    NSMutableArray<NSString*>* names = [NSMutableArray array];
    uint16_t remaining = buttons;
    for (NSUInteger i = 0; i < sizeof(known) / sizeof(known[0]); i++) {
        if ((buttons & known[i].mask) != 0) {
            [names addObject:known[i].name];
            remaining &= (uint16_t)~known[i].mask;
        }
    }
    if (remaining != 0) [names addObject:[NSString stringWithFormat:@"Unknown(0x%04X)", remaining]];
    return [names componentsJoinedByString:@" + "];
}

static inline NSString* NextRemote(NSArray<NSString*>* targets, NSSet<NSString*>* excluded, NSUInteger* cursor) {
    if (targets.count == 0) return nil;
    for (NSUInteger i = 0; i < targets.count; i++) {
        *cursor %= targets.count;
        NSString* candidate = RemoteAddress(targets[(*cursor)++]);
        if (candidate != nil && ![excluded containsObject:candidate]) return candidate;
    }
    return nil;
}

// Connected devices are skipped for this attempt, not permanently excluded.
static inline NSString* NextUnconnectedRemote(NSArray<NSString*>* targets, NSSet<NSString*>* handedOff,
                                             NSSet<NSString*>* connected, NSUInteger* cursor) {
    NSMutableSet* excluded = [NSMutableSet setWithSet:handedOff];
    [excluded unionSet:connected];
    return NextRemote(targets, excluded, cursor);
}

static inline BOOL IsObservedClone(NSNumber* vendor, NSNumber* product, NSString* serial,
                                  NSString* target, NSString* transport, NSString* name, BOOL synthetic) {
    NSString* address = RemoteAddress(target);
    return !synthetic && vendor != nil && product != nil && vendor.unsignedIntegerValue == 0 &&
        product.unsignedIntegerValue == 0 && address != nil && [address isEqualToString:RemoteAddress(serial)] &&
        [transport isEqualToString:@"Bluetooth"] && [name isEqualToString:@"Nintendo RVL-CNT-01"];
}

// Mode 0x30 is requested by this app. An ACK/status packet alone is not readiness.
static inline BOOL ReadButtons(uint32_t reportID, const uint8_t* bytes, NSUInteger length, uint16_t* buttons) {
    if (reportID != 0x30 || bytes == NULL || buttons == NULL) return NO;
    NSUInteger offset = 0;
    if (length == 3 && bytes[0] == 0x30) offset = 1;
    else if (length != 2) return NO;
    *buttons = ((uint16_t)bytes[offset] << 8) | bytes[offset + 1];
    return YES;
}

// Portable identities only: profiles never contain pairing PINs or link keys.
static inline NSArray<NSString*>* ProfileAddresses(id object) {
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"schema"] isEqual:@1] ||
        ![object[@"status"] isEqual:@"complete"] || ![object[@"devices"] isKindOfClass:NSArray.class]) return @[];
    NSMutableOrderedSet* addresses = [NSMutableOrderedSet orderedSet];
    for (id device in object[@"devices"]) {
        if (![device isKindOfClass:NSDictionary.class]) continue;
        NSString* name = device[@"name"];
        if (![name isEqual:@"Nintendo RVL-CNT-01"] && ![name isEqual:@"Nintendo RVL-CNT-01-TR"]) continue;
        NSString* address = RemoteAddress(device[@"address"]);
        if (address) [addresses addObject:address];
    }
    return addresses.array;
}
