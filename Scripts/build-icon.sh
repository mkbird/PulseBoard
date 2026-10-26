#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Resources/AppIcon-master.png"
OUTPUT="$PROJECT_DIR/Resources/PulseBoard.icns"
WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/PulseBoard.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "$OUTPUT"
