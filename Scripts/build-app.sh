#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/CliptoPulse.app"
RESOURCE_BUNDLE="$BUILD_DIR/PulseBoard_PulseBoard.bundle"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/PulseBoard" "$APP_BUNDLE/Contents/MacOS/PulseBoard"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CliptoPulseBuildTimestamp string $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %z')" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/PulseBoard.icns" "$APP_BUNDLE/Contents/Resources/PulseBoard.icns"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
