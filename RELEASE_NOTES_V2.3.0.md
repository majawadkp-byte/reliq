# RELIQ Solutions V2.3.0 — Production Release

V2.3.0 promotes the validated V2.2.10 release-candidate code line to the production baseline. No new feature or database migration is introduced by this promotion.

## Production baseline
- Application version: `2.3.0+2300`
- Database schema: 31 (unchanged)
- Product identity: RELIQ Solutions
- Tagline: Reliable Intelligent Solutions

## Included release work
- RELIQ light/dark design system and reflective frosted-glass surfaces.
- Exact supplied login compositions and full-resolution theme wallpapers.
- Global Cmd+F / Ctrl+F lookup for products, customers and suppliers.
- Customer/supplier results route to full party ledgers; product results retain product detail lookup.
- Alt+1…Alt+9 hardware-key navigation support, including macOS Option-key handling.
- Customer and supplier ledger detail pages with separate Edit actions and operational history.
- Customer/supplier search fixes.
- Sales/POS, navigation, Day Book, report readability/performance, WhatsApp, printing and theme consistency refinements from the V2.2.x line.

## Packaging
- `BUILD_MACOS_RELEASE.command` builds a release `.app` and ad-hoc-signed DMG.
- `BUILD_WINDOWS_RELEASE.bat` builds the Windows release folder and ZIP.
- The macOS DMG is not Apple-notarized; Gatekeeper behavior on other Macs can therefore vary.

## Release gate
Before distributing to customers, build on the target platform and complete `PRODUCTION_RELEASE_CHECKLIST.md`. This source package was prepared without a Flutter SDK in the packaging environment, so binaries are intentionally not represented as runtime-validated here.
