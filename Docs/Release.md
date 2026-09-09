# Release preparation

The current app is an experimental preview with a narrow built-in compatibility allowlist. Preparing the source does not certify production compatibility.

## Before publishing source

- Keep the project GPLv3 license and the m1ddc MIT license and attribution in the published source.
- Review the included source, artwork provenance, and documentation.
- Run `zsh Scripts/test.sh` and `zsh Scripts/build.sh` on the documented Xcode/macOS setup.
- Run `python3 Scripts/package-source.py` and inspect the resulting archive. This uses an explicit path allowlist, excludes local results and build outputs, and does not use Git.
- Keep historical investigation notes labeled as historical evidence.

## Before distributing an app

- Set version/build metadata consistently for the app and controller in `Scripts/build.sh`.
- Test launch and fallback UI on macOS 11, 12, 13, 14, and later versions. The deployment target is 11.0; compilation alone does not validate older runtime behavior.
- Validate the target Mac/OS combinations before changing the native-panel allowlist.
- Test real brightness keys, permission denial, login registration, sleep/wake, hotplug, external targeting, and recovery on the signed release candidate.
- Prepare a Developer ID distribution process including hardened-runtime compatibility, notarization, stapling, and a Gatekeeper check on a clean Mac. The current script supports local code signing only; it does not implement this distribution process.
- Keep the exact verified bundle and record its checksums and validation environment.

Do not describe policy tests as proof of physical display behavior. Do not ship private certificates, local recovery records, reference downloads, or the entire working directory as a release archive.
