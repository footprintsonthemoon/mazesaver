#!/usr/bin/env bash
# Builds MazeSaver.saver directly with swiftc/lipo/codesign — no Xcode project
# needed. Compiles the shared MazeCore sources together with the ScreenSaverView
# subclass as a single compilation unit (mirrors how the whole app used to be one
# target before it was split for reuse between the app and this bundle).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME=MazeSaver
BUNDLE="$NAME.saver"
BUILD="build/$BUNDLE"
SDK=$(xcrun --sdk macosx --show-sdk-path)
DEPLOY=13.0

SOURCES=(Sources/MazeCore/*.swift Sources/MazeSaverScreenSaver/MazeSaverView.swift)

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
cp Sources/MazeSaverScreenSaver/Info.plist "$BUILD/Contents/Info.plist"

if [ ! -f Packaging/AppIcon.icns ]; then
  ./Scripts/build-icon.sh
fi
cp Packaging/AppIcon.icns "$BUILD/Contents/Resources/AppIcon.icns"

COMMON=(
  -sdk "$SDK"
  -framework ScreenSaver -framework AppKit
  -emit-library -Xlinker -bundle
  -module-name "$NAME" -O
)

echo "Compiling arm64..."
swiftc -target arm64-apple-macos$DEPLOY "${COMMON[@]}" \
       -o "$BUILD/Contents/MacOS/arm64.bin" "${SOURCES[@]}"

echo "Compiling x86_64..."
swiftc -target x86_64-apple-macos$DEPLOY "${COMMON[@]}" \
       -o "$BUILD/Contents/MacOS/x86_64.bin" "${SOURCES[@]}"

echo "Creating universal binary..."
lipo -create "$BUILD/Contents/MacOS/arm64.bin" \
             "$BUILD/Contents/MacOS/x86_64.bin" \
     -output "$BUILD/Contents/MacOS/$NAME"
rm "$BUILD/Contents/MacOS/arm64.bin" "$BUILD/Contents/MacOS/x86_64.bin"

echo "Ad-hoc code signing..."
codesign --force --sign - --timestamp=none "$BUILD"

echo "Built: $BUILD"
