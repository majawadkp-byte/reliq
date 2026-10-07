# RELIQ Solutions V2.2.5 — Final Analyzer Compile Fix

## Build fixes
- Fixed the remaining invalid `const` context in Receive Purchase where a theme-aware text color calls `V3Style.mutedFor(context)`.
- Fixed the remaining invalid `const` context in Sales POS empty-cart messaging for the same theme-aware color helper.
- These are the two actual analyzer errors shown by the V2.2.4 test log; the remaining analyzer output is warnings/info and does not block launch.
- Keeps database schema version 31; no data migration is introduced.

## macOS launch
- Retains the hardened V2.2.4 macOS runner regeneration and stale metadata cleanup.
- `RUN_MACOS.command` continues to stop only on analyzer errors, while warnings/info are allowed through to launch.

## Important
Extract V2.2.5 into a new folder and run `./RUN_MACOS.command` from that folder. Do not type the literal `/path/to/...` example path.
