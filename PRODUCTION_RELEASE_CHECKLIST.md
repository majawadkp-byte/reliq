# RELIQ Solutions V2.3.1 — Production Release Checklist

## Build gate
- [ ] `flutter pub get` succeeds.
- [ ] `flutter analyze` has zero errors.
- [ ] macOS release build succeeds on macOS.
- [ ] Windows release build succeeds on Windows.

## Smoke test
- [ ] Dark login matches approved composition.
- [ ] Light login uses approved light wallpaper and remains readable.
- [ ] Alt+1 through Alt+9 navigate correctly.
- [ ] Cmd+F / Ctrl+F finds a product, customer and supplier from unrelated screens.
- [ ] Product lookup shows current product details.
- [ ] Customer lookup opens full customer ledger.
- [ ] Supplier lookup opens full supplier ledger.
- [ ] Customer/supplier row click opens ledger; Edit button edits.
- [ ] Create sale; verify stock, customer balance, ledger and receipt.
- [ ] Out-of-stock POS warning is clear.
- [ ] Create purchase; verify stock, supplier balance and ledger.
- [ ] Customer and supplier payment allocation works, including partial payment.
- [ ] Sales/purchase returns post correctly.
- [ ] Direct-print setting behaves correctly.
- [ ] WhatsApp action opens app or web fallback and pre-fills the intended message.
- [ ] Morning Brief, Inventory Intelligence and Reports load and refresh.
- [ ] Day Book buttons do not overflow at normal and reduced window sizes.
- [ ] Physical Stock Count is in the correct navigation location.
- [ ] Light/dark dialogs, dropdowns, tables, labels and icons remain readable.

## Data upgrade
- [ ] Back up a real pre-production database.
- [ ] Open it with V2.3.1 and verify schema/data integrity.
- [ ] Reconcile sample stock, receivables, payables and P&L values before/after upgrade.

## Distribution
- [ ] Record SHA-256 for customer package.
- [ ] Archive exact source/tag used to build binaries.
- [ ] Test installer/package on a clean target machine.
