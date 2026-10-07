# RELIQ Solutions V2.0.7 — WhatsApp Communication Workflow

Build 207 · Database schema 26

## Added
- WhatsApp customer payment receipts from Payment Activity.
- WhatsApp supplier payment advice from Payment Activity.
- Receipt/payment-advice PDFs include allocations before WhatsApp opens.
- Editable WhatsApp templates for invoice, statement, reminder, quotation, quotation follow-up, purchase order, customer receipt and supplier payment advice.
- Customer and supplier communication history dialogs.
- Customer statements and payment reminders are now recorded in communication history.
- Purchase-order WhatsApp actions are recorded in supplier communication history.
- Quotation follow-up WhatsApp action for sent quotations.
- Business Action Center surfaces sent quotations older than three days that remain unconverted.
- Payment Activity shows whether a WhatsApp receipt/payment advice has previously been prepared and allows resend.

## Operating rule
Business transactions are saved first. WhatsApp is a separate manual action and never blocks POS, receipt posting, supplier payment posting, or quotation saving. Standard WhatsApp mode records Prepared / opened only; it does not claim delivery or read status.

## Database
No schema migration is required from V2.0.6. Database schema remains 26.
