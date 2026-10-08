#!/usr/bin/env python3
"""Enable native Open/Save panel access for a sandboxed Reliq macOS build.

Run from the Flutter project root. Existing entitlements are preserved.
"""
from pathlib import Path
import plistlib
import sys

root = Path.cwd()
runner = root / 'macos' / 'Runner'
files = [runner / 'DebugProfile.entitlements', runner / 'Release.entitlements']
missing = [str(p) for p in files if not p.is_file()]
if missing:
    sys.exit('Cannot locate macOS entitlement files:\n' + '\n'.join(missing) + '\nRun this script from the Flutter project root.')

for path in files:
    with path.open('rb') as f:
        entitlements = plistlib.load(f)
    if not isinstance(entitlements, dict):
        sys.exit(f'Unexpected entitlement plist: {path}')
    entitlements.pop('com.apple.security.files.user-selected.read-only', None)
    entitlements['com.apple.security.files.user-selected.read-write'] = True
    with path.open('wb') as f:
        plistlib.dump(entitlements, f, sort_keys=False)
    print(f'Updated: {path.relative_to(root)}')
print('Native user-selected file read/write entitlement is enabled. Rebuild Reliq for the change to take effect.')
