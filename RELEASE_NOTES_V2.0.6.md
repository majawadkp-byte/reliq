# RELIQ Solutions V2.0.6 — Non-blocking Invoice Sharing

- POS completion remains independent from WhatsApp/email communication.
- Sales History is the primary manual invoice-sharing workspace.
- WhatsApp Invoice can be opened or resent later without changing the original sale, stock, ledger or accounting entries.
- Successful WhatsApp-open actions are recorded in the communication log as `Prepared / opened`; RELIQ does not claim delivery/read status without an API.
- Sales History shows whether an invoice has never been shared or was previously prepared for WhatsApp, including the latest preparation time in the tooltip.
- Print/reprint remains independent from sharing.
- Database schema remains 26; no database migration is required from V2.0.5.
