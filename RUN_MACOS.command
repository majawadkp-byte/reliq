#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v flutter >/dev/null 2>&1 || { echo "Flutter was not found in PATH."; exit 1; }

flutter config --enable-macos-desktop

# A folder named macos is not enough; Flutter needs a complete Xcode runner.
if [ ! -f "macos/Runner.xcodeproj/project.pbxproj" ]; then
  if [ -d "macos" ]; then
    echo "An incomplete macOS runner was found. Moving it aside before regeneration..."
    mv macos "macos.incomplete.$(date +%Y%m%d%H%M%S)"
  fi
  echo "Generating the macOS desktop runner..."
  flutter create --platforms=macos --project-name=reliq_solutions .
fi

rm -f test/widget_test.dart 2>/dev/null || true
rmdir test 2>/dev/null || true
if [ -f tools/patch_macos_entitlements.sh ]; then
  chmod +x tools/patch_macos_entitlements.sh
  ./tools/patch_macos_entitlements.sh
fi

# Force analyzer/build metadata to match the extracted source. This avoids
# stale .dart_tool state when a new RELIQ source pack replaces an older one.
rm -rf .dart_tool
flutter clean
flutter pub get

echo
echo "Running analyzer (errors will stop the launch)..."
ANALYZE_LOG="/tmp/reliq_flutter_analyze.log"
set +e
flutter analyze 2>&1 | tee "$ANALYZE_LOG"
ANALYZE_STATUS=${PIPESTATUS[0]}
set -e
if grep -qE '^ *error •' "$ANALYZE_LOG"; then
  echo
  echo "RELIQ still has analyzer errors. Launch stopped so the errors are not hidden by runtime output."
  exit 1
fi
if [ "$ANALYZE_STATUS" -ne 0 ]; then
  echo "Analyzer returned non-zero because of warnings/info only; continuing."
fi

echo
echo "Launching RELIQ Solutions on macOS..."
flutter run -d macos
