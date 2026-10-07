# RELIQ Solutions V2.2.9 — Exact Login, Universal Lookup & Shortcut Repair

V2.2.9 is a focused usability and visual-fidelity release on top of V2.2.8. It does not change accounting, inventory posting, sales/purchase calculations, or the database schema.

## Login fidelity

- Rebuilt the wide-screen login composition to match the supplied 1280×800 reference layout: ~56/44 split, brand lockup on the upper-left, feature copy on the lower-left, and the login glass panel positioned in the right pane.
- Uses the exact full-resolution dark and light background files supplied by the user as source artwork.
- Dark mode uses the approved white horizontal RELIQ lockup; light mode uses the approved dark horizontal lockup.
- Added stronger frosted-glass depth to the login card and the username/password fields, including a restrained reflective highlight and edge sheen.

## Glass system

- `ReliqGlass` now supports reflective highlights and edge reflections in addition to backdrop blur, transparency, border, and shadow.
- Reflection is drawn behind content so text/icons remain readable.
- Existing internal RELIQ glass surfaces inherit the same restrained reflective language without changing dense table/business logic layouts.

## Universal Cmd/Ctrl+F lookup

- Cmd+F on macOS and Ctrl+F on Windows now opens one global RELIQ Lookup from any application screen.
- The lookup searches products, customers, and suppliers at the same time.
- Product results preserve the existing product-detail lookup (stock, price, sales/purchases, movements, expiry, etc.).
- Customer results navigate directly to Customer Ledgers and filter to the selected customer.
- Supplier results navigate directly to Supplier Ledgers and filter to the selected supplier.
- Local page-level Cmd/Ctrl+F handlers were removed so the global behavior is consistent everywhere.

## Alt navigation shortcut repair

- Alt+1 through Alt+9 are now handled at the application hardware-key level rather than relying only on focused widget shortcut propagation.
- Number-row shortcuts use physical digit keys, which avoids macOS Option/Alt character translation problems.
- Numpad 1–9 are also supported.
- Mapping remains:
  - Alt+1 Morning Brief
  - Alt+2 Sales / POS
  - Alt+3 Receive Purchase
  - Alt+4 Products & Barcodes
  - Alt+5 Customer Ledgers
  - Alt+6 Supplier Ledgers
  - Alt+7 Payment Activity
  - Alt+8 Reports
  - Alt+9 Business Action Center

## Metadata consistency

- App version: `2.2.9+229`
- `Brand.version`, build number, and label aligned with the package version.
- `Brand.databaseVersion` aligned with the existing database schema version 31. No schema migration is added by V2.2.9.
