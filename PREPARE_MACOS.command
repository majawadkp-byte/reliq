#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v flutter >/dev/null 2>&1 || { echo "Flutter was not found in PATH."; exit 1; }
flutter config --enable-macos-desktop
if [ ! -d "macos" ]; then
  flutter create --platforms=macos --project-name=reliq_solutions .
fi
rm -f test/widget_test.dart 2>/dev/null || true
rmdir test 2>/dev/null || true
chmod +x tools/patch_macos_entitlements.sh
./tools/patch_macos_entitlements.sh
flutter pub get
echo
echo "macOS runner ready. Run: flutter analyze && flutter run -d macos"
