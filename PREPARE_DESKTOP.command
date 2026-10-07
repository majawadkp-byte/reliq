#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null 2>&1 || { echo "Flutter was not found in PATH."; exit 1; }

flutter config --enable-macos-desktop --enable-windows-desktop
if [ ! -d "macos" ]; then
  flutter create --platforms=macos .
fi
if [ ! -d "windows" ]; then
  flutter create --platforms=windows .
fi
rm -f test/widget_test.dart 2>/dev/null || true
rmdir test 2>/dev/null || true
./tools/patch_macos_entitlements.sh
flutter pub get

echo
echo "RELIQ desktop runners are ready."
echo "Run locally: flutter run -d macos"
echo "Release build: ./BUILD_MACOS_RELEASE.command"
