#!/usr/bin/env bash
# Builds both bundles and zips them the way macOS expects (ditto, not plain
# zip — preserves the code signature and extended attributes), ready to
# attach to a GitHub release.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

./Scripts/build-app.sh
./Scripts/build-saver.sh

cd build
rm -f MazeSaver-App.zip MazeSaver-Screensaver.zip
ditto -c -k --sequesterRsrc --keepParent MazeSaver.app MazeSaver-App.zip
ditto -c -k --sequesterRsrc --keepParent MazeSaver.saver MazeSaver-Screensaver.zip

echo "Built: build/MazeSaver-App.zip"
echo "Built: build/MazeSaver-Screensaver.zip"
