#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Screen Todo Capture.app"
SOURCE_APP="$ROOT_DIR/.build/release/ScreenTodoCapture.app"
TARGET_APP="/Applications/$APP_NAME"

"$ROOT_DIR/scripts/package-app.sh" >/dev/null

rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"

echo "$TARGET_APP"
