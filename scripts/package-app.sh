#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  "$ROOT_DIR/scripts/generate-icon.sh" >/dev/null
fi

APP_DIR="$ROOT_DIR/.build/release/ScreenTodoCapture.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/ScreenTodoCapture" "$APP_DIR/Contents/MacOS/ScreenTodoCapture"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
