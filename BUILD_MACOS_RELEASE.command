#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "============================================"
echo " RELIQ Solutions V2.3.1 - macOS Release Build"
echo "============================================"

command -v flutter >/dev/null 2>&1 || { echo "Flutter was not found in PATH."; exit 1; }
flutter config --enable-macos-desktop

if [ ! -d "macos" ]; then
  echo "Creating the macOS runner..."
  flutter create --platforms=macos .
fi

# Remove Flutter's template test if the runner generator created it.
rm -f test/widget_test.dart 2>/dev/null || true
rmdir test 2>/dev/null || true

# FilePicker needs user-selected read/write access while the macOS sandbox is enabled.
./tools/patch_macos_entitlements.sh

# Product identity.
APPINFO="macos/Runner/Configs/AppInfo.xcconfig"
if [ -f "$APPINFO" ]; then
  python3 - "$APPINFO" <<'PY'
from pathlib import Path
import sys, re
p=Path(sys.argv[1]); s=p.read_text()
def setv(key, value):
    global s
    pat=rf'(?m)^{re.escape(key)}\s*=.*$'
    line=f'{key} = {value}'
    s=re.sub(pat,line,s) if re.search(pat,s) else s+'\n'+line+'\n'
setv('PRODUCT_NAME','RELIQ Solutions')
setv('PRODUCT_BUNDLE_IDENTIFIER','com.reliq.solutions')
setv('PRODUCT_COPYRIGHT','Copyright © 2026 RELIQ Solutions. All rights reserved.')
p.write_text(s)
PY
fi

# Replace the generated application icon with the RELIQ mark.
ICON_DIR="macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_DIR" ]; then
  for size in 16 32 64 128 256 512 1024; do
    cp "release_assets/macos/app_icon_${size}.png" "$ICON_DIR/app_icon_${size}.png"
  done
fi

flutter clean
flutter pub get
flutter build macos --release

APP="build/macos/Build/Products/Release/RELIQ Solutions.app"
if [ ! -d "$APP" ]; then
  APP="build/macos/Build/Products/Release/reliq_solutions.app"
fi
if [ ! -d "$APP" ]; then
  echo "Release app was not found after build."
  exit 1
fi

mkdir -p dist
rm -rf "dist/RELIQ Solutions.app" "dist/RELIQ_Solutions_macOS.dmg" "dist/dmg_stage"
cp -R "$APP" "dist/RELIQ Solutions.app"

# Ad-hoc sign for a clean local package. This is not Apple notarization.
/usr/bin/codesign --force --deep --sign - "dist/RELIQ Solutions.app" >/dev/null 2>&1 || true

mkdir -p "dist/dmg_stage"
cp -R "dist/RELIQ Solutions.app" "dist/dmg_stage/"
ln -s /Applications "dist/dmg_stage/Applications"
hdiutil create -volname "RELIQ Solutions" -srcfolder "dist/dmg_stage" -ov -format UDZO "dist/RELIQ_Solutions_macOS.dmg"
rm -rf "dist/dmg_stage"

echo
echo "DONE"
echo "App: dist/RELIQ Solutions.app"
echo "DMG: dist/RELIQ_Solutions_macOS.dmg"
echo "Note: this DMG is not Apple-notarized. On another Mac, Gatekeeper may require right-click > Open the first time."
