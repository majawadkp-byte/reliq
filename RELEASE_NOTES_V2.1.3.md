# RELIQ Solutions V2.1.3 — Build 213

## Never Frozen II

This release continues the responsiveness pass started in V2.1.1/V2.1.2. The focus is Sales History, Purchase History, Payments & Ledgers, Migration Center, document preparation, and large product catalogues.

### History workspaces
- Sales History and Purchase History now keep a stable data Future instead of starting a new database request on unrelated widget rebuilds.
- Search is debounced so typing does not query SQLite on every keystroke.
- Page, page-size, status, sort and date changes explicitly refresh the current result.
- Loading, empty and error states are separate and clearly labelled.
- Sales profit calculations are skipped for users who do not have permission to view profit, avoiding unnecessary sale-item/return aggregation.
- Invoice and purchase preview actions immediately show a persistent “RELIQ is still working” indicator before document preparation begins.
- PDF document generation now caches the resolved Unicode system-font theme and company logo bytes for the app session, avoiding repeated font/logo disk reads on every invoice, receipt, statement, PO or quotation preview.

### Payments & Ledgers
- Payment Activity now caches its active Future and debounces search/min/max filters.
- The Payment Activity tab opts into keep-alive so moving between ledger tabs does not discard its current result unnecessarily.
- WhatsApp receipt/payment-advice preparation now displays an immediate working indicator and refreshes only after the action completes.
- Added a composite communication-log index for document/channel/date lookups used by invoice/receipt WhatsApp status.

### Persistent heavy workspaces
After first visit, Products, Purchase History, Sales History, Payments & Ledgers, Reports and Migration Center stay mounted while the user moves elsewhere in RELIQ. Returning to them preserves filters, scroll/query state and completed Futures instead of reconstructing the workspace from zero. Explicit refresh still rebuilds the workspace.

### Migration Center
- Large CSV parsing/validation now runs on a Flutter worker isolate.
- Migration ZIP expansion, entity detection and CSV parsing now run off the UI isolate.
- Actual database imports report progress every 100 processed rows and yield back to Flutter between progress updates.
- The status bar now shows the current migration stage and `done / total` row count during long imports.

### Large product databases
- Product catalogue loading no longer performs separate tax-profile subqueries for every product row.
- Recipe/combo availability is pre-aggregated once in a CTE and joined to the product result instead of recalculating recipe availability independently for each product.
- Existing V2.1.2 debounced product search and in-memory filter reuse remain in place.

### Database performance
Schema 30 adds indexes for:
- sales by customer/date
- sales by status/balance/date
- purchases by supplier/date
- purchases by status/balance/date
- payment activity by date
- communication log by document/document-id/channel/date

No sales, purchase, stock, payment or accounting values are rewritten by this migration.

## Upgrade
Back up the customer database before first launch. V2.1.3 upgrades schema 29 → 30 automatically.

## Validation note
The source/package structure and YAML were validated in the packaging environment. Flutter/Dart are not installed in that environment, so `flutter analyze` and a real desktop build must still be run on a Flutter development machine before customer release.
