# Activation interruption: September 5, 2026

> Historical investigation record. Version numbers, paths, and behavior below describe the experiments at that time. See the README for current behavior and compatibility.

This records the investigation before the 0.4.0 implementation described below.
Physical flicker-free output has not been photometrically verified.

## Observations

- A controlled activation from the Apple XDR preset spent about 179 ms selecting
  the Apple Display preset. Its first brightness write completed at 251 ms and
  the 280 ms ramp ended at 543 ms.
- The native trace recorded no zero brightness target, asleep display, or
  resolution/refresh-rate change. This does not exclude a physical blackout
  between samples or a compositor interruption. Physical confirmation of the
  isolated test is pending.
- Runtime inspection of MonitorPanel showed that `setActivePreset:` forwards
  the display ID and preset index into the native preset path. It does not
  expose a fade duration. Inspection found no verified alternative instant
  setter. `PresetInstantSwitch` in display information is not evidence that
  an application can suppress every visible transition.
- Apple's documented `CGAcquireDisplayFadeReservation` returned 1006,
  `kCGErrorNotImplemented`, on this Mac/build. No fade operation was issued.
  Reserving the fade hardware therefore is not a usable workaround here.
- In a separate bounded comparison with the Apple Display preset already
  selected, two activations began writing brightness in 15 and 18 ms. Their
  ramps completed in 319 and 310 ms. Both reached and held 650 driver-reported
  nits. Disable preserved that test's starting preset; final cleanup restored
  the user's original XDR preset, brightness, gamma fingerprint, mode, and caps.

## Product decision

Keeping the direct-control preset for the controller session would remove
repeated preset changes from boost toggles. Initial configuration could still
blink. Even while boost is off, macOS would tone-map HDR against the 500-nit
preset; quitting or recovery would need to restore the original preset. This
is a visible behavior tradeoff, not a verified way to make the first activation
instant or preserve original HDR rendering while off.

Restoring the original preset on every disable preserves the existing off
behavior, but retains the suspect transition on the next activation. The
previous no-preset experiment allowed asynchronous OS writes to replace the
requested level. It is not ready to substitute for the direct backend.

The user explicitly chose to retain the prepared configuration between toggles.
No permission database was changed and no software gamma backend was substituted.
Brightness key delivery remains a separate unresolved issue.

Read-only `Tools/WatchPanel.swift` now includes awake state, mode, and linear
brightness in its trace. The rebuilt probe compiled successfully. Evidence and
the source checkpoint are under ignored `local-results/smooth-activation/`.

## References

- [Apple: reserving fade hardware](https://developer.apple.com/documentation/coregraphics/cgacquiredisplayfadereservation(_:_:))
- Installed SDK `CoreGraphics/CGError.h`: error 1006 is not implemented.
- [BetterDisplay direct control discussion](https://github.com/waydabber/BetterDisplay/discussions/4983): the maintainer describes selecting the standard SDR preset and its HDR tone-mapping consequence.

Driver-reported nits and successful writes are not photometric measurements or
proof of flicker-free output.

## 0.4.0: retain the prepared configuration

Explicit boost-off restores the brightness values still owned by the controller
but retains the Apple Display preset and transparent EDR surface. Subsequent
activation reads the current native brightness and starts its ramp without
reselecting the preset or recreating/presenting the surface. No display setup
is performed just by launching the app.

The recovery record now separates the session's original preset from each
activation's brightness baseline. Prepared/off records own no brightness writes.
Manual brightness changes while off become the next activation's baseline and
are preserved on quit. The original preset survives repeated toggles and a
crash while off. Existing journals without the new field remain readable.
Quit, EOF, heartbeat expiry, and the existing sleep/session/thermal safeguards
release the prepared setup. A later foreign preset is not overwritten on quit.

A live regression test caught DisplayServices completing its native scalar
write after a slider command had interrupted activation. Both physical caps
remained at the slider target, but the driver level reverted to the scalar's
standard level. The controller now allows one guarded completion 50 ms after an
immediate command during the first 100 ms of its own native handoff. It requires
the same panel/preset/scalar, both caps still owned, and the specific standard
level readback. Revision checks cancel it on newer input or disable. It does not
delay input, repeat indefinitely, or reassert against unrelated native changes.

The test client now waits for a fresh status after its hold interval instead of
treating an earlier queued observation as the final steady state.

When retaining the SDR preset, boost-off restores the original normal SDR light
level rather than replaying an HDR-mode backlight reading that can be as high
as 1600. This conversion is limited to still-owned level/backlight entries and
only applies while the prepared SDR preset remains selected. Foreign writes
and presets retain their ownership protections.

## Verification and installed handoff

- 110 policy checks passed, including legacy/prepared journal decoding,
  repeated-session preset ownership, off-state brightness preservation,
  bounded handoff guards, and SDR restoration after an HDR-mode baseline.
- The live controller suite passed the complete range, rapid input, interrupted
  activation, off-state restoration, EOF, heartbeat expiry, and crash recovery.
- Three prepared toggles began brightness writes at 8.29, 9.77, and 6.39 ms in
  the latest complete live run. The 5-second native trace retained preset 1,
  the awake state, and the same mode throughout repeated on/off cycles.
- A pending native handoff was cancelled by disable; no old target replayed.
  Manual native brightness at 62.5% while off became 100% on reactivation, and
  quit preserved the manual native value while restoring the session preset.
- Crash recovery while prepared/off restored the original preset. Full test
  cleanup restored the starting native brightness, preset, mode, gamma, and caps.
- Version 0.4.0 (7) was installed at `/Applications/XDR Brightness.app` after
  successful build and validation. Deep/strict code-signature verification and
  both installed executable hashes matched the build:
  main `575c04e61ac34eebb5ea6849e5ef135e5e18b1e34f3eb9be54359f0cfc60c04a`;
  helper `ae889af27991e8e27d2afc96a35b23974c2868ea7f575c573ece4003686d7927`.
- Both installed processes launched. The installed window showed boost off
  with "Display setup stays ready until you quit." A user interaction changed
  the UI during the automated activation smoke check; its fresh state was
  inspected rather than forcing another toggle.
  The final UI observation showed the switch on at 160%; the user's current
  setting was left in place.

The first setup can still blink, and runtime timing varies with system load.
The change removes subsequent preset switches; these checks do not establish
photometrically flicker-free output. Physical brightness-key interception is
still blocked by the existing event-access problem, separate from this change.
