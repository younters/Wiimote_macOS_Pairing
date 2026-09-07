# WiimotePairPlus for macOS

A native macOS utility that pairs and reconnects Wii remotes, including the tested third-party remotes that report HID vendor/product IDs of zero.

Version **1.4.0 (18)** adds guided, timed pairing with an explicit PIN mode, a controller picker, named button display, and portable remote-identity import/export. This candidate is ad hoc signed and has not been notarized.

## Use

1. Download the DMG from [Releases](https://github.com/younters/Wiimote_macOS_Pairing/releases), open it, and drag WiimotePair into Applications. Open the app and allow Bluetooth access if prompted. This build is not notarized; if macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** after attempting to launch it, provided you trust the download.
2. Select the intended remote and a pairing mode, then click **Prepare Pairing**. The app stops discovery before arming the timed attempt.
3. Follow the instruction shown in the app, then click **Pair Now** while the LEDs blink:
   - **Red SYNC · Save pairing:** press the red **SYNC** button inside the battery compartment. This mode supplies the binary PIN derived from the Mac Bluetooth adapter address.
   - **1 + 2 · Guest PIN:** turn the remote off, then hold **1 + 2** together. This mode supplies the binary PIN derived from the remote address. macOS may still remember the remote's identity or pairing state.
4. Wait for **Wii Remote Connected**. Readiness requires a valid button report, not just a pairing callback or command acknowledgment.

Automatic pairing remains available and uses the red-SYNC PIN strategy. It alternates Bluetooth Classic discovery with attempts for remembered remotes. **Stop Auto Pair** pauses new attempts while preserving a working HID connection; **Start Auto Pair** resumes them.

If the selected target is already paired, wake it with **A**, **1**, or another regular button and use the guided action. The app reconnects it without removing its existing macOS pairing or Bluetooth bond. Do not press SYNC merely to reconnect an already paired remote.

Choose **Pair Another Remote** to hand the current controller to macOS/your controller application and automatically discover or reconnect another remote. This is not a multi-controller input viewer. Previously handed-off controllers are skipped until **Command-R** resets the selection.

**Show Details** opens timestamped diagnostics. **Copy Diagnostics** copies the current log and version information. The main window displays pressed buttons by name, including **Home**, and reports unknown button bits explicitly. Logs include remote addresses and a bounded number of input samples; PINs and link keys are omitted.

## Compatibility

- macOS 12 or later on Apple silicon or Intel. The build script produces and verifies a universal executable.
- Official `Nintendo RVL-CNT-01` and `Nintendo RVL-CNT-01-TR` HID identities `057e:0306` and `057e:0330` are supported by the matching policy. Physical pairing and input on these revisions remain unverified for this candidate.
- Two third-party `Nintendo RVL-CNT-01` controllers with Bluetooth transport, VID/PID `0000:0000`, and HID serials matching their Bluetooth addresses completed pairing and produced confirmed button input in live build 17; HOME presses and releases were also verified on one remote. The exception requires all of those properties and excludes synthetic devices.
- A third similar controller has not completed authentication and remains unsupported in practice until live input succeeds.
- Newly discovered Wii-named remotes are remembered, including names delivered after the initial discovery callback. Remembered addresses and macOS's existing Wii pairings are tried directly, bypassing name-filtered discovery.
- Some clones respond to the Wii's limited inquiry (LIAC) and may be absent from ordinary Mac discovery. This build does **not** claim a working low-level LIAC scanner on macOS. Their identities must first be learned through supported discovery or imported from a completed discovery profile. Preferences and Bluetooth bonds do not travel inside the app ZIP.
- MotionPlus, extensions, speaker/audio, Dolphin integration, and long-duration reliability have not yet been verified with this clone.

For another installation, a developer can provision independently verified controller addresses in the `KnownRemoteAddresses` array under the `org.dolphin-emu.WiimotePair` preferences domain. This is a setup/debugging fallback, not a requirement to type an address for each pairing attempt. Never add unrelated nearby devices.

## Build and test

Requires Xcode and the macOS SDK:

```bash
./Scripts/test.sh
./Scripts/build.sh
./Scripts/package-dmg.sh
```

The test runner checks address validation, fair target selection and exclusions, exact clone identity matching, and button parsing using the actual policy functions used by the app. It needs no Bluetooth hardware and does not replace live pairing tests.

The build script produces:

- `dist-candidate/WiimotePair.app` — universal Release app, signed ad hoc by default, with GPL license included.
- `dist-candidate/WiimotePair-1.4.0.dmg` — drag-to-Applications installer, with SHA-256 sidecar.
- `dist-candidate/WiimotePair.zip` — candidate archive.
- `dist-candidate/WiimotePair.zip.sha256` — archive checksum.

Verify the archive with `cd dist-candidate && shasum -a 256 -c WiimotePair.zip.sha256`.

Ad hoc signing is suitable for local testing. Normal Gatekeeper trust requires Developer ID signing and notarization; this release is distributed ad hoc signed with broader hardware/macOS validation still pending. Pairing depends on private IOBluetooth APIs; missing required selectors are handled with a diagnostic rather than attempting an unsupported call.

## Troubleshooting

- **Bluetooth access:** enable WiimotePair in System Settings → Privacy & Security → Bluetooth. The app waits for Bluetooth availability instead of quitting when Bluetooth is turned off.
- **Waiting for a remote:** keep it close, wake it, and allow time for discovery and remembered-device retries. A sleeping target can consume one full attempt.
- **Bluetooth connected, HID waiting:** copy diagnostics. A link alone does not establish controller input; do not broadly remove HID filters.
- **HID in use:** another app may own the device. This state is reported separately from confirmed input in WiimotePair.
- **Copied ZIP on a different Mac:** device preferences and Bluetooth bonds are per-Mac. Discover the remote there or import a completed identity profile, then pair it on that Mac.

See [portable build and signing](Documentation/PORTABLE_BUILD.md) and the [1.4.0 validation record](Documentation/RELEASE_1.4.0.md) for release details and remaining checks.

## License and origin

Based on [GabrielLascoskiFerraz/WiimotePairPlus](https://github.com/GabrielLascoskiFerraz/WiimotePairPlus), originally [dolphin-emu/WiimotePair](https://github.com/dolphin-emu/WiimotePair). GPL-2.0-or-later; see [LICENSES/GPL-2.0-or-later.txt](LICENSES/GPL-2.0-or-later.txt). Wii is a Nintendo trademark; this project is not affiliated with Nintendo.
