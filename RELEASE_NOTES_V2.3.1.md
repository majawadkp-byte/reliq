# RELIQ Solutions V2.3.1 — Production Hotfix

V2.3.1 is the production package requested after the V2.3.0 freeze. Database schema remains 31.

## Production fixes

- Customer and supplier ledger detail now opens inside the Payments & Ledgers workspace instead of pushing a full-screen route, so RELIQ's sidebar and top navigation remain visible.
- Added an in-workspace Back button from the detailed ledger to the customer/supplier list.
- Kept explicit Edit Customer / Edit Supplier actions inside the ledger detail; clicking a name continues to mean “open ledger,” not “edit.”
- Added a direct WhatsApp Customer action alongside WhatsApp Statement and Payment Reminder.
- Reworked WhatsApp launching to use the universal `wa.me` HTTPS route on macOS/Windows/Linux. This is more reliable than custom URL schemes and falls back naturally to WhatsApp Web when the desktop app is unavailable.
- Improved phone normalization, including domestic trunk-zero removal when a default country code is applied.
- WhatsApp Statement no longer forces the system PDF Preview app to the foreground before opening WhatsApp. Preview Statement remains available as a separate action.
- Added visible success feedback when Customer/Supplier WhatsApp is opened.

## Version

- Application: `2.3.1+2301`
- Database schema: `31` (unchanged)
