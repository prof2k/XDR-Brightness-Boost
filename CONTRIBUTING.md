# Contributing

Contributions to the original project code are provided under the [GNU General Public License v3.0](LICENSE), the same license as the project. Preserve the licenses and attribution of vendored code.

Use the build and test commands in the README. Keep native display interfaces isolated and preserve explicit display targeting, ownership checks, recovery journals, and bounded retries. Do not expand the built-in model/OS allowlist without physical validation on that exact combination.

For a bug report, include app version, Mac model, macOS build, monitor/connection type, reproduction steps, and whether other display controllers were running. Review diagnostic files for identifying information before sharing them. Never submit signing keys, certificates, or local recovery data.

Policy changes should include focused tests. Changes to display control need on-device checks of activation, deactivation, sleep/wake, disconnection, competing controllers, and recovery as applicable. Record what was actually tested and what remains unverified. Do not run destructive hardware experiments as part of the normal test suite.

Keep generated bundles, captures, and downloaded reference repositories outside the public source package. `python3 Scripts/package-source.py` creates an explicit allowlist-based archive without Git operations.
