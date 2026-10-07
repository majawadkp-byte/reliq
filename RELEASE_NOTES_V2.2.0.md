# RELIQ Solutions V2.2.0 — Visual System

V2.2 introduces the new RELIQ visual language while preserving the V2.1.3 business/database baseline.

## New design system
- New RELIQ dark and light abstract background assets.
- Responsive split login inspired by the approved mock-up.
- Theme-aware frosted-glass login panel with stronger focus states and improved error/submission feedback.
- New workspace background treatment: branded artwork remains intentionally subtle behind operational pages.
- New reusable `ReliqGlass`, `ReliqWorkspaceBackground`, semantic surface and brand-lockup primitives.
- Redesigned shell surfaces, sidebar treatment and top bar for a consistent dark-glass / lime-accent identity.
- Morning Brief hero updated to the new glass treatment.
- Shared V4 section cards now use the RELIQ translucent surface language.

## Light / dark readability hardening
- Rebuilt the application ColorScheme around semantic foreground/surface colors.
- Theme-aware inputs, labels, hints, menus, popup menus, dialogs, chips, tabs, buttons, tables, tooltips and scrollbars.
- Correct dark-mode foregrounds for text buttons and menus.
- Reworked legacy blue token into a cross-theme teal accent so icons remain visible on dark surfaces.
- Fixed return-information banners that previously used light-only backgrounds with inherited dark-mode text.
- Pagination and table helper surfaces now follow the active theme.

## Design principle
Branding is strongest on login and overview screens. Data-heavy POS, inventory, accounting and reporting workspaces use calmer translucent/opaque surfaces for legibility and performance.
