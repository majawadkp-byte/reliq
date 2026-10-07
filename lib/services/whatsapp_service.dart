import 'dart:io';

class WhatsAppService {
  WhatsAppService._();

  static String normalize(String raw, {String defaultCountryCode = ''}) {
    var value = raw.trim().replaceAll(RegExp(r'[^0-9+]'), '');
    if (value.startsWith('00')) value = '+${value.substring(2)}';
    if (value.startsWith('+')) value = value.substring(1);
    value = value.replaceAll(RegExp(r'[^0-9]'), '');
    final cc = defaultCountryCode.replaceAll(RegExp(r'[^0-9]'), '');
    if (value.isEmpty) return '';
    if (cc.isNotEmpty && !value.startsWith(cc)) {
      // Remove domestic trunk zeroes when converting a local number to
      // international form (e.g. 05... -> <country code>5...).
      value = value.replaceFirst(RegExp(r'^0+'), '');
      value = '$cc$value';
    }
    return value;
  }

  static Future<ProcessResult> _openUri(Uri uri) async {
    if (Platform.isMacOS) return Process.run('/usr/bin/open', [uri.toString()]);
    if (Platform.isWindows) return Process.run('cmd', ['/c', 'start', '', uri.toString()], runInShell: true);
    if (Platform.isLinux) return Process.run('xdg-open', [uri.toString()]);
    throw Exception('WhatsApp messaging is currently available on RELIQ desktop.');
  }

  static Future<void> openChat({required String phone, required String message, String defaultCountryCode = ''}) async {
    final number = normalize(phone, defaultCountryCode: defaultCountryCode);
    if (number.isEmpty) throw Exception('No WhatsApp/phone number is saved for this contact.');
    if (number.length < 7) throw Exception('The saved WhatsApp/phone number looks incomplete.');

    // wa.me is the most reliable cross-platform entry point. On systems with
    // WhatsApp installed it can hand off to the app; otherwise WhatsApp Web
    // opens in the default browser. This avoids custom-scheme handlers that
    // can report success without actually opening a conversation.
    final webUri = Uri.https('wa.me', '/$number', {'text': message});
    final result = await _openUri(webUri);
    if (result.exitCode != 0) {
      throw Exception('Could not open WhatsApp. Check the saved number and your default browser/WhatsApp installation.');
    }
  }

  static String _fill(String template, Map<String,String> values) { var out=template; values.forEach((k,v)=>out=out.replaceAll('{$k}',v)); return out; }
  static String customerStatementMessage(Map<String,String> settings, Map<String,Object?> customer) => _fill(
    settings['whatsapp_statement_template'] ?? 'Hello {customer}, please find your account statement from {company}. Outstanding balance: {currency} {balance}.',
    {'customer':'${customer['name'] ?? 'Customer'}','company':settings['business_name']??'','currency':settings['currency']??'','balance':((customer['balance'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3)});
  static String paymentReminderMessage(Map<String,String> settings, Map<String,Object?> customer) => _fill(
    settings['whatsapp_reminder_template'] ?? 'Hello {customer}, this is a friendly payment reminder from {company}. Your outstanding balance is {currency} {balance}. Thank you.',
    {'customer':'${customer['name'] ?? 'Customer'}','company':settings['business_name']??'','currency':settings['currency']??'','balance':((customer['balance'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3)});
  static String purchaseOrderMessage(Map<String,String> settings, Map<String,Object?> order) => _fill(
    settings['whatsapp_po_template'] ?? 'Hello {supplier}, purchase order {po} from {company} is ready. Order value: {currency} {total}.',
    {'supplier':'${order['supplier_name'] ?? 'Supplier'}','company':settings['business_name']??'','po':'${order['no']??''}','currency':settings['currency']??'','total':((order['ordered_total'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3)});
  static String paymentMessage(Map<String,String> settings,{required String partyName,required double amount,required String kind}) => _fill(
    settings['whatsapp_payment_template'] ?? 'Hello {party}, {kind} of {currency} {amount} has been recorded by {company}. Thank you.',
    {'party':partyName,'kind':kind,'currency':settings['currency']??'','amount':amount.toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'company':settings['business_name']??''});

  static String customerReceiptMessage(Map<String,String> settings, Map<String,Object?> payment) => _fill(
    settings['whatsapp_receipt_template'] ?? 'Hello {party}, we received {currency} {amount}. Receipt {receipt} is ready. Your current account balance is {currency} {balance}. Thank you — {company}.',
    {'party':'${payment['party_name']??'Customer'}','receipt':'${payment['id']??''}','currency':settings['currency']??'','amount':((payment['amount'] as num?)??0).abs().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'balance':((payment['party_balance'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'company':settings['business_name']??''});

  static String supplierPaymentAdviceMessage(Map<String,String> settings, Map<String,Object?> payment) => _fill(
    settings['whatsapp_supplier_payment_template'] ?? 'Hello {party}, payment of {currency} {amount} has been recorded by {company}. Payment advice {payment} is ready. Current payable balance: {currency} {balance}.',
    {'party':'${payment['party_name']??'Supplier'}','payment':'${payment['id']??''}','currency':settings['currency']??'','amount':((payment['amount'] as num?)??0).abs().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'balance':((payment['party_balance'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'company':settings['business_name']??''});

  static String quotationFollowupMessage(Map<String,String> settings, Map<String,Object?> q) => _fill(
    settings['whatsapp_quotation_followup_template'] ?? 'Hello {customer}, just following up on quotation {quotation} from {company} for {currency} {total}. Please let us know if you would like us to proceed.',
    {'customer':'${q['customer_name']??'Customer'}','quotation':'${q['no']??''}','company':settings['business_name']??'','currency':settings['currency']??'','total':((q['total'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3)});

  static String quotationMessage(Map<String,String> settings, Map<String,Object?> q) => _fill(
    settings['whatsapp_quotation_template'] ?? 'Hello {customer}, please find quotation {quotation} from {company} for {currency} {total}. Valid until {valid_until}.',
    {'customer':'${q['customer_name']??'Customer'}','quotation':'${q['no']??''}','company':settings['business_name']??'','currency':settings['currency']??'','total':((q['total'] as num?)??0).toDouble().toStringAsFixed(int.tryParse(settings['currency_decimals']??'3')??3),'valid_until':'${q['valid_until']??''}'.split('T').first});

  static String invoiceMessage(Map<String,String> settings, Map<String,Object?> header) {
    final company=(settings['business_name']??'').trim();
    final customer=(header['customer_name']??'Customer').toString();
    final no=(header['no']??'').toString();
    final currency=(settings['currency']??'').trim();
    final decimals=int.tryParse(settings['currency_decimals']??'3')??3;
    final total=(header['total'] as num? ?? 0).toDouble().toStringAsFixed(decimals);
    final template=(settings['whatsapp_invoice_template']??'Hello {customer}, thank you for your purchase from {company}. Invoice {invoice} for {currency} {total} is ready.').trim();
    return template.replaceAll('{customer}',customer).replaceAll('{company}',company).replaceAll('{invoice}',no).replaceAll('{currency}',currency).replaceAll('{total}',total);
  }
}
