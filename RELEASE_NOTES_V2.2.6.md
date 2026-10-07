# RELIQ Solutions V2.2.6 — Navigation, Light Theme & Checkout Communication

## Navigation integrity
- Restored Business Action Center beside Morning Brief.
- Restored Physical Stock Counts to the Inventory group.
- Restored Payments & Ledgers to Finance & Reports.
- Restored License to Administration instead of Purchasing.
- Corrected Sales, Inventory, Purchasing, Finance and Administration group membership.
- Corrected sidebar shortcut badges that had drifted after pages were added.
- Corrected Morning Brief KPI destinations (collections/receivables/payables, expenses and reports).

## Morning Brief
- Today Sales, Today Collected, Today Purchases, Today Expenses, Receivables and Payables now appear immediately below the Morning Brief header.
- Top Products was moved below the daily operating KPIs so it no longer pushes the most important daily figures down the page.

## Light-mode consistency
- Material semantic primary color is now deep RELIQ teal in light mode and RELIQ lime in dark mode.
- Primary CTA buttons remain RELIQ lime in both themes.
- Checkboxes, radios, switches, selection/cursor states, progress indicators and generic theme icons now use a readable light-mode teal instead of fluorescent lime on white.
- Inventory Intelligence filter-chip icons now use the theme-aware accent.
- Product bulk-selection bar now uses a restrained teal surface/actions in light mode.
- Repeated Customer “Receive Payment” and Return-row actions are now secondary/outlined actions instead of filling every row with lime.

## WhatsApp & post-sale workflow
- WhatsApp now tries the installed desktop app using the `whatsapp://` scheme first and falls back to `wa.me`/WhatsApp Web.
- Sale completion always shows a completion dialog, including when automatic printing/preview is enabled.
- Added **Send Message** to the sale-completed dialog when the selected customer has a saved WhatsApp/phone number.
- If Settings already uses **Print Directly** or automatic Preview, the dialog does not show the same print action again.
- Added clearer WhatsApp settings guidance for country codes and desktop/web fallback.

## Data compatibility
- No database schema change in V2.2.6.
