# Portable macOS build

`Scripts/build.sh` produces a universal macOS application containing both arm64 and x86_64 executable slices. It requires Xcode command-line tools and builds the Release configuration without asking Xcode to manage a signing identity.

By default, the script replaces only the named release artifacts in `dist-candidate`, leaving the last known working build in `dist` untouched:

```sh
./Scripts/test.sh
./Scripts/build.sh
./Scripts/package-dmg.sh
```

To select another candidate location, set a project-local output directory:

```sh
WIIMOTEPAIR_OUTPUT_DIR="$PWD/dist-candidate" ./Scripts/build.sh
```

The output override must resolve beneath the project directory. The script refuses the project directory itself and paths outside it before running any removal command. Its artifacts are `WiimotePair.app`, `WiimotePair.zip`, and `WiimotePair.zip.sha256` in the selected directory.

`Scripts/test.sh` runs the Objective-C policy tests. When `python3` is installed, it also runs the Linux discovery-helper parser tests. A missing Python interpreter is reported as a skipped optional test; Python is not required to build or run the Mac application.

## Signing and use on another Mac

The default build is ad hoc signed (`codesign --sign -`). That makes the bundle internally consistent and permits local execution, but it does not establish a publisher identity and is not a substitute for Developer ID signing and Apple notarization. A ZIP downloaded on another Mac may be quarantined, and Gatekeeper can refuse its first launch. For a public release that opens normally after download, sign with a valid Developer ID Application identity and notarize the resulting archive.

The build script accepts a signing identity without embedding a developer-specific value in the repository:

```sh
WIIMOTEPAIR_OUTPUT_DIR="$PWD/dist-candidate" \
WIIMOTEPAIR_SIGN_IDENTITY="Developer ID Application: Example Organization (TEAMID)" \
./Scripts/build.sh
```

This signs the copied app with its Bluetooth entitlements before creating the ZIP. Notarization and stapling remain separate release steps because they require Apple account credentials and network access. Verify a release identity with `codesign -dv --verbose=4 dist-candidate/WiimotePair.app` and assess Gatekeeper policy with `spctl --assess --type execute --verbose=4 dist-candidate/WiimotePair.app`.

macOS Bluetooth privacy approval is stored by the receiving Mac and does not travel in the ZIP. The app's usage description causes macOS to request access when needed. Ad hoc signatures provide no stable Developer ID identity across independently rebuilt copies, so macOS may treat a replacement build as a different or changed app and ask for Bluetooth access again. Keeping the bundle identifier and a consistent Developer ID signature improves identity continuity, but privacy decisions remain under macOS control. Do not copy privacy databases, Bluetooth bonds, remembered devices, or controller identifiers into a release artifact.

Before publishing, test the exact ZIP on both Apple silicon and Intel hardware (or equivalent clean systems), confirm both architectures with `lipo -archs WiimotePair.app/Contents/MacOS/WiimotePair`, verify its signature, and check first-launch Bluetooth authorization. The universal executable makes the app CPU-compatible; OS version, Gatekeeper, signing, and Bluetooth hardware behavior still need release validation.

The optional packaging script creates a verified compressed DMG with the app, an Applications shortcut, installation instructions, and the license. A SHA-256 sidecar accompanies the image. The DMG carries the same signing limitations as the ZIP.
