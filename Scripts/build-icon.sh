#!/usr/bin/env bash
# Generates Packaging/AppIcon.icns from the source artwork using sips + iconutil
# (both ship with the Command Line Tools — no Xcode needed).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="Assets/icon.png"
ICONSET="build/AppIcon.iconset"
OUT="Packaging/AppIcon.icns"

if [ ! -f "$SRC" ]; then
  echo "error: $SRC not found at repo root" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Packaging
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "Built: $OUT"
