#!/usr/bin/env bash
set -euo pipefail

# Run the Swift Testing suites with either Xcode or standalone Command Line Tools.
# Recent CLT releases ship Testing outside SwiftPM's default framework search path.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_PATH="$(xcode-select -p)"
FRAMEWORK_PATH="$DEVELOPER_PATH/Library/Developer/Frameworks"
cd "$ROOT_DIR"

if [[ -d "$FRAMEWORK_PATH/Testing.framework" ]]; then
  swift test --disable-xctest \
    -Xswiftc -F -Xswiftc "$FRAMEWORK_PATH" \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_PATH" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_PATH/Library/Developer/usr/lib" "$@"
else
  swift test --disable-xctest "$@"
fi
