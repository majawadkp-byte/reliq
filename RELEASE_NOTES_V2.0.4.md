# RELIQ Solutions V2.0.4 — WhatsApp Business Workflow

Build 204 • Database schema 25

## Added
- WhatsApp customer statement workflow: generate statement PDF, prepare WhatsApp recipient/message, user confirms sending/attachment.
- WhatsApp payment reminders directly from Customers for outstanding balances.
- Supplier WhatsApp number field with phone fallback.
- WhatsApp supplier contact action.
- Purchase Order PDF generation and WhatsApp PO workflow.
- Customer statement PDF with invoices, payments and outstanding balance.
- Reusable WhatsApp templates/service support for statements, reminders, purchase orders and payment notices.

## Design rule
WhatsApp Standard does not use Meta API and does not silently send messages. RELIQ prepares the recipient/message and document preview; the user performs the final WhatsApp send/attachment action. This avoids pretending delivery/read confirmation exists.

## Database
Schema 25 adds suppliers.whatsapp. Existing databases upgrade automatically.
