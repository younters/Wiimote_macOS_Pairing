# WiimotePairPlus 1.4.0 validation

Version 1.4.0 (18) is a release candidate. Its guided flow lets the user select a known remote, prepare a quiet discovery window, choose the red-SYNC or 1+2 guest PIN strategy, and start a timed pairing attempt. Already paired targets take the reconnect path and retain their existing macOS pairing and Bluetooth bond.

## Completed checks

- The Objective-C policy tests pass, covering address normalization, target selection, PIN bytes for both modes, exact clone identity matching, portable profile filtering, input-report parsing, and named buttons including Home.
- The Python discovery-helper parser tests pass.
- The Release configuration compiles as a universal executable with arm64 and x86_64 slices.
- Ad hoc signing and strict signature verification pass for the candidate app. This does not provide Developer ID trust or notarization.
- Live build 17 completed red-SYNC PIN exchange and received physical HID input from both previously working clones: one through automatic pairing and one through guided pairing. The guided target subsequently disconnected and recovered, so long-term connection stability remains under test.
- Selecting an already connected, paired remote through the guided flow restored input monitoring without a new PIN exchange.
- On September 7, 2026, the second clone repeatedly delivered HOME press reports (`30 00 80`) followed by release reports (`30 00 00`). HOME reaches macOS correctly in this test. Dolphin handling has not been verified.
- A subsequent source correction fixes the diagnostic labels for A/B/1/2 and the D-pad. Independent fixtures cover all eleven core buttons; this correction is included in build 18.

## Runtime limits and pending validation

On the current validation environment, the inspected `requestAuthentication` and `HCIInquiry` entry points behave as no-op stubs. The candidate does not claim an explicit fallback for those calls or working low-level LIAC discovery. Diagnostics report when authentication is not requested or confirmed rather than treating a connection alone as success.

A third similar clone still has not completed authentication. Support for that controller remains unresolved.

Live validation is partial. Build 18 includes the latest diagnostic and state cleanup changes. Clean installation on another Mac and live verification of the corrected non-HOME button labels remain pending. Successful guest-PIN pairing remains unverified; the third clone failed before a PIN request in both selected modes. Developer ID signing and notarization are needed for normal Gatekeeper trust; an ad hoc build can still be distributed with its limitations disclosed. See [PORTABLE_BUILD.md](PORTABLE_BUILD.md).
