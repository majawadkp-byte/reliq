# RELIQ Solutions V2.1.2 — Never Frozen Performance Pass

Build 212 • Database schema 29

## Responsiveness
- Reports stays alive after first opening, so leaving Reports and returning no longer throws away its in-memory date/branch/query caches.
- Report PDF/XLSX/CSV generation runs in a background isolate after the save location is selected. A persistent “RELIQ is still working” status is shown while the export is prepared.
- Automatic backup and analytics warm-up no longer run before/against first paint. They are deferred and scheduled at Flutter idle priority.
- Analytics warm-up reuses valid persisted snapshots instead of forcing a complete recalculation every startup.

## Faster high-traffic searches
- POS product search is debounced and reuses a stable Future instead of starting a database query on every widget rebuild.
- Products & Barcodes search is debounced; category/filter changes reuse the loaded product result rather than querying again.
- Customer and supplier searches are debounced and no longer re-run merely because the screen rebuilt.
- Customer/supplier overdue balances are aggregated once and joined instead of executing one correlated overdue query per row.
- Supplier search now includes WhatsApp number.

## Loading vs empty vs error
- Products, POS product search, customer/supplier lists, purchase orders and stock counts now show explicit working states while data is loading instead of temporarily showing “no data”.
- Long report export operations explicitly tell the user that RELIQ is working.

## SQLite desktop tuning
- WAL mode, NORMAL synchronous mode, a 5-second busy timeout, in-memory temporary storage and a bounded SQLite cache reduce read/write contention during normal desktop operation.
- Added indexes for product names/codes/barcodes and customer/supplier lookup fields.

## Database
Schema 28 → 29 adds indexes only; business transaction data is not transformed.
