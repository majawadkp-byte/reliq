# RELIQ Solutions V2.1.1 — Reports Performance & Responsiveness

Build 211 • Database schema 28

## Reports performance
- Reworked the trend query so each transaction table is aggregated once for the selected period instead of running correlated subqueries for every chart day.
- Added branch/date indexes for sales and purchase returns used by report aggregation.
- Report summary, detail rows, trend series and branch-comparison futures are cached per period/branch while the Reports screen is open.
- Switching Overview → Sales → Purchases → Expenses reuses the already-loaded trend dataset instead of rebuilding it.
- Switching report sections no longer invalidates the period summary unnecessarily.
- Branch comparison summaries are requested together instead of one branch at a time.
- Manual Refresh explicitly invalidates the screen caches and reloads current data.

## Never-look-frozen UX
- Trend/comparison cards show a progress state while data is being calculated.
- The previous-period comparison shows an explicit working message while loading.
- Report detail tables show a loading card instead of temporarily showing an empty/no-data state.
- Initial report load tells the user that RELIQ is preparing the report and that large date ranges can take a moment.
- “No chart data” is now reserved for a completed query that genuinely returned no data.

## Database
Schema 28 adds reporting indexes only; no business transaction data is transformed.
