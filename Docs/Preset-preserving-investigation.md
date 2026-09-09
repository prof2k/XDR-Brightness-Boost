# Preserving Apple XDR Display

> Historical investigation record. Version numbers, paths, and behavior below describe the experiments at that time. See the README for current behavior and compatibility.

Decision under investigation: keep Apple XDR Display (P3-1600 nits) selected
through activation and deactivation. Do not ship the current SDR-preset engine
as the final implementation of this requirement.

## Evidence, September 5, 2026

Host: macOS 27.0, build 26A5416b. Automatic brightness disabled.

BetterDisplay initially failed UI automation and CLI reads timed out. Later,
its CLI recovered. Version 4.3.5 build 50105 reports software brightness
upscaling on, a combined range ending at 1.6, and a software range ending at
approximately 2.428. Its saved configuration names ColorController for software
brightness and AppleController for hardware brightness. Both direct and native
upscaling queries returned empty results, which are not interpreted as false.

The installed XDR Brightness process was stopped and its recovery helper ran.
Its journal had retained an SDR baseline, so recovery alone left preset 1.
The diagnostic explicitly selected Apple XDR Display before the experiments,
as requested. That is the final retained preset. No new application was installed.

Three bounded diagnostic runs each sampled 315 frames across factors
1, 1.15, 1, 1.3, 1, 1.6, 1. Every sample retained preset 0 and reported the
display awake. The initial transparent EDR anchor yielded headroom 1; a visible
one-point HDR anchor yielded approximately 1.207 in one run, but headroom 1
in a subsequent run. It is not a reliable EDR-engagement mechanism yet.

Endpoint-only gamma observations were insufficient: the endpoint remained 1,
but inspecting the curve showed that the write was applied and clamped:

| Factor | Midpoint readback | Three-quarter readback | White endpoint |
| --- | --- | --- | --- |
| 1 | 0.50049 | 0.75073 | 1 |
| 1.15 | 0.57556 | 0.86334 | 1 |
| 1.3 | 0.65064 | 0.97595 | 1 |
| 1.6 | 0.80078 | 1 | 1 |

The naive multiplied-table candidate is rejected: highlight entries collapse
at 1.6. This is evidence about transfer-table behavior, not a photometric or
HDR-video measurement. No claim of flicker-free behavior follows from the
awake flag. Exact baseline gamma hashes and preset restoration were checked.

## Successful reference comparison and revised candidate

BetterDisplay was exercised at combined settings 100%, 115%, 130%, and 160%.
Every captured preset remained Apple XDR Display. At 160% its transfer table
read back midpoint 1.21519, three-quarter 1.82278, and endpoint 2.42800. These
entries remained distinct. Its software setting returned 2.428. The immediately
preceding settings (combined 0.65, hardware 0.567, software 1, upscaling on) were
restored and read back. Those were a newer snapshot than the earlier 0.717
combined observation; snapshots must not be mixed across user interactions.

The revised probe resamples the original curve into 256 entries for boost
writes, while restoring the complete original table on release. In the run at
`local-results/preset-preserving/20260905-223821-950427`, at factor 1.6 the
midpoint was 0.80078, three-quarter 1.20117, and endpoint 1.60000. All 315 samples
retained preset 0 and awake state, and full gamma hash, display mode, and native
brightness restoration passed. BetterDisplay was closed during this run and
reopened with its saved software/hardware/upscaling settings afterward.

This candidate passes the transfer-table gate. The previous run used 1024
entries and showed headroom near 1; the revised run used 256 entries and had
headroom about 9.639. Those variables changed together: table length alone has
**not** been proven to cause the different result. Cold EDR engagement needs
an isolated follow-up. Neither a factor of 1.6 nor a UI setting of 160% proves
1600-nit optical output. HDR clipping beyond the SDR curve also remains untested.

A follow-up 1024-entry run with active headroom about 7.801 still clamped the
three-quarter entry and endpoint to 1 at factor 1.6. The following 256-entry
run aborted at the native-state guard; its original diagnostic conflated an
unavailable/invalid native read with a nonzero preset. It does not prove an
actual preset switch. The diagnostic now distinguishes those cases. Restoration
ran after the child failure, and the final read verified Apple XDR Display and
the neutral curve (midpoint 0.50049, three-quarter 0.75073, endpoint 1).
BetterDisplay was relaunched. This paired run is incomplete, not a passing
repeatability result.

## Documentation boundary

Apple documents CGSetDisplayTransferByTable with channel values in 0...1.
Using values above 1 therefore relies on behavior beyond the documented input
range, even though the function itself is public. A successful return code is
not proof that extended values are preserved.

- [Apple: display transfer tables](https://developer.apple.com/documentation/coregraphics/cgsetdisplaytransferbytable(_:_:_:_:_:))
- [Apple: Metal EDR content](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent)
- [BetterDisplay method comparison](https://github.com/waydabber/BetterDisplay/wiki/XDR-and-HDR-brightness-upscaling)

## Reproduction and next gate

Compile Tools/PresetPreservingProbe.swift with Tools/ProbeEDRAnchor.swift and
the existing NativePanel.o, linking AppKit, CoreGraphics, IOKit, Metal and
QuartzCore. The probe anchor is intentionally separate from the application
anchor. Run `python3 Scripts/test-preset-preserving.py` with competing controllers
closed and Apple XDR Display already selected. The supervisor restores the
saved gamma and native scalar if the child crashes or times out.

Next: isolate cold EDR engagement and table length, then compare
curve and EDR behavior with a calibrated SDR/HDR chart. The menu-bar and HUD
work is pending finalization; no preset-preserving production engine has passed
the quality gate yet.
