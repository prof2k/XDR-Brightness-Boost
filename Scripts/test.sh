#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/ControlPolicy.swift Tests/ControlPolicyTests.swift -o .build/policy-tests
.build/policy-tests
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/ColorPolicy.swift Tests/ColorPolicyTests.swift -o .build/color-policy-tests
.build/color-policy-tests
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/SliderSnapPolicy.swift Tests/SliderSnapPolicyTests.swift -o .build/slider-snap-tests
.build/slider-snap-tests

xcrun clang -target arm64-apple-macos11.0 -Wall -Wextra -Werror -fmodules -fmodules-cache-path=.build/module-cache -I Vendor/m1ddc/headers Tests/DDCPacketTests.m Vendor/m1ddc/sources/i2c.m -o .build/ddc-packet-tests
.build/ddc-packet-tests
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/ExternalDimmingPolicy.swift Tests/ExternalDimmingPolicyTests.swift -o .build/external-dimming-tests
.build/external-dimming-tests

# Fake hardware: verifies lifecycle intent without changing display output.
xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/DisplayTarget.swift Tests/ExternalDimmingLifecycleTests.swift -framework AppKit -o .build/external-dimming-lifecycle-tests
.build/external-dimming-lifecycle-tests

xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/StatusItemImage.swift Tests/StatusItemImageTests.swift -framework AppKit -o .build/status-image-tests
.build/status-image-tests

xcrun swiftc -target arm64-apple-macos11.0 -parse-as-library -warnings-as-errors -module-cache-path .build/module-cache Sources/KeyAccess.swift Tests/KeyAccessTests.swift -framework AppKit -o .build/key-access-tests
.build/key-access-tests
