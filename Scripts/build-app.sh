#!/usr/bin/env bash
# Builds MazeSaver.app as a real double-clickable, distributable app bundle from
# a release build of the MazeSaverApp SwiftPM product.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME=MazeSaver
APP="build/$NAME.app"

echo "Building release binary..."
swift build -c release --product MazeSaverApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MazeSaverApp "$APP/Contents/MacOS/$NAME"
cp Packaging/App-Info.plist "$APP/Contents/Info.plist"

if [ ! -f Packaging/AppIcon.icns ]; then
  ./Scripts/build-icon.sh
fi
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Ad-hoc code signing..."
codesign --force --sign - --timestamp=none "$APP"

echo "Built: $APP"
