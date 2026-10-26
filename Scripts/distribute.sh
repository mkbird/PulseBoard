#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_BUNDLE="$PROJECT_DIR/dist/PulseBoard.app"
ARCHIVE="$PROJECT_DIR/dist/PulseBoard.zip"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: DONGPENG MA (X4BPFGFQXD)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "请设置 NOTARY_PROFILE（由 xcrun notarytool store-credentials 创建）。" >&2
    exit 2
fi

CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$PROJECT_DIR/Scripts/build-app.sh"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"

echo "$ARCHIVE"
