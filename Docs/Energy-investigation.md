# Menu-bar redraw loop — 2026-09-09

Version 0.7.12 (92) was observed consuming 97.3% CPU in the main app,
with its helper at 0.7%. The app had accumulated 1061 minutes of CPU time
over about 24 hours 48 minutes. Activity Monitor also showed very high
energy impact. That score is not a direct wattage measurement.

A three-second live `sample` captured repeated
`NSStatusItem._updateReplicants`, snapshot rendering, and
`AppDelegate.buildMenuBarControl`'s appearance callback assigning the image.
The callback assigned the same cached image again, invalidating the status
item and feeding another appearance/redraw cycle. Brightness readback also
unconditionally reassigned this image.

Version 0.7.13 (93) routes all menu-bar image assignments through
`StatusItemImage.update`. It skips assignment when the image instance is
already installed, while retaining changes between idle, boosted-dark,
and boosted-light assets. No brightness-engine, glass, or slider changes
were made for this fix.

Validation:

- Regression test: 10,000 identical updates cause only one assignment;
  simulated appearance feedback terminates; boost, appearance, and nil
  transitions still replace the image.
- Existing automated checks passed. External-display lifecycle test skipped
  because no independent external display was available.
- Signed build installed in `/Applications/XDR Brightness Boost.app`;
  installed executable hashes matched the build.
- Post-install CPU samples at process ages 16, 26, and 36 seconds were
  2.0%, 0.0%, and 0.0%. CPU time increased from 0.31 to 0.35 seconds over
  the latter 20 seconds (approximately 0.2% of one CPU core on average).
- In the post-install three-second stack sample, 232 of 234 main-thread
  samples were waiting for events. The repeating status-item redraw chain
  was absent.

Raw local samples: `/tmp/xdr-main-energy-before.txt`,
`/tmp/xdr-helper-energy-before.txt`, `/tmp/xdr-main-energy-after.txt`.
These are temporary diagnostics, not bundled app resources.

This confirms removal of the observed idle CPU loop. It is not a battery
life measurement or extended sleep/wake/boost stress test. Activity Monitor's
12-hour metric includes usage from the previous build.
