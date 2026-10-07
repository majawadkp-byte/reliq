# RELIQ Solutions V2.2.8 — Search, Shortcuts & Frosted Surfaces

## Scope
V2.2.8 is a focused interaction and visual-consistency update on top of V2.2.7. It does not change the database schema or accounting/inventory posting logic.

## Login backgrounds
- Replaced the previous derived/cropped login artwork with the exact user-supplied full-resolution assets.
- Dark login: `assets/branding/reliq_background_dark.jpg` (2048×1280).
- Light login: `assets/branding/reliq_background_light.png` (1586×992).
- The existing approved RELIQ login composition is retained.

## Frosted login fields
- Username, password/PIN and owner-setup confirmation fields now sit on their own real `BackdropFilter` frosted layers.
- The main authentication card remains a stronger frosted-glass surface.

## Customer & supplier search fix
- Search now has a shorter, reliable debounce plus Enter/Search submission and a clear control.
- Database search is case-insensitive and now matches name, phone, WhatsApp, email, address and internal ID.
- Multi-word searches are supported; every word can match a different contact field.
- Search fields use frosted surfaces while preserving light/dark contrast.

## Cmd/Ctrl + F
- On Customer Ledgers, Cmd/Ctrl+F focuses the customer search field.
- On Supplier Ledgers, Cmd/Ctrl+F focuses the supplier search field.
- On other screens the existing product lookup behavior remains the fallback.
- The top-bar Lookup action follows the same contextual behavior.

## Shortcut audit
The active shortcut mappings were reviewed against the in-app keyboard shortcut guide. No existing POS, Purchase, Product or Stock Adjustment bindings were removed.

## Internal glass language
- Common light-theme cards/surfaces and inputs are now slightly translucent.
- The application top bar now uses a real backdrop blur.
- Payments & Ledgers tabs, Customer search and Supplier search use reusable RELIQ frosted surfaces.
- Operational background remains `#F7F9F9` in light mode; no abstract login artwork is used after authentication.

## Day Book
- Increased the safe action area height so aligned bottom buttons do not overflow cards on smaller windows or touch-density layouts.

## Versioning
- App version: `2.2.8+228`
- Database schema: unchanged from V2.2.7 / schema 31.
