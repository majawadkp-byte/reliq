# RELIQ Solutions V2.2.1 — Visual System Build Fix

## Build repairs
- Fixed unsupported `MenuStyle.foregroundColor` usage in the global theme.
- Restored the missing `_audit` method closure so quotation/communication database APIs are class members.
- Fixed the malformed product option-tile surface color expression.
- Fixed `num` to `double` type mismatches in customer statement, purchase order and quotation PDF totals.

## Official RELIQ assets
- Added the supplied master RELIQ SVG to the branding assets.
- Added the supplied POS, inventory and intelligence lime icons.
- Login feature rows now use the official supplied icon artwork.

## macOS developer workflow
- Added `RUN_MACOS.command`. It creates the generated macOS runner when missing, applies RELIQ entitlements, fetches packages, runs analysis and launches the app.
- The source archive intentionally keeps generated desktop runner folders out of source control; the helper creates the runner using the installed Flutter SDK.

## Compatibility
- Database schema remains version 30.
- Existing V2.1.3/V2.2.0 data remains compatible.
