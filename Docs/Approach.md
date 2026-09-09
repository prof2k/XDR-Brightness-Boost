# Brightness controller: implementation and validation

> Historical investigation record. Version numbers, paths, and behavior below describe the experiments at that time. See the README for current behavior and compatibility.

Current 0.4.0 behavior retains the direct-control preset between boost toggles.
See [the activation change and validation](Activation-investigation.md) for the
current lifecycle; older version sections below are historical evidence.

Scope: MacBookPro18,3 (14-inch M1 Pro), macOS 27.0 build 26A5416b.
The app controls the existing built-in panel. It creates no virtual display,
changes no resolution, and writes no gamma tables.

## Current interaction contract — 0.3.0

The standard macOS switch enables one 0–160% control. Below 100%, the requested
level is 0–500 nits; above it, the scale interpolates from 500 to 1600. Enabling
maps the existing native slider position into the extended range, so native
100% targets 160%. Activation begins at the prior SDR level and uses a 280 ms
smoothstep ramp. Slider/key commands cancel the ramp and apply immediately,
without the previous 150 ms debounce.

A Core Graphics event tap in the GUI consumes only brightness media-key down,
repeat, and up events while active. Normal steps are 6.25 points; Option–Shift
uses 1.5625. It forwards intent to the worker; it never writes the panel or reads
text-key content. The tap is disabled logically while control is off. Other
media keys pass through. A system-disabled tap is re-enabled.

macOS must allow the active system-defined event tap to intercept keys. The app
provides an explicit Core Graphics permission request and System Settings link.
Until a tap is successfully enabled,
the system still handles brightness keys. Native scalar changes are observed
without turning the app off or writing back continuously. The next explicit
slider/key command reacquires native control. A custom brightness HUD is not
implemented.

There is no process-name blockade for BetterDisplay or other controllers. Gamma
changes also do not deactivate the app. The user controls coexistence. Competing
writes can affect output, so the app reports actual readback and does not claim
that its requested value is still applied when another writer changes it.

## API boundary

Apple's EDR APIs describe rendering an application's own HDR surfaces. They do
not establish a supported contract for changing every other app's SDR luminance.
Headroom is a ratio, not measured emitted brightness.

- [Apple: Explore HDR rendering with EDR](https://developer.apple.com/videos/play/wwdc2021/10161/)
- [Apple: HDR rendering in a Metal layer](https://developer.apple.com/documentation/metal/displaying-hdr-content-in-a-metal-layer)
- [Apple: current screen EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumextendeddynamicrangecolorcomponentvalue)
- [Apple: creating an event tap](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple: checking Accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple: NSSwitch](https://developer.apple.com/documentation/appkit/nsswitch)
- [Apple: specifications for this Mac](https://support.apple.com/en-us/111902)

Apple specifies 500 nits SDR, 1000 nits sustained full-screen HDR, and 1600 nits
peak HDR. The upper target is not a promise of sustained output. The user
explicitly authorized a narrowly isolated unsupported native interface.

`NativePanel.m` owns the unsupported MonitorPanel preset selectors,
DisplayServices brightness calls, and these AppleCLCD2 properties:

- `BLNitsCap`
- `limit_max_physical_brightness`
- `IOMFBIndicatorNitsCap`
- `IOMFBBrightnessLevel`

The observed encoding is nits × 65536. Individually serialized property writes
were verified; grouped dictionary writes did not reliably apply all four keys.
[IORegistryEntrySetCFProperty](https://developer.apple.com/documentation/iokit/1514882-ioregistryentrysetcfproperty)
is the documented transport, not a contract for these driver properties.
Runtime selector encodings and symbols are checked. The hardware/build allowlist
and internal-panel identity check remain in place. Thermal-protection switches
are not modified.

Brightness media-key constants were checked against Apple's installed SDK:
`IOKit/hidsystem/ev_keymap.h` and `IOKit/hidsystem/IOLLEvent.h`. The decoder uses
system-defined subtype 8, brightness up/down 2/3, and down/up states 0x0a/0x0b.

## Native transition and limitations

The controlled path selects the existing Apple Display (P3-500 nits) preset,
presents a fully transparent one-point Metal EDR surface, and sets the native
scalar near maximum (0.999). Driver properties then provide the whole range.
The surface uses `rgba16Float`, `extendedLinearSRGB`, and
`wantsExtendedDynamicRangeContent`, clearing RGBA to (0, 0, 0, 0). It has no
bright pixel or fullscreen overlay and no continuous redraw timer. Window and
Metal resources are prepared while hidden before activation.

The preset is selected before presenting the EDR surface to avoid starting an
HDR ramp and then cancelling it with a preset change. The initial driver level
uses the original linear native brightness, rather than jumping straight to a
fixed boosted value. A short ramp then raises it to the expanded target.

Live alternatives were rejected, rather than silently shipped:

- Preserving the XDR preset while writing the driver allowed the OS to overwrite
  the level during HDR entry.
- Omitting the EDR surface allowed later native brightness drift.
- Leaving the original native scalar below maximum also caused overwritten
  ramp frames and failed the steady-slider test.

The selected path passed the repeated control and recovery sequence. Its most
recent complete run recorded approximately 233 ms of native preparation plus
280 ms of ramping (about 517 ms total). Slider/key protocol commands completed
in approximately 6 ms. These are software/driver observations, not photometric
measurements. There is still a native preset transition; zero latency and
universally flicker-free behavior have not been established.

macOS tone maps against the 500-nit preset while physical output is rescaled.
This differs from the original 1600-nit HDR reference behavior. Neutral gamma
tables alone do not prove identical HDR appearance.

## Recovery and ownership

The nested helper app alone writes the panel, under an exclusive lock. It saves
the original state and expected writes before each mutation. Revision tokens
cancel stale ramp frames when new input, disable, or recovery occurs. Request
IDs prevent old worker acknowledgements from reversing newer UI intent.

EOF, disable, quit, and heartbeat expiry restore values still identifiable as
owned. A killed worker leaves its recovery record; startup and GUI recovery
attempt restoration. Recovery runs before Metal setup, so rendering preparation
cannot prevent it. Legacy records still restore the native scalar they owned.
A different boot/panel identity invalidates old records, and failures retain them.
External changes are preserved rather than overwritten during restoration.

## Completed checks on 2026-09-05

- 88 policy checks, including both range boundaries, expansion on enable,
  brightness-key decoding/repeat/fine steps, unrelated-key pass-through,
  monotonic ramp interpolation, ownership, and stale-command cancellation.
- The physical controller expanded the native 81.25% position to 130%, with a
  smooth ramp ending at 1050 driver-reported nits.
- Key commands crossed 100% in both directions, and the controller reached zero
  then increased again without deactivating.
- A native brightness-up adjustment without the event tap released the owned
  zero cap and reached 31 nits. Recovery uses cap ownership, because the native
  level may report a nonzero value while the app still owns a zero physical cap.
- Rapid slider changes applied the latest target; input during activation
  cancelled the pending endpoint. The steady target remained applied.
- EOF, heartbeat expiry, and SIGKILL followed by durable recovery restored the
  original preset, native brightness, gamma fingerprint, mode, and fixed caps.
- An external native scalar change remained in place, with control still on.
  The next owned key command resumed full-range control.
- Starting BetterDisplay while active did not switch the controller off.
  Enabling with BetterDisplay already running also succeeded.
- 160% reached 1600 driver-reported nits and returned below 100%.
- BetterDisplay was returned to its initially closed state. The exact original
  native brightness, preset, gamma fingerprint, and fixed caps were verified.

Live traces and snapshots are ignored under `local-results/controller-update/`.
The first attempted run found the display asleep and made no brightness changes.
The verification runs used bounded keep-awake assertions.

## Remaining verification

The Mac was locked during the installed UI/key-permission check. Actual physical
key interception and suppression of the system HUD still require an unlocked
session with Accessibility granted to the installed app. Protocol tests do not
substitute for that check. No custom popup is claimed.

Visual flicker/white clipping, emitted luminance, fullscreen HDR video, long-term
idle cost, sleep/lid/lock transitions, thermal throttling, and other hardware/OS
combinations still need physical acceptance testing. The app releases control
on sleep/session loss or thermal events and does not automatically reactivate.

## Reference research

BetterDisplay distinguishes direct/native control from software color-table and
Metal methods. Its old custom native preset is unavailable since macOS 26.3.
A preset modifies the existing display; it is not a virtual display.

- [BetterDisplay: XDR methods](https://github.com/waydabber/BetterDisplay/wiki/XDR-and-HDR-brightness-upscaling)
- [BetterDisplay: direct-control development](https://github.com/waydabber/BetterDisplay/issues/5242)
- [BetterDisplay: direct-control discussion](https://github.com/waydabber/BetterDisplay/discussions/4983)
- [BrightIntosh: gamma implementation](https://github.com/niklasr22/BrightIntosh/blob/15892f27ba11d2c5bca9f7d0c237b02541a45d90/BrightIntosh/GammaTechnique.swift)
- [Lunar: API declarations](https://github.com/alin23/Lunar/blob/8a21ffe302a00890d9f5d5101536cdd2a4631be8/Lunar/DDC/Lunar-Bridging-Header.h)

No third-party implementation code was incorporated into this project.

## Installed handoff

Version 0.3.0 (4) was installed at `/Applications/XDR Brightness.app`. The GUI
and nested helper hashes matched the signed build, deep strict signature
verification passed, and both installed processes were running. There was no
pending recovery record. The app was launched with control off; the Mac remained
locked, so the Accessibility-dependent physical-key/UI check remains pending.

## 0.3.1 key-access diagnosis

The installed slider was exercised at 130% and 160%; native readbacks reached
1050 and 1600 respectively, and the control was returned to 100%. Key capture
was unavailable: the app displayed its access/setup button while System Settings
showed an enabled XDR Brightness entry. A permission toggle refresh and restart
of the identical build did not resolve that discrepancy.

Version 0.3.1 (5) removes the hard AX preflight gate. Actual event-tap creation and
enablement, both enforced by macOS, now determine availability. This is not a
permission bypass. The installed build still reported capture unavailable, so
physical key interception is not yet verified. A stale signing requirement is
suspected: these local builds use ad-hoc signatures with a changing designated
code hash, and no valid local signing identity was found. Re-adding the exact
installed application to the permission list remains a manual follow-up; the UI
automation service failed before completing that step. No other application's
permission was changed. The new build passed all 88 policy checks and installed
with matching main/helper hashes and deep signature verification.

## 0.3.2 reference comparison and physical-key failure

On September 5, 2026, inspected the current BrightIntosh `main` archive, its
`AppDelegate.swift`, `BrightnessManager.swift`, and `GammaTechnique.swift`.
BrightIntosh registers custom shortcuts with KeyboardShortcuts, leaves native
brightness-key control to macOS, and adjusts its gamma-based boost in response
to screen-parameter / EDR changes. Its gamma backend also implements integrity
polling, HDR-trigger recovery, and upward stabilization delays. These are a
different tradeoff from direct physical control; no GPL implementation was
copied into this app.

BetterDisplay's wiki describes combined brightness, separate direct and
software methods, and event-access setup for native keyboard control. Its
current direct-control implementation is closed source. MediaKeyTap's public
implementation and Apple's Core Graphics SDK informed these changes:

- Use `.cgSessionEventTap` with an active filter and only `NX_SYSDEFINED` in
  the mask. MediaKeyTap uses this location; Apple's SDK documents extra
  restrictions at the HID entry point. This change alone did not fix delivery.
- Ask for event control using `CGRequestPostEventAccess`, instead of treating
  broad Accessibility trust as equivalent to the tap's permission. Preflights
  do not gate an otherwise usable tap.
- Remove repeated permission preflights while the tap is enabled. They were
  unnecessary work on the key run loop.
- Reinsert the tap on explicit activation, foregrounding while active, and
  at the start of a slider mouse/keyboard interaction. Do not continuously
  reorder taps or disable BetterDisplay. Head insertion only establishes
  priority at that moment; another utility may subsequently install a new tap.
- Log tap availability changes and handled brightness steps only. No text
  keys are subscribed to or logged.
- Support an existing stable signing certificate via `XDR_CODESIGN_IDENTITY`.
  No certificate or trust policy was created or changed. Default development
  signing remains ad-hoc and may invalidate old permissions after rebuilds.

Observed evidence and limits:

1. TCC logs for the installed app explicitly denied `kTCCServiceListenEvent`
   and `kTCCServicePostEvent` requests (`authValue=0`, `authReason=5`), despite
   Settings showing XDR Brightness enabled. The meaning of reason 5 was not
   independently established; do not call it proof of a signing mismatch.
2. A scoped `tccutil reset Accessibility local.elijah.XDRBrightness` completed.
   A subsequent session tap became available with mask 16384 and options 0,
   even though the event-control preflight still reported false.
3. The user then tested physical brightness keys at 100% and confirmed the app
   stayed at 100%. No handled brightness steps appeared in its log. A native
   trace showed the scalar moving and returning to 1 while the physical cap
   stayed at 500 nits. An enabled tap does not prove delivery or suppression.
4. BetterDisplay was running during this failed test. Its registered session
   tap used mask 17408 and options 0. Competing interception is a plausible
   delivery failure, not yet proven by a successful comparison. Numerical tap
   IDs do not establish processing order.
5. The latest build includes explicit tap reordering and removal of the
   recurring preflight. All 88 policy checks passed and the build succeeded.
   It was installed as 0.3.2 (6), with matching executable hashes and deep
   strict signature verification:
   main `29154f3c90a699290772db060725b6a7d726e8ecffbabb485f314f11b5fe1c62`;
   helper `f166955b08702fe10a6b7e1e3721142cc3fddf8fb1e2b69ad57e7575aac6c3b4`.
   The installed process launched, but reported `session tap=false`.
6. Automatic approval review rejected an app-wide permission reset and then
   the narrower, app-specific `PostEvent` reset for lack of explicit user
   authorization. Neither rejected command ran. Keyboard delivery in the
   latest build remains pending that access repair and a physical-key test.

Read-only diagnostic tools: `Tools/ProbeBrightnessKeys.swift` compares tap
capabilities in its own execution context and optionally lists one process's
tap metadata. A successful console probe is not proof of GUI-app permission.
The native trace is in ignored `local-results/key-fix/keyboard-native-trace.jsonl`.
UI automation could not synthesize `XF86MonBrightnessUp` and intermittently
failed to start, so it cannot substantiate a hardware-key success claim.

Additional primary references:
- [BrightIntosh source](https://github.com/niklasr22/BrightIntosh)
- [MediaKeyTap's event implementation](https://github.com/nhurden/MediaKeyTap/blob/master/MediaKeyTap/MediaKeyTapInternals.swift)
- [Apple: Core Graphics event-access example](https://developer.apple.com/forums/thread/707680)
- [Apple: code-signing identities and designated requirements](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
