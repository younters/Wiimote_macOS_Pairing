# Second Mac: automatic discovery and Pair Another Remote

## User goal

Open WiimotePair, press **Pair Another Remote**, put a new knockoff Wii remote into SYNC mode, and have it connect without typing an address, importing a profile, or configuring a specific Mac. Generic behavior is the priority. Preserve the official Wii controller already connected on this second Mac.

The user reports that v1.4.0 currently fails this workflow on the second Mac. This is not yet diagnosed there. Do not assume its cause is identical to the first Mac.

## Start here

- Repository: https://github.com/younters/Wiimote_macOS_Pairing . Published v1.4.0 build 18, universal ad hoc signed DMG. The release commit is 1a59aa61f18ea0a71ae8fd4d4d9c11ef8a4a9847.
- Determine this Mac's OS/version, running app path/build, Bluetooth approval/state, whether Dolphin is running, and what the app reports before/after Pair Another Remote. Read source and existing diagnostics first.
- Preserve the connected official controller and existing bonds. Do not reset system Bluetooth, forget devices, or move the USB dongle/VM from the first Mac. The user asked to leave those alone.
- Tell the user exactly when to press red SYNC if a timed test is needed. Do not assume a remote remains discoverable indefinitely.

## First diagnostic decision

Capture a single fresh discovery cycle after Pair Another Remote. Record scan-start return, discovery callbacks (including unnamed devices), delayed name updates, cycle completion, selected target, and any pairing/PIN/input callback. Record why a candidate was skipped.

1. **No scan starts:** investigate app scheduler/handoff gates, including `_receivedHIDReport`, `_hidOwnedByAnotherApp`, `_pairedDevice`, and timers. The official remote being connected must not prevent finding another remote.
2. **Scan runs but no clone address appears:** this is discovery, before PIN selection. Compare public inquiry and current OS capabilities. Do not claim a name-filter change can fix missing radio results.
3. **Clone appears but is ignored:** examine name arrival and classification. Current source uses Nintendo RVL-CNT-01 name matching; delayed name callbacks reuse that selection path. Determine actual advertised identity before broadening it.
4. **Clone selected but no PIN callback/input:** investigate service discovery and authentication separately. Never interpret an ACL connection alone as successful pairing.

Use one clean cycle to select the next branch. Do not repeatedly retry the same failed procedure without gathering new evidence. The user most recently requested deeper research before speculative fixes.

## Relevant first-Mac evidence

Two zero-VID/PID clones completed pairing and physical HID input. One worked through automatic remembered-target pairing and one through guided pairing. HOME press/release reports were correct; Dolphin HOME handling was not independently verified. A third clone reached ACL and HID service discovery but failed before any application PIN callback. None of this proves fresh-Mac automatic clone discovery.

Linux LIAC discovery originally supplied all three identities. The app does not compile controller addresses into its pairing policy, but the successful first-Mac workflow had learned identities available. Those preferences and OS bonds are deliberately absent from the DMG. The receiving Mac derives its own host-address PIN automatically; users should not need to configure it.

On first Mac's macOS 26.5.2, ordinary inquiry repeatedly saw a TV but missed these clones. Read-only inspection found the old direct HCI inquiry/authentication and C raw-HCI entry points were no-ops. Public IOBluetoothDeviceInquiry is functional, with no evidenced LAP selector; private CBClassicManager also has real inquiry code but no exposed LIAC option. This does not prove the second Mac has the same behavior.

Dolphin's current Linux source deliberately uses LIAC for third-party remotes. An automatic discovery companion could avoid manual address entry, but would still require another scanner and is not implemented. Prefer a verified standalone Mac path if available; do not present the fallback as already done.

## Success criteria

With an empty app identity cache (use an isolated test preference domain rather than erasing user state), an unknown compatible clone is discovered and paired after SYNC, with no manual address/profile. Pair another distinct compatible remote with no source changes. The official remote remains usable. Report discovery, PIN exchange, physical input, and reconnect results separately.

See THIRD_CONTROLLER_RESEARCH.md for sources and detailed hypotheses. Keep the released build recoverable when implementing any later fix.
