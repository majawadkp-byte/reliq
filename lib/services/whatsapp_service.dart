import 'dart:io';

import 'document_share_service.dart';

class WhatsAppShareResult {
  final bool pdfEnabled;
  final bool copiedToClipboard;
  final bool revealedFallback;

  const WhatsAppShareResult({
    required this.pdfEnabled,
    this.copiedToClipboard = false,
    this.revealedFallback = false,
  });

  String get auditAction {
    if (!pdfEnabled) return 'Message prepared / opened';
    if (copiedToClipboard) return 'PDF copied to clipboard / opened';
    return 'PDF prepared / revealed';
  }

  String userMessage(String documentLabel) {
    if (!pdfEnabled) {
      return 'WhatsApp is open with the message. PDF attachment is disabled in Settings.';
    }
    if (copiedToClipboard) {
      final paste = Platform.isMacOS ? '⌘V' : 'Ctrl+V';
      return '$documentLabel PDF copied to the clipboard. WhatsApp is open — press $paste to attach it, then send.';
    }
    return '$documentLabel PDF is ready in Finder/Explorer and WhatsApp is open. Drag the PDF into the chat, then send.';
  }
}

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
      value = value.replaceFirst(RegExp(r'^0+'), '');
      value = '$cc$value';
    }
    return value;
  }

  static bool pdfAttachmentsEnabled(Map<String, String> settings) {
    final raw = (settings['whatsapp_pdf_attachment_enabled'] ?? '1')
        .trim()
        .toLowerCase();
    return raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on';
  }

  static Future<ProcessResult> _openUri(Uri uri) async {
    if (Platform.isMacOS) return Process.run('/usr/bin/open', [uri.toString()]);
    if (Platform.isWindows) {
      return Process.run(
        'cmd',
        ['/c', 'start', '', uri.toString()],
        runInShell: true,
      );
    }
    if (Platform.isLinux) return Process.run('xdg-open', [uri.toString()]);
    throw Exception(
        'WhatsApp messaging is currently available on RELIQ desktop.');
  }

  static Future<void> openChat({
    required String phone,
    required String message,
    String defaultCountryCode = '',
  }) async {
    final number = normalize(phone, defaultCountryCode: defaultCountryCode);
    if (number.isEmpty) {
      throw Exception('No WhatsApp/phone number is saved for this contact.');
    }
    if (number.length < 7) {
      throw Exception('The saved WhatsApp/phone number looks incomplete.');
    }

    final webUri = Uri.https('wa.me', '/$number', {'text': message});
    final result = await _openUri(webUri);
    if (result.exitCode != 0) {
      throw Exception(
        'Could not open WhatsApp. Check the saved number and your default browser/WhatsApp installation.',
      );
    }
  }

  /// Opens WhatsApp and, when enabled in Settings, prepares the generated PDF
  /// as a clipboard file so the user can attach it with one Paste command.
  ///
  /// No UI automation is used and RELIQ never presses Send automatically.
  /// If file clipboard support fails, RELIQ safely falls back to revealing the
  /// PDF in Finder/Explorer for drag-and-drop.
  static Future<WhatsAppShareResult> shareDocument({
    required Map<String, String> settings,
    required String phone,
    required String message,
    Future<File> Function()? prepareAttachment,
  }) async {
    final pdfEnabled =
        pdfAttachmentsEnabled(settings) && prepareAttachment != null;
    final defaultCountryCode = settings['whatsapp_country_code'] ?? '';

    if (!pdfEnabled) {
      await openChat(
        phone: phone,
        message: message,
        defaultCountryCode: defaultCountryCode,
      );
      return const WhatsAppShareResult(pdfEnabled: false);
    }

    final attachment = await prepareAttachment();
    if (!await attachment.exists()) {
      throw Exception('The PDF attachment could not be created.');
    }

    final copied = await DocumentShareService.copyFileToClipboard(attachment);
    await openChat(
      phone: phone,
      message: message,
      defaultCountryCode: defaultCountryCode,
    );

    if (copied) {
      return const WhatsAppShareResult(
        pdfEnabled: true,
        copiedToClipboard: true,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 350));
    await DocumentShareService.revealFile(attachment);
    return const WhatsAppShareResult(
      pdfEnabled: true,
      revealedFallback: true,
    );
  }

  /// Backward-compatible helper for any older call sites. Clipboard delivery
  /// is attempted first; Finder/Explorer is used only as fallback.
  static Future<void> openChatWithAttachment({
    required String phone,
    required String message,
    required File attachment,
    String defaultCountryCode = '',
  }) async {
    await shareDocument(
      settings: {
        'whatsapp_pdf_attachment_enabled': '1',
        'whatsapp_country_code': defaultCountryCode,
      },
      phone: phone,
      message: message,
      prepareAttachment: () async => attachment,
    );
  }

  static String _fill(String template, Map<String, String> values) {
    var out = template;
    values.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  static String customerStatementMessage(
    Map<String, String> settings,
    Map<String, Object?> customer,
  ) =>
      _fill(
        settings['whatsapp_statement_template'] ??
            'Hello {customer}, please find your account statement from {company}. Outstanding balance: {currency} {balance}.',
        {
          'customer': '${customer['name'] ?? 'Customer'}',
          'company': settings['business_name'] ?? '',
          'currency': settings['currency'] ?? '',
          'balance':
              ((customer['balance'] as num?) ?? 0).toDouble().toStringAsFixed(
                    int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
                  ),
        },
      );

  static String paymentReminderMessage(
    Map<String, String> settings,
    Map<String, Object?> customer,
  ) =>
      _fill(
        settings['whatsapp_reminder_template'] ??
            'Hello {customer}, this is a friendly payment reminder from {company}. Your outstanding balance is {currency} {balance}. Thank you.',
        {
          'customer': '${customer['name'] ?? 'Customer'}',
          'company': settings['business_name'] ?? '',
          'currency': settings['currency'] ?? '',
          'balance':
              ((customer['balance'] as num?) ?? 0).toDouble().toStringAsFixed(
                    int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
                  ),
        },
      );

  static String purchaseOrderMessage(
    Map<String, String> settings,
    Map<String, Object?> order,
  ) =>
      _fill(
        settings['whatsapp_po_template'] ??
            'Hello {supplier}, purchase order {po} from {company} is ready. Order value: {currency} {total}.',
        {
          'supplier': '${order['supplier_name'] ?? 'Supplier'}',
          'company': settings['business_name'] ?? '',
          'po': '${order['no'] ?? ''}',
          'currency': settings['currency'] ?? '',
          'total': ((order['ordered_total'] as num?) ?? 0)
              .toDouble()
              .toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
        },
      );

  static String paymentMessage(
    Map<String, String> settings, {
    required String partyName,
    required double amount,
    required String kind,
  }) =>
      _fill(
        settings['whatsapp_payment_template'] ??
            'Hello {party}, {kind} of {currency} {amount} has been recorded by {company}. Thank you.',
        {
          'party': partyName,
          'kind': kind,
          'currency': settings['currency'] ?? '',
          'amount': amount.toStringAsFixed(
            int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
          ),
          'company': settings['business_name'] ?? '',
        },
      );

  static String customerReceiptMessage(
    Map<String, String> settings,
    Map<String, Object?> payment,
  ) =>
      _fill(
        settings['whatsapp_receipt_template'] ??
            'Hello {party}, we received {currency} {amount}. Receipt {receipt} is ready. Your current account balance is {currency} {balance}. Thank you — {company}.',
        {
          'party': '${payment['party_name'] ?? 'Customer'}',
          'receipt': '${payment['id'] ?? ''}',
          'currency': settings['currency'] ?? '',
          'amount': ((payment['amount'] as num?) ?? 0).abs().toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
          'balance': ((payment['party_balance'] as num?) ?? 0)
              .toDouble()
              .toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
          'company': settings['business_name'] ?? '',
        },
      );

  static String supplierPaymentAdviceMessage(
    Map<String, String> settings,
    Map<String, Object?> payment,
  ) =>
      _fill(
        settings['whatsapp_supplier_payment_template'] ??
            'Hello {party}, payment of {currency} {amount} has been recorded by {company}. Payment advice {payment} is ready. Current payable balance: {currency} {balance}.',
        {
          'party': '${payment['party_name'] ?? 'Supplier'}',
          'payment': '${payment['id'] ?? ''}',
          'currency': settings['currency'] ?? '',
          'amount': ((payment['amount'] as num?) ?? 0).abs().toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
          'balance': ((payment['party_balance'] as num?) ?? 0)
              .toDouble()
              .toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
          'company': settings['business_name'] ?? '',
        },
      );

  static String quotationFollowupMessage(
    Map<String, String> settings,
    Map<String, Object?> q,
  ) =>
      _fill(
        settings['whatsapp_quotation_followup_template'] ??
            'Hello {customer}, just following up on quotation {quotation} from {company} for {currency} {total}. Please let us know if you would like us to proceed.',
        {
          'customer': '${q['customer_name'] ?? 'Customer'}',
          'quotation': '${q['no'] ?? ''}',
          'company': settings['business_name'] ?? '',
          'currency': settings['currency'] ?? '',
          'total': ((q['total'] as num?) ?? 0).toDouble().toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
        },
      );

  static String quotationMessage(
    Map<String, String> settings,
    Map<String, Object?> q,
  ) =>
      _fill(
        settings['whatsapp_quotation_template'] ??
            'Hello {customer}, please find quotation {quotation} from {company} for {currency} {total}. Valid until {valid_until}.',
        {
          'customer': '${q['customer_name'] ?? 'Customer'}',
          'quotation': '${q['no'] ?? ''}',
          'company': settings['business_name'] ?? '',
          'currency': settings['currency'] ?? '',
          'total': ((q['total'] as num?) ?? 0).toDouble().toStringAsFixed(
                int.tryParse(settings['currency_decimals'] ?? '3') ?? 3,
              ),
          'valid_until': '${q['valid_until'] ?? ''}'.split('T').first,
        },
      );

  static String invoiceMessage(
    Map<String, String> settings,
    Map<String, Object?> header,
  ) {
    final company = (settings['business_name'] ?? '').trim();
    final customer = (header['customer_name'] ?? 'Customer').toString();
    final no = (header['no'] ?? '').toString();
    final currency = (settings['currency'] ?? '').trim();
    final decimals = int.tryParse(settings['currency_decimals'] ?? '3') ?? 3;
    final total =
        (header['total'] as num? ?? 0).toDouble().toStringAsFixed(decimals);
    final template = (settings['whatsapp_invoice_template'] ??
            'Hello {customer}, thank you for your purchase from {company}. Invoice {invoice} for {currency} {total} is ready.')
        .trim();
    return template
        .replaceAll('{customer}', customer)
        .replaceAll('{company}', company)
        .replaceAll('{invoice}', no)
        .replaceAll('{currency}', currency)
        .replaceAll('{total}', total);
  }
}
