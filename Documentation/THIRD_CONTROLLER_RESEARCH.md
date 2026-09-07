# Third-controller investigation — research only

2026-09-07. Scope: review saved evidence, application source, and primary protocol/implementation sources. No app changes, pairing attempts, Bluetooth resets, VM access, or dongle reassignment were performed for this research. Published v1.4.0 remains unchanged.

## Conclusion

The leading question is why the third controller reaches service discovery but does not produce a PIN callback or physical HID input. Service recognition/security sequencing is a stronger next investigation than changing the PIN calculation. Pairing lifecycle is worth instrumenting, but duplicate callbacks alone do not establish duplicate application attempts. The advertised device-class difference is real but is not proof of a macOS rejection rule.

A missing application PIN callback establishes only that our handler was not invoked. It does not prove that no authentication command was sent, that the remote never requested a PIN, or that authentication failed because of a wrong key. Packet-level evidence is needed to distinguish those cases.

## Saved evidence

The local captures `/tmp/wiimote-third-connection.log` and `/tmp/wiimote-third-auth.log` cover an earlier build, not the released build 18. In one recorded attempt:

| Time (MDT) | Observed event |
| --- | --- |
| 12:05:15.785 | App session requests connection; macOS starts SDP on PSM 0x0001. |
| 12:05:15.791 | A second connection message arrives for the same session/device; daemon reports duplicate addition. |
| 12:05:19.485 | ACL connection succeeds. |
| 12:05:19.544 | Security enforcement for the SDP service completes at security level zero; remote SSP support and existing link key are reported absent. |
| 12:05:20.109 | SDP parser recognizes HumanInterfaceDeviceService and logs that it is not creating a remote SDP record. |
| 12:05:22.010 | Device is removed from the connection-request queue. |
| 12:05:35.261 | ACL disconnect is recorded. |

The SDP security message is about service discovery; it does not confirm HID authentication. The remote-record message is a useful comparison point, not proof of malformed SDP. Internal statuses such as SDP result 1, disconnect reason 10722, and app callback 0x02 must not be decoded as interchangeable HCI error codes. AACP/ear-status diagnostics are generic daemon messages and do not establish that the remote was classified as headphones.

Build 16 already tried `openConnection:withPageTimeout:authenticationRequired:YES` alongside the pairing agent. It returned connection success but still produced no PIN callback before failure. Repeating that unchanged would not be a new experiment. Later build 17 also failed with the third target in guided red-SYNC and guest-PIN selections. Both working targets completed red-SYNC pairing; one also recovered after a later disconnect.

## Lead 1: pairing lifecycle

[Apple’s IOBluetoothDevicePair documentation](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevicepair) explicitly allows a single object to perform two low-level pairings. It also documents that stopping a pair removes its delegate and disconnects an established connection. This supports retaining the existing protection against stopping a completed pair.

In our source, `startPendingPairing` consumes `_pendingPairDevice` before starting. Pair delegate callbacks require `sender == _devicePair`. Those guards weaken the simple explanation that two inquiry-complete callbacks necessarily started two app attempts. However, cancellation and framework teardown remain asynchronous at the system level, and existing logs lack stable per-attempt identities.

The independent lifecycle review found exactly one application `start` call site (ViewController.m:731). It also found a concrete diagnostic weakness: repeated progress callbacks can overwrite `_attemptStage` with an earlier phase, so timeout wording may lose the furthest reached stage. A future diagnostic change should retain raw callback order and separately track the furthest phase.

The PIN reply uses the inherited private coordinator method instead of Apple's documented `replyPINCode:` API. This is a compatibility risk, but cannot explain an attempt that never reaches the application's PIN handler. If callback status 0x02 is interpreted in the HCI domain, the installed SDK names it No Connection; the callback contract also permits IOReturn values, so neither a bad-PIN nor authentication-failure diagnosis follows from that number alone.

Proposed later experiment: record attempt sequence, pair object identity, target, start/stop invocations, timer cause, and each callback. Compare one isolated guided attempt for a known-working remote with one for the third. Determine whether duplicate daemon requests follow one application start or two, and whether teardown from an earlier attempt overlaps the next. Do not suppress callbacks solely because they repeat.

## Lead 2: advertised device class and SDP identity

The [Bluetooth SIG assigned numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html) decode the saved Linux classes as follows:

| Field | Working remotes: 0x002504 | Third remote: 0x042500 |
| --- | --- | --- |
| Major device class | Peripheral | Peripheral |
| Peripheral subtype | Joystick | Uncategorized |
| Keyboard/pointing flags | Neither | Neither |
| Limited-discoverable flag | Set | Set |
| Rendering service flag | Clear | Set |

Both carry the limited-discoverable flag. This comparison does not establish that only the third needs LIAC, nor that any remote is LIAC-only. The [Generic Access Profile, section 3.2.4.4](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-62/out/en/host/generic-access-profile.html) says device class should not determine support for a specific service; service discovery supplies that information.

The application currently logs Class of Device but does not use it as a pairing rejection filter. Changing an app filter cannot fix an absent filter. An imported profile supplies an address to our app; it does not install the Linux-observed name or class into Apple's device cache.

Proposed later comparison: actual macOS name/cache state, complete HID SDP attributes and report descriptor, protocol lists for control/data channels, HIDDeviceSubclass, HIDVirtualCable, HIDReconnectInitiate, HIDNormallyConnectable, and Device ID records. Also compare remote feature/version fields. Similar boards can still advertise different firmware behavior. No evidence yet establishes which difference is causal, or an effective supported API to override the remote class.

## Lead 3: authentication and HID connection order

[WiiBrew’s protocol research](https://wiibrew.org/wiki/Wiimote#Bluetooth_Communication) describes host-initiated legacy authentication and warns against opening the interrupt/data channel before authentication on newer remotes. The existing PIN formulas match that documentation. Its behavior descriptions are a compatibility baseline, not proof that every clone implements them identically.

The current [BlueZ autopair implementation](https://github.com/bluez/bluez/blob/12f5eb726c6e9674093223d139a3fadc4937df9f/plugins/autopair.c) recognizes Wii devices by known VID/PID or name, then supplies the six adapter-address bytes in BlueZ's native Bluetooth-address representation. Its comments also describe a short interval for establishing the input service. This shows that correct PIN selection and timely profile connection are separate requirements; the historical timeout described there is not a measured deadline for this clone. The old standalone wiimote plugin has been folded into autopair in current source.

Our local runtime inspection previously found the legacy `requestAuthentication` API to be a no-op. A successful return from it therefore cannot implement a verified authentication step here. The app's IOHID initialization occurs after pairing/attachment; macOS owns the earlier Bluetooth profile establishment. Reordering application LED/status reports would not address a failure before HID exists.

Proposed later capture: compare ACL connection, SDP completion, Authentication Requested command, Link Key Request/reply, PIN Code Request/reply, Authentication Complete, encryption events, L2CAP control/data setup, and disconnection. Record event presence and timing without logging PINs or link keys. If authentication is absent, investigate the macOS profile/security trigger. If authentication occurs but callbacks are absent, investigate pairing-agent routing. If authentication succeeds but channels fail, investigate SDP/profile behavior. If data opens before authentication, investigate an ordering workaround. Native packet-capture availability on this macOS version remains to be established; this research did not activate a capture or touch the VM.

## Recommended order after research

1. Add diagnostic attempt identities and establish a clean comparison of one working target and the third.
2. Compare full SDP and the actual security/channel sequence on the Mac.
3. Choose a narrowly scoped workaround from the first observed divergence, then regression-test both working controllers.

Do not brute-force PINs, remove working bonds, broadly accept unrelated HID devices, alter the remote firmware/class, or restart the system Bluetooth service on the strength of these hypotheses.

## Deeper follow-up: generic discovery without manual addresses

The user-facing objective is: launch on another Mac, press SYNC on a previously unknown compatible remote, and let the app discover and pair it. No remote address entry, no compiled controller allowlist, and no hardcoded Mac Bluetooth address. Bluetooth still uses device addresses internally. The host-address PIN is derived automatically from the receiving Mac; it is not a user-entered configuration requirement.

### Stronger implementation evidence

[Dolphin's current Linux backend](https://github.com/dolphin-emu/dolphin/blob/a2efdf1197be8132674b90fe9cf4761df39752ed/Source/Core/Core/HW/WiimoteReal/IOLinux.cpp#L181) deliberately sets the inquiry LAP to LIAC (`0x9E8B00`), with a comment explaining third-party remote compatibility. It discovers identities dynamically and resolves their names, instead of depending exclusively on configured addresses. This is direct implementation evidence for prioritizing Wii-compatible inquiry as the route to generic discovery. Our Linux helper has already found the user's three remotes using that kind of inquiry. That does not independently establish GIAC failure on the same adapter under controlled timing, or guarantee every clone responds.

Apple's [documented inquiry API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdeviceinquiry) provides search type, duration, class criteria, and name updating, but no documented inquiry-LAP selector. Class criteria filter which results to consider; selecting the limited-discoverable service bit is not evidence that LIAC is transmitted. The documented inquiry service also throttles frequent scans. Merely scanning faster or accepting more names cannot recover a response that never reaches the application.

[InternalBlue's own macOS guide](https://github.com/seemoo-lab/internalblue/blob/master/doc/macos.md) claims support through Big Sur, with best support on Catalina. Its implementation uses the C raw-HCI path (`BluetoothHCIRequestCreate` / `BluetoothHCISendRawCommand`), so inspecting just the Objective-C HCIInquiry method does not exhaust every historical route. These exports and the real current inquiry backend need inspection on this Mac before concluding native LIAC is unavailable. Historical availability is not proof they work on Tahoe.

### Chosen architecture and proof requirements

A discovery provider should supply fresh candidate identities to the existing shared pairing path. Pairing policy remains independent of where discovery happened. Remembered addresses become a reconnect cache, not the prerequisite for adding a new controller.

Preferred provider: native macOS discovery with a verified Wii-compatible inquiry path. Before integrating it, prove an actual LIAC request reaches the controller and yields an uncached remote identity. A nonzero method body, an available symbol, or return code zero is insufficient. Keep normal discovery available and perform name/SDP validation before automatic pairing. Unknown unnamed devices should require identification rather than being paired based only on an address prefix or peripheral class.

Alternative provider, if native LIAC cannot be made reliable: an automatically connected discovery-only companion can pass freshly found remote identities to the Mac, which still performs its own pairing and host-specific PIN calculation. This removes manual address entry and per-remote imports but still requires another scanner; it must not be presented as a standalone Mac-only solution. The current JSON helper/profile import is an existing foundation, not a completed automatic companion. No VM or USB configuration was changed for this research.

A discovery fix alone may expose more remotes but cannot claim to fix the third controller's later failure. That controller is already reachable by address and has answered SDP. Treat discovery and pairing compatibility as separate acceptance criteria.

### Acceptance tests for the intended experience

- Start with an empty app identity cache on another Mac. A previously unknown compatible remote appears and pairs after SYNC, with no address supplied by the tester.
- Repeat with another identity of the same supported behavior; no source/configuration edits.
- Verify the receiving Mac supplies its own derived PIN, and that an exported identity never carries another host's pairing key.
- Confirm a nearby TV is not selected, slow/missing names remain visible as diagnostic outcomes, and one failed controller does not prevent discovering others.
- Preserve input and reconnect for the two currently working controllers. Validate the third independently through actual HID input rather than an ACL or pairing callback alone.

[Apple's Bluetooth developer page](https://developer.apple.com/bluetooth/) provides PacketLogger through Additional Tools for Xcode. Native packet capture should first prove that it records real known traffic before relying on an empty trace as evidence. A capture setup problem must not be mistaken for absent authentication.

### Native runtime audit result (macOS 26.5.2)

Read-only Objective-C metadata and implementation-byte inspection found substantive code for IOBluetoothDeviceInquiry and private CBClassicManager inquiry. Exposed controls include duration, duplicate reporting, RSSI, class/service criteria, but no evidenced LAP selector. This is evidence about inspected interfaces, not a proof that no undocumented daemon mechanism exists.

The exported C functions BluetoothHCIRequestCreate and BluetoothHCISendRawCommand, plus the inspected HostController inquiry and IAC-LAP methods, immediately execute `mov w0, #0; ret`. Consequently, the historical InternalBlue path cannot provide LIAC through those entry points on this runtime. No Bluetooth operations were invoked during inspection. A second Mac may run a different OS and must be checked independently.
