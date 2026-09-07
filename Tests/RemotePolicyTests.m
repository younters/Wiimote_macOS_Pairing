#import "../WiimotePair/RemotePolicy.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSString* first = @"12:34:56:39:C7:CD";
        NSString* second = @"12:34:56:39:9D:E9";
        assert([RemoteAddress(@" 12-34-56-39-c7-cd\n") isEqualToString:first]);
        for (id bad in @[@"", @"12:34:56", @"12:34:56:39:C7:CG", @"00:00:00:00:00:00", @"FF:FF:FF:FF:FF:FF", @42])
            assert(RemoteAddress(bad) == nil);
        uint8_t redSyncBytes[] = {0x15, 0x71, 0xDA, 0x7D, 0x1A, 0x00};
        uint8_t guestBytes[] = {0xCD, 0xC7, 0x39, 0x56, 0x34, 0x12};
        assert([WiimotePairingPIN(WiimotePairingPINModeRedSync, @"00:1A:7D:DA:71:15", nil)
                isEqualToData:[NSData dataWithBytes:redSyncBytes length:sizeof(redSyncBytes)]]);
        assert([WiimotePairingPIN(WiimotePairingPINModeGuestOnePlusTwo, nil, first)
                isEqualToData:[NSData dataWithBytes:guestBytes length:sizeof(guestBytes)]]);
        assert(WiimotePairingPIN(WiimotePairingPINModeRedSync, @"bad", first) == nil);
        assert(WiimotePairingPIN(WiimotePairingPINModeGuestOnePlusTwo, first, @"00:00:00:00:00:00") == nil);
        assert(WiimotePairingPIN((WiimotePairingPINMode)99, first, second) == nil);
        assert([WiimoteButtonNames(0) isEqualToString:@"Released"]);
        assert([WiimoteButtonNames(0x0001) isEqualToString:@"Two"]);
        assert([WiimoteButtonNames(0x0002) isEqualToString:@"One"]);
        assert([WiimoteButtonNames(0x0004) isEqualToString:@"B"]);
        assert([WiimoteButtonNames(0x0008) isEqualToString:@"A"]);
        assert([WiimoteButtonNames(0x0010) isEqualToString:@"Minus"]);
        assert([WiimoteButtonNames(0x0080) isEqualToString:@"Home"]);
        assert([WiimoteButtonNames(0x0100) isEqualToString:@"Left"]);
        assert([WiimoteButtonNames(0x0200) isEqualToString:@"Right"]);
        assert([WiimoteButtonNames(0x0400) isEqualToString:@"Down"]);
        assert([WiimoteButtonNames(0x0800) isEqualToString:@"Up"]);
        assert([WiimoteButtonNames(0x1000) isEqualToString:@"Plus"]);
        assert([WiimoteButtonNames(0x1088) isEqualToString:@"A + Home + Plus"]);
        assert([WiimoteButtonNames(0x0020) isEqualToString:@"Unknown(0x0020)"]);
        NSUInteger cursor = 0;
        NSArray* targets = @[first, second];
        assert([NextRemote(targets, [NSSet set], &cursor) isEqualToString:first]);
        assert([NextRemote(targets, [NSSet set], &cursor) isEqualToString:second]);
        assert([NextRemote(targets, [NSSet setWithObject:first], &cursor) isEqualToString:second]);
        assert(NextRemote(targets, [NSSet setWithArray:targets], &cursor) == nil);
        assert(NextRemote(@[], [NSSet set], &cursor) == nil);
        assert(IsObservedClone(@0, @0, first, first, @"Bluetooth", @"Nintendo RVL-CNT-01", NO));
        // A never-provisioned identity uses the same clone policy; no address allowlist.
        NSString* unseen = @"12:34:56:78:9A:BC";
        NSArray* three = @[unseen, first, second];
        NSSet* connected = [NSSet setWithArray:@[first, second]];
        cursor = 1; // The failed third attempt must not fall through to connected remotes.
        assert([NextUnconnectedRemote(three, [NSSet set], connected, &cursor) isEqual:unseen]);
        assert([NextUnconnectedRemote(three, [NSSet set], connected, &cursor) isEqual:unseen]);
        assert(NextUnconnectedRemote(three, [NSSet setWithObject:unseen], connected, &cursor) == nil);
        cursor = 1;
        assert([NextUnconnectedRemote(three, [NSSet set], [NSSet set], &cursor) isEqual:first]);
        assert(IsObservedClone(@0, @0, unseen, unseen, @"Bluetooth", @"Nintendo RVL-CNT-01", NO));
        assert(!IsObservedClone(@0, @0, second, first, @"Bluetooth", @"Nintendo RVL-CNT-01", NO));
        assert(!IsObservedClone(nil, @0, first, first, @"Bluetooth", @"Nintendo RVL-CNT-01", NO));
        assert(!IsObservedClone(@0, @0, first, first, @"USB", @"Nintendo RVL-CNT-01", NO));
        assert(!IsObservedClone(@0, @0, first, first, @"Bluetooth", @"Keyboard", NO));
        assert(!IsObservedClone(@0, @0, first, first, @"Bluetooth", @"Nintendo RVL-CNT-01", YES));
        NSDictionary* profile = @{@"schema": @1, @"status": @"complete", @"devices": @[
            @{@"name": @"Nintendo RVL-CNT-01", @"address": unseen},
            @{@"name": @"TV", @"address": first},
            @{@"name": @"Nintendo RVL-CNT-01", @"address": @"bad"}, @42]};
        assert([ProfileAddresses(profile) isEqualToArray:@[unseen]]);
        assert(ProfileAddresses(@[]).count == 0);
        assert(ProfileAddresses(@{@"schema": @1, @"status": @"error", @"devices": profile[@"devices"]}).count == 0);
        uint16_t buttons;
        uint8_t pressed[] = {0x30, 0, 8}, home[] = {0x30, 0, 0x80};
        uint8_t released[] = {0x30, 0, 0}, payload[] = {0, 4};
        uint8_t ack[] = {0x22, 0, 0, 0x11, 0};
        assert(ReadButtons(0x30, pressed, 3, &buttons) && buttons == 8);
        assert([WiimoteButtonNames(buttons) isEqualToString:@"A"]);
        assert(ReadButtons(0x30, home, 3, &buttons) && buttons == 0x0080);
        assert([WiimoteButtonNames(buttons) isEqualToString:@"Home"]);
        assert(ReadButtons(0x30, released, 3, &buttons) && buttons == 0);
        assert(ReadButtons(0x30, payload, 2, &buttons) && buttons == 4);
        assert(!ReadButtons(0x22, ack, 5, &buttons));
        assert(!ReadButtons(0x30, pressed, 1, &buttons));
        assert(!ReadButtons(0x30, ack, 5, &buttons));
        assert(!ReadButtons(0x30, NULL, 3, &buttons));
        puts("Remote policy tests passed");
    }
}
