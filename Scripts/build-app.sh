#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/PulseBoard.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Library/LaunchDaemons"
cp "$BUILD_DIR/PulseBoard" "$APP_BUNDLE/Contents/MacOS/PulseBoard"
cp "$BUILD_DIR/PulseBoardHelper" "$APP_BUNDLE/Contents/Resources/PulseBoardHelper"
cp "$PROJECT_DIR/Resources/com.madongpeng.PulseBoard.helper.plist" "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.madongpeng.PulseBoard.helper.plist"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_BUNDLE/Contents/Resources/PulseBoardHelper"
    codesign --force --sign - "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE/Contents/Resources/PulseBoardHelper"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
