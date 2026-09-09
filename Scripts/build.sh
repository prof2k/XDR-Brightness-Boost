#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# This machine's certificate choice survives rebuilds without entering source
# archives. An explicit environment override still works for other developers.
if [[ -n "${XDR_CODESIGN_IDENTITY:-}" ]]; then
    xdr_signing_identity="$XDR_CODESIGN_IDENTITY"
elif [[ -f .local-signing-identity ]]; then
    xdr_signing_identity="$(<.local-signing-identity)"
    [[ -n "$xdr_signing_identity" && "$xdr_signing_identity" != "-" ]] || { print -u2 'Invalid local signing identity'; exit 1; }
else
    xdr_signing_identity="-"
    print -u2 'Building ad-hoc for source validation only; installation requires a stable certificate.'
fi
mkdir -p .build/module-cache
xcrun clang -target arm64-apple-macos11.0 -fobjc-arc -Wall -Wextra -Werror -O2 -c Sources/NativePanel.m -o .build/NativePanel.o
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -O -warnings-as-errors -module-cache-path .build/module-cache -import-objc-header Sources/NativePanel.h Sources/ControlPolicy.swift Sources/ColorPolicy.swift Sources/EDRAnchor.swift Sources/ColorEDRAnchor.swift Sources/KeyAccess.swift Sources/BrightnessKeys.swift Sources/Worker.swift Sources/ColorWorker.swift Sources/PercentageReadout.swift Sources/SliderSnapPolicy.swift Sources/BrightnessPreview.swift Sources/ExternalGamma.swift Sources/ExternalDimmingPolicy.swift Sources/DisplayTarget.swift Sources/StatusItemImage.swift Sources/App.swift .build/NativePanel.o -framework AppKit -framework SwiftUI -framework ServiceManagement -framework CoreGraphics -framework IOKit -framework Metal -framework MetalKit -framework QuartzCore -o .build/XDRBrightness
xcrun clang -target arm64-apple-macos11.0 -Wall -Wextra -Werror -fmodules -fmodules-cache-path=.build/module-cache -I Vendor/m1ddc/headers Vendor/m1ddc/sources/*.m -F /System/Library/PrivateFrameworks -framework CoreDisplay -o .build/xdr-ddc
# Build into a fresh staging directory; preserve the previous verified app on failure.
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.build-XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/XDR Brightness Boost.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/XDRBrightness "$app/Contents/MacOS/XDRBrightness"
cp .build/xdr-ddc "$app/Contents/MacOS/xdr-ddc"
cp Vendor/m1ddc/LICENSE "$app/Contents/Resources/m1ddc-LICENSE.txt"
xcrun actool "Resources/XDR Brightness Boost.icon" --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 11.0 --app-icon "XDR Brightness Boost" --output-partial-info-plist .build/icon-info.plist
cp Resources/brightness-active.svg Resources/brightness-active-light.svg Resources/brightness-default.svg "$app/Contents/Resources/"
cp Resources/boost-unsupported.svg Resources/setting.svg Resources/left-arrow.svg Resources/close.svg "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.elijah.XDRBrightness</string>
<key>CFBundleExecutable</key><string>XDRBrightness</string>
<key>CFBundleName</key><string>XDR Brightness Boost</string>
<key>CFBundleDisplayName</key><string>XDR Brightness Boost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.19</string>
<key>CFBundleVersion</key><string>99</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>XDR Brightness Boost</string>
<key>CFBundleIconName</key><string>XDR Brightness Boost</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
helper="$app/Contents/Helpers/XDRBrightnessController.app"
mkdir -p "$helper/Contents/MacOS"
cp .build/XDRBrightness "$helper/Contents/MacOS/XDRBrightnessController"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.elijah.XDRBrightness.Controller</string>
<key>CFBundleExecutable</key><string>XDRBrightnessController</string>
<key>CFBundleName</key><string>XDR Brightness Controller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.19</string>
<key>CFBundleVersion</key><string>99</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$xdr_signing_identity" "$app/Contents/MacOS/xdr-ddc"
codesign --force --sign "$xdr_signing_identity" "$helper"
codesign --force --sign "$xdr_signing_identity" "$app"
codesign --verify --strict --deep "$app"
destination="$PWD/dist/XDR Brightness Boost.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$stage/previous.app"
fi
if ! mv "$app" "$destination"; then
    [[ ! -e "$stage/previous.app" ]] || mv "$stage/previous.app" "$destination"
    exit 1
fi
print -r -- "$destination"
