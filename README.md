# WiimotePair for macOS

A native utility for pairing and maintaining a Wii Remote connection on macOS, including the **Wii Remote Plus with MotionPlus Inside (`Nintendo RVL-CNT-01-TR`)**.

This version fixes an issue where the remote completes pairing, flashes all four LEDs, and powers off a few seconds later. The app preserves the pairing session until macOS finishes creating the physical HID device, then initializes the remote through IOHID.

## Requirements

- macOS 12.0 or later;
- a Mac with Bluetooth;
- Xcode with the macOS SDK to build from source;
- an original `RVL-CNT-01` or `RVL-CNT-01-TR` Wii Remote.

The `RVL-CNT-01-TR` is identified by:

- Vendor ID: `0x057e`;
- Product ID: `0x0330`.

The original Wii Remote uses Product ID `0x0306`.

## Required permissions

WiimotePair only needs permission to use **Bluetooth**.

On the first launch, macOS should display a Bluetooth access prompt. Choose **Allow**. You can review or change this permission later at:

```text
System Settings → Privacy & Security → Bluetooth → WiimotePair
```

Make sure the switch next to WiimotePair is enabled. If Bluetooth access was previously denied, quit the app completely with `Command-Q`, enable it in System Settings, and open the app again.

The app does **not** require:

- Accessibility access;
- Input Monitoring;
- Full Disk Access;
- access to Documents, Desktop, or other personal files;
- an administrator password for normal pairing and reconnection.

The downloadable build is signed ad hoc rather than notarized by Apple. If Gatekeeper blocks the first launch:

1. Control-click `WiimotePair.app` and choose **Open**.
2. Confirm **Open** in the dialog.
3. If that option is unavailable, open **System Settings → Privacy & Security**, locate the blocked-app message, and choose **Open Anyway**.

Only bypass Gatekeeper for a build obtained from this repository or produced locally with `Scripts/build.sh`.

## First-time pairing

1. If the remote is already listed but does not work, remove it from **System Settings → Bluetooth**.
2. Open `WiimotePair.app`.
3. Press only the red **SYNC** button behind the battery cover.
4. Do not press any other buttons during pairing.
5. Wait until the app displays a message similar to:

   ```text
   HID: connected and receiving • report 0x30
   ```

macOS may display the `RVL-CNT-01-TR` as a “Game Controller.” This is only its Bluetooth UI classification and does not prove that the physical HID session is ready.

## Reconnecting later

After the first successful pairing, do not use the SYNC button again:

1. Open WiimotePair.
2. Press `A`, `1`, or another normal button once.
3. Wait for `HID: connected and receiving`.

Use the red **SYNC** button only when you need to pair the remote again from scratch. If reconnection fails, quit and reopen the app or toggle Bluetooth off and on before retrying.

## Status messages

- `ACL disconnected`: there is no basic Bluetooth connection; press a button on the remote.
- `ACL connected`: macOS sees the Bluetooth device, but the physical HID has not appeared yet.
- `physical device open`: the IOHID device was found and is being initialized.
- `waiting for first packet`: the initial commands were sent successfully.
- `connected and receiving`: a real input report confirmed that the connection works.
- `another compatible controller is in use`: another app has exclusive access to a compatible HID device. WiimotePair continues monitoring other matching devices.

## Architecture

The connection flow is:

```text
Bluetooth discovery
        ↓
Pairing with a binary PIN
        ↓
macOS HID service opens the L2CAP channels
        ↓
IOHIDManager finds the physical Nintendo device
        ↓
IOHIDDeviceOpen
        ↓
Reports 0x11, 0x12, and 0x15
        ↓
The first input report confirms the connection
```

The app does not open L2CAP channels `0x11` and `0x13` directly. Those channels are owned by the macOS HID service. Opening them simultaneously from the app causes contention with `bluetoothd`, timeouts, and disconnections.

The IOHID matching dictionaries also use `GCSyntheticDevice = false`, preventing the app from opening the synthetic gamepad created by GameController instead of the physical Wii Remote.

### Main components

- `IOBluetoothDeviceInquiry`: discovers nearby remotes;
- `IOBluetoothDevicePair`: performs pairing with the binary PIN derived from the Mac Bluetooth address;
- `IOHIDManager`: detects physical `057e:0306` and `057e:0330` devices;
- `IOHIDDeviceSetReport`: configures the player LED, report mode, and status request;
- input-report callback: confirms that the HID session is actually functional.

## Quick build

Run this command from the repository root:

```bash
./Scripts/build.sh
```

The script:

1. builds the Release configuration;
2. creates `dist/WiimotePair.app`;
3. applies an ad hoc signature with the Bluetooth entitlement;
4. verifies the signature;
5. creates `dist/WiimotePair.zip`.

Generated files are stored in `dist/` and are not tracked by Git.

## Building with Xcode

1. Open `WiimotePair.xcodeproj`.
2. Select the **WiimotePair** scheme and **My Mac** destination.
3. To use a development signature, select your team under **Signing & Capabilities**.
4. Choose **Product → Build**.

If no “Mac Development” certificate is installed, use `Scripts/build.sh` to create an ad hoc signed build for local testing.

## Permissions and security

The required user permission and Gatekeeper steps are described in [Required permissions](#required-permissions). The app carries this Bluetooth entitlement:

```text
com.apple.security.device.bluetooth
```

Pairing still depends on private `IOBluetooth` interfaces to send the binary PIN required by a Wii Remote. This version is therefore intended for testing and direct distribution, not for the Mac App Store.

## Troubleshooting

### The remote appears connected but is powered off

“Connected” in System Settings may represent only the ACL link. Check WiimotePair instead; the connection is considered functional only after `HID: connected and receiving` appears.

### All four LEDs flash and then turn off

Remove the remote from Bluetooth settings, open this version of WiimotePair, and pair it again using only the red SYNC button.

### Another compatible controller is in use

Quit other instances of WiimotePair, Dolphin, WiiController, or similar controller utilities. Then open only the app from `dist/WiimotePair.app`.

### The physical HID is found but cannot be opened

Quit other applications that may be using the remote, reopen WiimotePair, and reconnect. Also verify Bluetooth permission under **Privacy & Security**.

### Xcode cannot find a development certificate

Run `./Scripts/build.sh` to create an ad hoc build, or configure an Apple Developer account in Xcode.

## Origin and license

Based on [dolphin-emu/WiimotePair](https://github.com/dolphin-emu/WiimotePair). This project is licensed under GPL-2.0-or-later; see `LICENSES/GPL-2.0-or-later.txt`.
