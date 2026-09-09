#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.build/module-cache"
xcrun swiftc -parse-as-library -module-cache-path "$project_dir/.build/module-cache" \
  "$project_dir/Tools/DisplayProbe.swift" "$project_dir/Tools/PrivateDisplayReader.swift" \
  -o "$project_dir/.build/display-probe"
exec "$project_dir/.build/display-probe" "$@"
