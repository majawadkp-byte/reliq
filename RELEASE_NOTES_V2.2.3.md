# RELIQ Solutions V2.2.3 — Consistency & Report Performance

## Performance
- Reworked the Reports headline summary from many sequential SQLite aggregate calls into one indexed aggregate query.
- Added persistent stale-while-revalidate snapshots for the common report summary and daily trend series. Saved values open immediately on later visits; dirty snapshots refresh in the background.
- Startup idle warm-up now prepares the common 30-day report summary/trend after first paint, alongside the existing inventory/action snapshots.
- Reduced Tax report aggregation from five database round-trips to one.
- Reduced Profit & Loss headline financial aggregation to one database round-trip plus the expense-category grouping query.
- Added schema v31 reporting indexes for branch/date/status and due-balance report paths.
- Existing Inventory Intelligence, Morning Brief and Business Action Center continue to share cached analytics snapshots.

## Visual consistency
- Added theme-aware secondary-text and accessible label-accent tokens.
- Updated high-use operational/reporting screens to use theme-aware secondary text instead of a fixed muted color where practical.
- Preserved the clean post-login workspace; the abstract wallpaper remains login-only.
- Kept light-mode labels/indicators deep teal and dark-mode labels/indicators RELIQ lime.

## Brand assets
- Replaced production RELIQ icon/logo PNG assets with the official RGB exports supplied in the latest brand pack.
- The uploaded archive contains RELIQ logo/icon variants, but it does not contain a sidebar/module icon set. Existing Material module icons are therefore intentionally retained until the actual navigation icon pack is supplied.

## Database
- Database schema version: 31.
- Migration only adds indexes; no accounting, inventory, invoice, payment or master-data values are changed.
