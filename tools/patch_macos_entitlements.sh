#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d "macos/Runner" ]; then
  echo "macOS runner not found. Run: flutter create --platforms=macos ."
  exit 1
fi

for ENT in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [ ! -f "$ENT" ]; then
    echo "Skipping missing $ENT"
    continue
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-write bool true" "$ENT" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-write true" "$ENT"
  echo "Enabled user-selected read/write access in $ENT"
done
