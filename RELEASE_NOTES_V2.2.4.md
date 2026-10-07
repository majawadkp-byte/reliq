# RELIQ Solutions V2.2.4 — Analyzer & macOS Runner Fix

## Build fixes
- Removed the five invalid `const` widget contexts introduced when theme-aware text colors were added to Day Book, Inventory Intelligence, Products and Reports.
- Confirmed the database API used by Customers, Payments/Ledgers, Products, Quotations and Reports is present in `AppDatabase`, including the V2.2.3 fast report methods.
- Keeps database schema version 31; no data migration is introduced by this build.

## macOS launch
- Hardened `RUN_MACOS.command` to verify the actual Xcode runner project, not merely the presence of a `macos` directory.
- Incomplete macOS runner folders are moved aside and regenerated with `flutter create --platforms=macos`.
- Clears stale `.dart_tool`/Flutter build metadata before dependency resolution.
- Analyzer errors now stop launch instead of being hidden by `flutter analyze || true`; warnings/info do not block launch.

## Important
Extract V2.2.4 into a new folder. Do not merge it over an older V2.2.x source directory. Then run `./RUN_MACOS.command` from the new folder.
