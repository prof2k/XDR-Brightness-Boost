# XDR Brightness Boost

A native macOS menu-bar app for built-in XDR brightness boost and external-display brightness control.

**Experimental, version 0.7.19 (99).** Targets Apple silicon and **macOS Big Sur 11 or later**. Runtime validation has so far been performed on macOS 27; older versions still need on-device testing. Built-in XDR control currently accepts only **MacBookPro18,3 on macOS build 26A5416b**. Other models and OS builds are intentionally rejected by that engine. This is not yet a broadly validated production release.

## Features

- Built-in brightness from 0–160%, with a separate remembered boost target.
- Native slider, animated percentage readout, and brightness-key HUD.
- Display selection in the menu; brightness keys otherwise target the display under the pointer.
- External brightness from 0–100% using DisplayServices or the bundled DDC/CI helper, plus software gamma dimming.
- Automatic brightness-key control, optional boost activation from keys, and start on login.
- A separate controller process with ownership-aware recovery for color changes.

The percentage is a control scale, not measured luminance. Above 100%, the built-in engine extends the color transfer curve while retaining the Apple XDR preset. Enabling boost recalls the saved target (initially 160%). Brightness keys and dragging can cross 100% to enable boost automatically. Lowering brightness leaves the toggle on; switching it off returns to at most 100%, and the next upward keypress can enable boost again. Unsupported displays remain capped at 100%. In Settings, **Keys can enable boost** (on by default) controls whether keys may cross 100% while boost is off. Turn it off to make keys respect the main toggle; dragging above 100% still enables boost.

External adjustments combine hardware brightness, where supported, with gamma scaling. For example, 50% requests 50% hardware brightness and a 0.5 color-table multiplier. Software dimming does not turn off the backlight. External XDR boost and independent mirrored-display control are unsupported. Original M1 Macs do not have built-in XDR panels; running on these Macs does not enable built-in XDR boost.

## Build and install

Use a full Xcode installation with the macOS 27 SDK, command-line tools selected with `xcode-select`, and Python 3 for installation and packaging.

```sh
zsh Scripts/test.sh
zsh Scripts/build.sh
python3 Scripts/install.py
open '/Applications/XDR Brightness Boost.app'
```

The build produces `dist/XDR Brightness Boost.app`. A failed build preserves the previous successful bundle. The installer stages and verifies the replacement before quitting the matching installed app, then verifies installed executable hashes and signatures. It preserves preferences and recovery data.

Source builds without a configured certificate are ad-hoc signed for build validation only; the installer refuses them. Save your existing certificate name or SHA-1 fingerprint in `.local-signing-identity` (one line, ignored and excluded from source archives) to use it for every local build. Alternatively, explicitly select it for a single build:

```sh
XDR_CODESIGN_IDENTITY='Your certificate name' zsh Scripts/build.sh
```

The installer checks that certificate-signed updates satisfy the installed app’s designated requirement. Moving from an older ad-hoc build to a certificate may require one final permission approval. Do not remove the permission entry or change certificates during routine updates. A local certificate is not Developer ID signing or notarization. The build script does not produce a notarized public download; see [release preparation](Docs/Release.md).

## Usage and compatibility

Open the sun icon in the menu bar. Choose a display, then adjust its slider. On the supported built-in panel, select **Apple XDR Display (P3-1600 nits)** in macOS and turn automatic brightness off before enabling boost.

Brightness-key control starts automatically while the app runs. Settings shows a compact permission warning with **Open Settings** only when access is missing, or **Retry** if permission exists but capture fails. The **Keys can enable boost** preference stays dimmed with a grayscale switch until capture is ready; its saved choice is retained. Settings also provides start on login on macOS 13 or later. On macOS 11–12, add the app manually in System Preferences → Users & Groups → Login Items. The HUD uses native blur before macOS 26, and animated numeric transitions require macOS 14. Grant the requested macOS access for key capture. If the event tap cannot run, macOS continues handling the keys. An enabled permission entry alone does not prove key capture works.

DisplayServices and the native panel adapter use unsupported macOS interfaces. Extended color-table values exceed Apple's documented 0–1 range. Actual luminance, HDR-video accuracy, protected-content compatibility, and flicker-free behavior are not guaranteed. External hardware control depends on the monitor and connection.

Normal quit restores owned built-in changes with a 35% native-brightness floor. External hardware brightness is retained; owned external gamma changes are restored. Recovery data lives in `~/Library/Application Support/XDRBrightness/`. Do not delete pending recovery records: disconnected displays may need them when reconnected. A competing controller's different curve is not overwritten during recovery.

## Development

The ordinary test runner covers control/color policies, slider snapping, DDC packets, external dimming policy, and a fake-hardware lifecycle test. The lifecycle test reports a skip if no independent external display is connected.

Physical-display scripts in `Scripts/test-*.py` are **opt-in experiments**, not routine tests. They can change brightness, color curves, and presets; some exercise crashes or launch another display controller. Read the script and its prerequisites first. Historical results in [Docs/Approach.md](Docs/Approach.md) do not establish compatibility with other hardware or OS releases.

Main components:

| Path | Responsibility |
| --- | --- |
| `Sources/App.swift` | Menu, settings, display selection, worker supervision |
| `Sources/BrightnessKeys.swift` | Brightness-key event tap |
| `Sources/BrightnessPreview.swift` | Brightness HUD |
| `Sources/ColorWorker.swift` | Current built-in color engine and recovery |
| `Sources/DisplayTarget.swift` | External hardware targeting and DDC coordination |
| `Sources/ExternalGamma.swift` | External color ownership and recovery journal |
| `Sources/NativePanel.m` | Unsupported native panel API boundary and allowlist |
| `Sources/Worker.swift` | Legacy driver engine used by investigation tools |
| `Vendor/m1ddc` | Pinned DDC helper and upstream license |

See [CONTRIBUTING.md](CONTRIBUTING.md) for changes and validation, and [Docs/Release.md](Docs/Release.md) for publication preparation.

## Licensing

The original project code is licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). The bundled m1ddc helper retains its [MIT license](Vendor/m1ddc/LICENSE) and [upstream attribution](Vendor/m1ddc/UPSTREAM.md).
