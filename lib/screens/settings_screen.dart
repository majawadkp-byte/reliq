import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../config/brand.dart';
import '../data/app_database.dart';
import '../services/print_service.dart';
import 'system_updates_screen.dart';
import '../ui/v3_style.dart';

class SettingsScreen extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  final VoidCallback? onSettingsChanged;
  final int initialSection;
  const SettingsScreen(
      {super.key,
      this.onNavigate,
      this.onSettingsChanged,
      this.initialSection = 0});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int section = 0;
  final ScrollController _contentScrollController = ScrollController();
  bool loading = true;
  String status = '';
  String logoPath = '';
  String dataPath = '';
  Future<Map<String, Object?>>? auditStatsFuture;

  final business = TextEditingController();
  final legalName = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  final address = TextEditingController();
  final taxNo = TextEditingController();
  final whatsappCountryCode = TextEditingController(text: '965');
  final whatsappInvoiceTemplate = TextEditingController();
  final whatsappStatementTemplate = TextEditingController();
  final whatsappReminderTemplate = TextEditingController();
  final whatsappQuotationTemplate = TextEditingController();
  final whatsappQuotationFollowupTemplate = TextEditingController();
  final whatsappPoTemplate = TextEditingController();
  final whatsappReceiptTemplate = TextEditingController();
  final whatsappSupplierPaymentTemplate = TextEditingController();
  final customFieldLabels = List.generate(4, (_) => TextEditingController());
  final customFieldValues = List.generate(4, (_) => TextEditingController());
  final customFieldInvoice = List<bool>.filled(4, true);
  final currency = TextEditingController(text: 'KWD');
  final currencyDecimals = TextEditingController(text: '3');
  final invoiceTitle = TextEditingController(text: 'SALES INVOICE');
  final invoiceFooter = TextEditingController();
  final thankYou = TextEditingController(text: 'Thank you');
  final salePrefix = TextEditingController(text: 'S');
  final purchasePrefix = TextEditingController(text: 'P');
  final purchaseTitle = TextEditingController(text: 'PURCHASE RECEIPT');
  final purchaseFooter = TextEditingController();
  final expiryWarningDays = TextEditingController(text: '30');
  final targetCoverageDays = TextEditingController(text: '21');
  final barcodeWidth = TextEditingController(text: '55');
  final barcodeHeight = TextEditingController(text: '32');
  final backupReminderDays = TextEditingController(text: '1');
  final backupRetentionCount = TextEditingController(text: '14');
  final sessionTimeoutMinutes = TextEditingController(text: '30');

  String documentFormat = 'Thermal 80mm';
  String purchaseDocumentFormat = 'A4';
  String logoPosition = 'Center';
  String posDefaultView = 'Tiles';
  String defaultPaymentMethod = 'Cash';
  String themeDefault = 'Light';
  String salesPrintAction = 'Preview';
  String customerReceiptPrintAction = 'None';
  String purchasePrintAction = 'None';
  String supplierPaymentPrintAction = 'None';
  String salesPrinter = '';
  String customerReceiptPrinter = '';
  String purchasePrinter = '';
  String supplierPaymentPrinter = '';
  List<ReliqPrinterOption> printers = const [];
  bool loadingPrinters = false;

  bool touchDefault = false;
  bool showLogo = true;
  bool showSku = true;
  bool showBarcode = false;
  bool showTax = true;
  bool showDiscount = true;
  bool showPayment = true;
  bool showCustomer = true;
  bool showCashier = false;
  bool purchaseShowTax = true;
  bool purchaseShowDiscount = true;
  bool autoSku = true;
  bool autoBarcode = true;
  bool lowStockAlerts = true;
  bool expiryAlerts = true;
  bool barcodeShowSku = true;
  bool barcodeShowPrice = false;
  bool autoBackupEnabled = true;
  bool shortcutHelpersEnabled = true;
  bool autoForecastStockLevels = true;
  bool useLastYearSeasonality = true;
  bool whatsappPdfAttachmentEnabled = true;

  static const sections = [
    ('Business Profile', Icons.storefront_outlined),
    ('Documents & Layout', Icons.receipt_long_outlined),
    ('Sales & POS', Icons.point_of_sale_outlined),
    ('Keyboard & Productivity', Icons.keyboard_alt_outlined),
    ('Inventory', Icons.inventory_2_outlined),
    ('Printing & Documents', Icons.print_outlined),
    ('Tax', Icons.percent_outlined),
    ('Data & Security', Icons.shield_outlined),
    ('Team & Branches', Icons.group_outlined),
    ('Accounts & Payments', Icons.payments_outlined),
    ('System & Updates', Icons.system_update_alt_outlined),
    ('Sync & Integrations', Icons.sync_outlined),
  ];

  @override
  void initState() {
    super.initState();
    section = widget.initialSection.clamp(0, sections.length - 1);
    load();
  }

  void _selectSection(int value) {
    if (value == section) {
      if (_contentScrollController.hasClients) {
        _contentScrollController.animateTo(0,
            duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
      }
      return;
    }
    setState(() => section = value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_contentScrollController.hasClients) {
        _contentScrollController.jumpTo(0);
      }
    });
  }

  bool _bool(Map<String, String> values, String key, {bool fallback = false}) {
    final v = values[key];
    if (v == null || v.isEmpty) return fallback;
    return v == '1' || v.toLowerCase() == 'true' || v.toLowerCase() == 'yes';
  }

  Future<void> load() async {
    final values = await AppDatabase.instance.settings();
    final dir = await AppDatabase.instance.dataDir;
    if (!mounted) return;
    setState(() {
      business.text = values['business_name'] ?? Brand.name;
      legalName.text = values['legal_name'] ?? '';
      phone.text = values['business_phone'] ?? '';
      email.text = values['business_email'] ?? '';
      address.text = values['business_address'] ?? '';
      taxNo.text = values['tax_number'] ?? '';
      whatsappCountryCode.text = values['whatsapp_country_code'] ?? '965';
      whatsappInvoiceTemplate.text = values['whatsapp_invoice_template'] ??
          'Hello {customer}, thank you for your purchase from {company}. Invoice {invoice} for {currency} {total} is ready.';
      whatsappStatementTemplate.text = values['whatsapp_statement_template'] ??
          'Hello {customer}, please find your account statement from {company}. Outstanding balance: {currency} {balance}.';
      whatsappReminderTemplate.text = values['whatsapp_reminder_template'] ??
          'Hello {customer}, this is a friendly payment reminder from {company}. Your outstanding balance is {currency} {balance}. Thank you.';
      whatsappQuotationTemplate.text = values['whatsapp_quotation_template'] ??
          'Hello {customer}, please find quotation {quotation} from {company} for {currency} {total}. Valid until {valid_until}.';
      whatsappQuotationFollowupTemplate.text = values[
              'whatsapp_quotation_followup_template'] ??
          'Hello {customer}, just following up on quotation {quotation} from {company} for {currency} {total}. Please let us know if you would like us to proceed.';
      whatsappPoTemplate.text = values['whatsapp_po_template'] ??
          'Hello {supplier}, purchase order {po} from {company} is ready. Order value: {currency} {total}.';
      whatsappReceiptTemplate.text = values['whatsapp_receipt_template'] ??
          'Hello {party}, we received {currency} {amount}. Receipt {receipt} is ready. Your current account balance is {currency} {balance}. Thank you — {company}.';
      whatsappSupplierPaymentTemplate.text = values[
              'whatsapp_supplier_payment_template'] ??
          'Hello {party}, payment of {currency} {amount} has been recorded by {company}. Payment advice {payment} is ready. Current payable balance: {currency} {balance}.';
      whatsappPdfAttachmentEnabled =
          _bool(values, 'whatsapp_pdf_attachment_enabled', fallback: true);
      try {
        final fields =
            (jsonDecode(values['document_custom_fields'] ?? '[]') as List)
                .cast<Map>();
        for (var i = 0; i < fields.length && i < 4; i++) {
          customFieldLabels[i].text = '${fields[i]['label'] ?? ''}';
          customFieldValues[i].text = '${fields[i]['value'] ?? ''}';
          customFieldInvoice[i] = fields[i]['invoice'] != false;
        }
      } catch (_) {}
      currency.text = values['currency'] ?? 'KWD';
      currencyDecimals.text = values['currency_decimals'] ?? '3';
      invoiceTitle.text = values['invoice_title'] ?? 'SALES INVOICE';
      invoiceFooter.text = values['invoice_footer'] ?? '';
      thankYou.text = values['receipt_thank_you'] ?? 'Thank you';
      salePrefix.text = values['sale_prefix'] ?? 'S';
      purchasePrefix.text = values['purchase_prefix'] ?? 'P';
      purchaseTitle.text = values['purchase_title'] ?? 'PURCHASE RECEIPT';
      purchaseFooter.text = values['purchase_footer'] ?? '';
      expiryWarningDays.text = values['expiry_warning_days'] ?? '30';
      targetCoverageDays.text = values['target_coverage_days'] ?? '21';
      barcodeWidth.text = values['barcode_label_width_mm'] ?? '55';
      barcodeHeight.text = values['barcode_label_height_mm'] ?? '32';
      backupReminderDays.text = values['backup_reminder_days'] ?? '1';
      backupRetentionCount.text = values['backup_retention_count'] ?? '14';
      sessionTimeoutMinutes.text = values['session_timeout_minutes'] ?? '30';
      documentFormat = values['document_format'] ?? 'Thermal 80mm';
      purchaseDocumentFormat = values['purchase_document_format'] ?? 'A4';
      logoPosition = values['logo_position'] ?? 'Center';
      posDefaultView = values['pos_default_view'] ?? 'Tiles';
      defaultPaymentMethod = values['default_payment_method'] ?? 'Cash';
      themeDefault = values['theme_mode'] ?? 'Light';
      salesPrintAction = values['sales_print_action'] ??
          (_bool(values, 'auto_print_after_sale') ? 'Preview' : 'None');
      customerReceiptPrintAction =
          values['customer_receipt_print_action'] ?? 'None';
      purchasePrintAction = values['purchase_print_action'] ?? 'None';
      supplierPaymentPrintAction =
          values['supplier_payment_print_action'] ?? 'None';
      salesPrinter = values['sales_printer'] ?? '';
      customerReceiptPrinter = values['customer_receipt_printer'] ?? '';
      purchasePrinter = values['purchase_printer'] ?? '';
      supplierPaymentPrinter = values['supplier_payment_printer'] ?? '';
      touchDefault = _bool(values, 'touch_mode_default');
      showLogo = _bool(values, 'document_show_logo', fallback: true);
      showSku = _bool(values, 'document_show_sku', fallback: true);
      showBarcode = _bool(values, 'document_show_barcode');
      showTax = _bool(values, 'document_show_tax', fallback: true);
      showDiscount = _bool(values, 'document_show_discount', fallback: true);
      showPayment = _bool(values, 'document_show_payment', fallback: true);
      showCustomer = _bool(values, 'document_show_customer', fallback: true);
      showCashier = _bool(values, 'document_show_cashier');
      purchaseShowTax = _bool(values, 'purchase_show_tax', fallback: true);
      purchaseShowDiscount =
          _bool(values, 'purchase_show_discount', fallback: true);
      autoSku = _bool(values, 'auto_generate_sku', fallback: true);
      autoBarcode = _bool(values, 'auto_generate_barcode', fallback: true);
      lowStockAlerts = _bool(values, 'low_stock_alerts', fallback: true);
      expiryAlerts = _bool(values, 'expiry_alerts', fallback: true);
      barcodeShowSku = _bool(values, 'barcode_show_sku', fallback: true);
      barcodeShowPrice = _bool(values, 'barcode_show_price');
      autoBackupEnabled = _bool(values, 'auto_backup_enabled', fallback: true);
      shortcutHelpersEnabled =
          _bool(values, 'shortcut_helpers_enabled', fallback: true);
      autoForecastStockLevels =
          _bool(values, 'forecast_auto_fill_stock_levels', fallback: true);
      useLastYearSeasonality =
          _bool(values, 'forecast_use_last_year_seasonality', fallback: true);
      logoPath = values['logo_path'] ?? '';
      dataPath = dir;
      auditStatsFuture = AppDatabase.instance.auditStats();
      loading = false;
    });
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    if (!mounted) return;
    setState(() => loadingPrinters = true);
    final found = await PrintService.availablePrinters();
    if (!mounted) return;
    setState(() {
      printers = found;
      loadingPrinters = false;
    });
  }

  String _flag(bool value) => value ? '1' : '0';

  Future<void> save() async {
    final decimals =
        (int.tryParse(currencyDecimals.text.trim()) ?? 3).clamp(0, 4);
    final expiryDays =
        (int.tryParse(expiryWarningDays.text.trim()) ?? 30).clamp(0, 3650);
    final coverageDays =
        (int.tryParse(targetCoverageDays.text.trim()) ?? 21).clamp(1, 365);
    await AppDatabase.instance.saveSettings({
      'business_name': business.text.trim(),
      'legal_name': legalName.text.trim(),
      'business_phone': phone.text.trim(),
      'business_email': email.text.trim(),
      'business_address': address.text.trim(),
      'tax_number': taxNo.text.trim(),
      'whatsapp_country_code': whatsappCountryCode.text.trim(),
      'whatsapp_invoice_template': whatsappInvoiceTemplate.text.trim(),
      'whatsapp_statement_template': whatsappStatementTemplate.text.trim(),
      'whatsapp_reminder_template': whatsappReminderTemplate.text.trim(),
      'whatsapp_quotation_template': whatsappQuotationTemplate.text.trim(),
      'whatsapp_quotation_followup_template':
          whatsappQuotationFollowupTemplate.text.trim(),
      'whatsapp_po_template': whatsappPoTemplate.text.trim(),
      'whatsapp_receipt_template': whatsappReceiptTemplate.text.trim(),
      'whatsapp_supplier_payment_template':
          whatsappSupplierPaymentTemplate.text.trim(),
      'whatsapp_pdf_attachment_enabled': _flag(whatsappPdfAttachmentEnabled),
      'document_custom_fields': jsonEncode(List.generate(
              4,
              (i) => {
                    'label': customFieldLabels[i].text.trim(),
                    'value': customFieldValues[i].text.trim(),
                    'invoice': customFieldInvoice[i]
                  })
          .where((x) =>
              (x['label'] as String).isNotEmpty &&
              (x['value'] as String).isNotEmpty)
          .toList()),
      'currency': currency.text.trim().isEmpty
          ? 'KWD'
          : currency.text.trim().toUpperCase(),
      'currency_decimals': '$decimals',
      'logo_path': logoPath,
      'invoice_title': invoiceTitle.text.trim().isEmpty
          ? 'SALES INVOICE'
          : invoiceTitle.text.trim(),
      'invoice_footer': invoiceFooter.text.trim(),
      'receipt_thank_you': thankYou.text.trim(),
      'sale_prefix': salePrefix.text.trim().isEmpty
          ? 'S'
          : salePrefix.text.trim().toUpperCase(),
      'purchase_prefix': purchasePrefix.text.trim().isEmpty
          ? 'P'
          : purchasePrefix.text.trim().toUpperCase(),
      'purchase_title': purchaseTitle.text.trim().isEmpty
          ? 'PURCHASE RECEIPT'
          : purchaseTitle.text.trim(),
      'purchase_footer': purchaseFooter.text.trim(),
      'document_format': documentFormat,
      'purchase_document_format': purchaseDocumentFormat,
      'logo_position': logoPosition,
      'document_show_logo': _flag(showLogo),
      'document_show_sku': _flag(showSku),
      'document_show_barcode': _flag(showBarcode),
      'document_show_tax': _flag(showTax),
      'document_show_discount': _flag(showDiscount),
      'document_show_payment': _flag(showPayment),
      'document_show_customer': _flag(showCustomer),
      'document_show_cashier': _flag(showCashier),
      'purchase_show_tax': _flag(purchaseShowTax),
      'purchase_show_discount': _flag(purchaseShowDiscount),
      'pos_default_view': posDefaultView,
      'default_payment_method': defaultPaymentMethod,
      'sales_print_action': salesPrintAction,
      'customer_receipt_print_action': customerReceiptPrintAction,
      'purchase_print_action': purchasePrintAction,
      'supplier_payment_print_action': supplierPaymentPrintAction,
      'sales_printer': salesPrinter,
      'customer_receipt_printer': customerReceiptPrinter,
      'purchase_printer': purchasePrinter,
      'supplier_payment_printer': supplierPaymentPrinter,
      'touch_mode_default': _flag(touchDefault),
      'theme_mode': themeDefault,
      'auto_generate_sku': _flag(autoSku),
      'auto_generate_barcode': _flag(autoBarcode),
      'low_stock_alerts': _flag(lowStockAlerts),
      'expiry_alerts': _flag(expiryAlerts),
      'expiry_warning_days': '$expiryDays',
      'target_coverage_days': '$coverageDays',
      'barcode_label_width_mm':
          barcodeWidth.text.trim().isEmpty ? '55' : barcodeWidth.text.trim(),
      'barcode_label_height_mm':
          barcodeHeight.text.trim().isEmpty ? '32' : barcodeHeight.text.trim(),
      'barcode_show_sku': _flag(barcodeShowSku),
      'barcode_show_price': _flag(barcodeShowPrice),
      'auto_print_after_sale': _flag(salesPrintAction != 'None'),
      'auto_backup_enabled': _flag(autoBackupEnabled),
      'shortcut_helpers_enabled': _flag(shortcutHelpersEnabled),
      'forecast_auto_fill_stock_levels': _flag(autoForecastStockLevels),
      'forecast_use_last_year_seasonality': _flag(useLastYearSeasonality),
      'backup_reminder_days': backupReminderDays.text.trim().isEmpty
          ? '1'
          : backupReminderDays.text.trim(),
      'backup_retention_count': backupRetentionCount.text.trim().isEmpty
          ? '14'
          : backupRetentionCount.text.trim(),
      'session_timeout_minutes': sessionTimeoutMinutes.text.trim().isEmpty
          ? '30'
          : sessionTimeoutMinutes.text.trim(),
    });
    if (mounted) {
      setState(() => status =
          'Settings saved. Theme/touch defaults apply fully on the next app launch.');
      widget.onSettingsChanged?.call();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> chooseLogo() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.image, allowMultiple: false);
    final source = result?.files.single.path;
    if (source == null) return;
    final dir =
        Directory(p.join(await AppDatabase.instance.dataDir, 'branding'));
    await dir.create(recursive: true);
    final ext = p.extension(source).isEmpty ? '.png' : p.extension(source);
    final target = p.join(dir.path, 'business_logo$ext');
    await File(source).copy(target);
    if (mounted) setState(() => logoPath = target);
    await save();
  }

  Future<void> backup() async {
    final dir = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose backup folder');
    if (dir == null) return;
    try {
      final path = await AppDatabase.instance.backupTo(dir);
      if (mounted) setState(() => status = 'Backup created: $path');
    } catch (e) {
      if (mounted)
        setState(() => status =
            'Backup failed: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> restoreBackup() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose backup database',
      type: FileType.custom,
      allowedExtensions: ['db'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
            'RELIQ will first save a safety copy of the current database, verify the selected backup, then replace the live database. You will need to sign in again after restoring.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Verify & Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await AppDatabase.instance.restoreBackup(path);
      if (mounted)
        setState(() => status =
            'Backup restored successfully. Restart RELIQ before continuing transactions.');
    } catch (e) {
      if (mounted)
        setState(() => status =
            'Restore failed: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> checkDb() async {
    final result = await AppDatabase.instance.integrityCheck();
    if (mounted) setState(() => status = 'Database integrity: $result');
  }

  Future<void> manageTaxProfiles() async {
    await showDialog<void>(
        context: context, builder: (_) => const _TaxProfilesDialog());
  }

  Future<void> testPrint() async {
    await save();
    try {
      await PrintService.printTestDocument();
      if (mounted)
        setState(() => status = 'Sample invoice opened in system preview.');
    } catch (e) {
      if (mounted)
        setState(() => status =
            'Preview failed: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  void dispose() {
    for (final c in [
      business,
      legalName,
      phone,
      email,
      address,
      taxNo,
      whatsappCountryCode,
      whatsappInvoiceTemplate,
      whatsappStatementTemplate,
      whatsappReminderTemplate,
      whatsappQuotationTemplate,
      whatsappQuotationFollowupTemplate,
      whatsappPoTemplate,
      whatsappReceiptTemplate,
      whatsappSupplierPaymentTemplate,
      currency,
      currencyDecimals,
      invoiceTitle,
      invoiceFooter,
      thankYou,
      salePrefix,
      purchasePrefix,
      purchaseTitle,
      purchaseFooter,
      expiryWarningDays,
      targetCoverageDays,
      barcodeWidth,
      barcodeHeight,
      backupReminderDays,
      backupRetentionCount,
      sessionTimeoutMinutes,
    ]) {
      c.dispose();
    }
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 900;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
          decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor))),
          child: compact
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Settings',
                      style:
                          TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  const Text(
                      'Business setup, documents, operations, administration and system preferences.',
                      style: TextStyle(color: V3Style.muted, fontSize: 12)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                        onPressed: testPrint,
                        icon: const Icon(Icons.preview_outlined, size: 18),
                        label: const Text('Test document')),
                    FilledButton.icon(
                        onPressed: save,
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Save changes')),
                  ]),
                ])
              : Row(children: [
                  const Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('Settings',
                            style: TextStyle(
                                fontSize: 25, fontWeight: FontWeight.w800)),
                        SizedBox(height: 2),
                        Text(
                            'Business setup, documents, operations, administration and system preferences.',
                            style:
                                TextStyle(color: V3Style.muted, fontSize: 12)),
                      ])),
                  OutlinedButton.icon(
                      onPressed: testPrint,
                      icon: const Icon(Icons.preview_outlined, size: 18),
                      label: const Text('Test document')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                      onPressed: save,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Save changes')),
                ]),
        ),
        Expanded(
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                      SizedBox(height: 66, child: _sectionStrip()),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _contentScrollController,
                          primary: false,
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                          child: Align(
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                  width: double.infinity,
                                  child: _sectionBody())),
                        ),
                      ),
                    ])
              : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 232, child: _sectionRail()),
                  VerticalDivider(
                      width: 1, color: Theme.of(context).dividerColor),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _contentScrollController,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1180),
                          child: SizedBox(
                              width: double.infinity, child: _sectionBody()),
                        ),
                      ),
                    ),
                  ),
                ]),
        ),
        if (status.isNotEmpty)
          Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: .35),
              child: Text(status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))),
      ]);
    });
  }

  Widget _sectionRail() => ListView(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
        children: [
          _railGroupLabel('BUSINESS SETUP'),
          _sectionTile(0),
          _sectionTile(1),
          const SizedBox(height: 8),
          _railGroupLabel('OPERATIONS'),
          _sectionTile(2),
          _sectionTile(3),
          _sectionTile(4),
          const SizedBox(height: 8),
          _railGroupLabel('DOCUMENTS & COMPLIANCE'),
          _sectionTile(5),
          _sectionTile(6),
          const SizedBox(height: 8),
          _railGroupLabel('ADMINISTRATION'),
          _sectionTile(7),
          _sectionTile(8),
          _sectionTile(9),
          const SizedBox(height: 8),
          _railGroupLabel('SYSTEM'),
          _sectionTile(10),
          _sectionTile(11),
        ],
      );

  Widget _railGroupLabel(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.15,
          ),
        ),
      );

  Widget _sectionTile(int i) {
    final selected = section == i;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.primary.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark ? .16 : .10),
        selectedColor: Theme.of(context).colorScheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        dense: true,
        visualDensity: const VisualDensity(vertical: -1),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        leading: Icon(sections[i].$2, size: 19),
        title: Text(sections[i].$1,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
        onTap: () => _selectSection(i),
      ),
    );
  }

  Widget _sectionStrip() => ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        itemCount: sections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, i) => ChoiceChip(
          selected: section == i,
          avatar: Icon(sections[i].$2, size: 17),
          label: Text(sections[i].$1),
          onSelected: (_) => _selectSection(i),
        ),
      );

  Widget _sectionBody() {
    switch (section) {
      case 0:
        return _businessSection();
      case 1:
        return _documentsSection();
      case 2:
        return _posSection();
      case 3:
        return _keyboardSection();
      case 4:
        return _inventorySection();
      case 5:
        return _printingSection();
      case 6:
        return _taxSection();
      case 7:
        return _dataSection();
      case 8:
        return _card(
          title: 'Team & Branches',
          subtitle:
              'Manage users, roles, branch access, active branch and registered terminals from one setup area.',
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () => widget.onNavigate?.call(16),
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: const Text('Open Team & Branches'),
                ),
                OutlinedButton.icon(
                  onPressed: () => widget.onNavigate?.call(16),
                  icon: const Icon(Icons.store_mall_directory_outlined),
                  label: const Text('Manage Branches & Terminals'),
                ),
              ],
            ),
          ],
        );
      case 9:
        return _card(
            title: 'Customer, supplier and payment accounts',
            subtitle:
                'Review balances, allocate payments and manage account terms.',
            children: [
              FilledButton.icon(
                  onPressed: () => widget.onNavigate?.call(11),
                  icon: const Icon(Icons.payments),
                  label: const Text('Open Accounts & Payments')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: () => widget.onNavigate?.call(19),
                  icon: const Icon(Icons.shopping_cart_outlined),
                  label: const Text('Purchase Orders'))
            ]);
      case 10:
        return const SystemUpdatesScreen();
      case 11:
        return _card(
            title: 'Sync & Integrations',
            subtitle:
                'Configure the cloud connection, devices and synchronization.',
            children: [
              FilledButton.icon(
                  onPressed: () => widget.onNavigate?.call(22),
                  icon: const Icon(Icons.sync),
                  label: const Text('Open Sync Center'))
            ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _title(String title, String subtitle, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  color: const Color(0xFFEAF1FF),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: V3Style.blueDark)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(color: V3Style.muted, fontSize: 12)),
              ])),
        ]),
      );

  Widget _card(
          {required String title,
          String? subtitle,
          required List<Widget> children}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(subtitle,
                  style: const TextStyle(color: V3Style.muted, fontSize: 11))
            ],
            const SizedBox(height: 15),
            ...children,
          ]),
        ),
      );

  Widget _reliqBrandBlock() => LayoutBuilder(
        builder: (context, box) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          final logoAsset =
              dark ? 'assets/branding/reliq_logo_white.png' : Brand.logoAsset;
          final logo = SizedBox(
            width: box.maxWidth > 680 ? 320 : box.maxWidth,
            height: 72,
            child: Image.asset(logoAsset,
                fit: BoxFit.contain, alignment: Alignment.centerLeft),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(Brand.versionLabel,
                  style: TextStyle(fontWeight: FontWeight.w800)),
              SizedBox(height: 3),
              Text(Brand.tagline,
                  style: TextStyle(color: V3Style.muted, fontSize: 12)),
              SizedBox(height: 2),
              Text(Brand.copyright,
                  style: TextStyle(color: V3Style.muted, fontSize: 10)),
            ],
          );
          if (box.maxWidth > 680) {
            return Row(children: [
              logo,
              const SizedBox(width: 20),
              Expanded(child: details)
            ]);
          }
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [logo, const SizedBox(height: 10), details]);
        },
      );

  Widget _businessSection() {
    final logo = logoPath.isNotEmpty && File(logoPath).existsSync()
        ? File(logoPath)
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(
          'Business Profile',
          'Company identity, contact details and core business defaults.',
          Icons.storefront_outlined),
      _card(title: 'Brand & company details', children: [
        _reliqBrandBlock(),
        const Divider(height: 28),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 150,
            height: 100,
            decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12)),
            child: logo == null
                ? const Center(child: Text('No business logo'))
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.file(logo, fit: BoxFit.contain)),
          ),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                OutlinedButton.icon(
                    onPressed: chooseLogo,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Upload / replace business logo')),
                const SizedBox(height: 7),
                const Text(
                    'PNG/JPG works best. This is your company logo used on customer-facing documents.',
                    style: TextStyle(fontSize: 11, color: V3Style.muted)),
              ])),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: business,
                  decoration: const InputDecoration(
                      labelText: 'Trading / business name'))),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
                  controller: legalName,
                  decoration: const InputDecoration(
                      labelText: 'Legal name (optional)'))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: phone,
                  decoration: const InputDecoration(labelText: 'Phone'))),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
                  controller: email,
                  decoration: const InputDecoration(labelText: 'Email'))),
        ]),
        const SizedBox(height: 10),
        TextField(
            controller: address,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Business address')),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, box) {
          const common = [
            'KWD',
            'USD',
            'EUR',
            'GBP',
            'AED',
            'SAR',
            'QAR',
            'BHD',
            'OMR',
            'INR',
            'PKR',
            'PHP',
            'BDT',
            'EGP',
            'JOD',
            'TRY',
            'CAD',
            'AUD',
            'JPY',
            'CNY'
          ];
          final current = currency.text.trim().toUpperCase();
          final selected = common.contains(current) ? current : 'Other';
          return Wrap(spacing: 10, runSpacing: 10, children: [
            SizedBox(
                width: box.maxWidth > 700 ? 430 : box.maxWidth,
                child: TextField(
                    controller: taxNo,
                    decoration: const InputDecoration(
                        labelText: 'Tax / registration number'))),
            SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                    value: selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: [...common, 'Other']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) => setState(() {
                          if (v != null && v != 'Other')
                            currency.text = v;
                          else if (v == 'Other' &&
                              common
                                  .contains(currency.text.trim().toUpperCase()))
                            currency.text = '';
                        }))),
            if (selected == 'Other')
              SizedBox(
                  width: 190,
                  child: TextField(
                      controller: currency,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                          labelText: 'Currency code', hintText: 'e.g. ZAR'))),
            SizedBox(
                width: 160,
                child: TextField(
                    controller: currencyDecimals,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Decimals (0–4)'))),
          ]);
        }),
      ]),
    ]);
  }

  Widget _documentsSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Documents & Layout',
            'Control document appearance, legal fields, numbering and sharing messages.',
            Icons.receipt_long_outlined),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              flex: 5,
              child: Column(children: [
                _card(title: 'Sales invoice / receipt', children: [
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: invoiceTitle,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                                labelText: 'Document title'))),
                    const SizedBox(width: 10),
                    SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                            value: documentFormat,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'Format'),
                            items: const ['Thermal 80mm', 'Thermal 58mm', 'A4']
                                .map((x) =>
                                    DropdownMenuItem(value: x, child: Text(x)))
                                .toList(),
                            onChanged: (v) => setState(
                                () => documentFormat = v ?? documentFormat)))
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: salePrefix,
                            decoration: const InputDecoration(
                                labelText: 'Sales number prefix',
                                hintText: 'S'))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: DropdownButtonFormField<String>(
                            value: logoPosition,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: 'Logo position'),
                            items: const ['Left', 'Center', 'Right']
                                .map((x) =>
                                    DropdownMenuItem(value: x, child: Text(x)))
                                .toList(),
                            onChanged: (v) => setState(
                                () => logoPosition = v ?? logoPosition)))
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                      controller: invoiceFooter,
                      onChanged: (_) => setState(() {}),
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'Invoice footer / terms')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: thankYou,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                          labelText: 'Thank-you message')),
                  const SizedBox(height: 10),
                  _switchWrap([
                    ('Logo', showLogo, (v) => setState(() => showLogo = v)),
                    ('SKU', showSku, (v) => setState(() => showSku = v)),
                    (
                      'Barcode',
                      showBarcode,
                      (v) => setState(() => showBarcode = v)
                    ),
                    ('Tax', showTax, (v) => setState(() => showTax = v)),
                    (
                      'Discount',
                      showDiscount,
                      (v) => setState(() => showDiscount = v)
                    ),
                    (
                      'Payment',
                      showPayment,
                      (v) => setState(() => showPayment = v)
                    ),
                    (
                      'Customer',
                      showCustomer,
                      (v) => setState(() => showCustomer = v)
                    ),
                    (
                      'Cashier',
                      showCashier,
                      (v) => setState(() => showCashier = v)
                    ),
                  ]),
                ]),
                const SizedBox(height: 14),
                _card(title: 'Purchase document', children: [
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: purchaseTitle,
                            decoration: const InputDecoration(
                                labelText: 'Purchase document title'))),
                    const SizedBox(width: 10),
                    SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                            value: purchaseDocumentFormat,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'Format'),
                            items: const ['Thermal 80mm', 'Thermal 58mm', 'A4']
                                .map((x) =>
                                    DropdownMenuItem(value: x, child: Text(x)))
                                .toList(),
                            onChanged: (v) => setState(() =>
                                purchaseDocumentFormat =
                                    v ?? purchaseDocumentFormat)))
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                      controller: purchasePrefix,
                      decoration: const InputDecoration(
                          labelText: 'Purchase number prefix', hintText: 'P')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: purchaseFooter,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'Purchase footer / notes')),
                  const SizedBox(height: 8),
                  _switchWrap([
                    (
                      'Show tax',
                      purchaseShowTax,
                      (v) => setState(() => purchaseShowTax = v)
                    ),
                    (
                      'Show discount',
                      purchaseShowDiscount,
                      (v) => setState(() => purchaseShowDiscount = v)
                    ),
                  ]),
                ]),
              ])),
          const SizedBox(width: 14),
          Expanded(flex: 3, child: _documentPreview()),
        ]),
        const SizedBox(height: 14),
        _card(
          title: 'Legal & regulatory document fields',
          subtitle:
              'Optional fields printed on invoices where required, such as VAT registration, CR number, GSTIN or industry licences.',
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                      child: TextField(
                          controller: customFieldLabels[i],
                          decoration: InputDecoration(
                              labelText: 'Field ${i + 1} label',
                              hintText: i == 0
                                  ? 'VAT / CR / GSTIN / Licence No.'
                                  : null))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: customFieldValues[i],
                          decoration:
                              const InputDecoration(labelText: 'Value'))),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 155,
                      child: CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Show on invoice',
                              style: TextStyle(fontSize: 12)),
                          value: customFieldInvoice[i],
                          onChanged: (v) => setState(
                              () => customFieldInvoice[i] = v ?? true))),
                ]),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _card(
          title: 'WhatsApp & PDF sharing',
          subtitle:
              'Document delivery belongs with document settings. Configure the PDF helper and the message RELIQ prepares for each document type.',
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: whatsappPdfAttachmentEnabled,
              onChanged: (v) =>
                  setState(() => whatsappPdfAttachmentEnabled = v),
              title: const Text('Enable PDF attachment helper'),
              subtitle: const Text(
                  'Generates the document PDF and copies the file to the system clipboard before opening WhatsApp. Paste with ⌘V on Mac or Ctrl+V on Windows. RELIQ does not press Send automatically.'),
            ),
            const SizedBox(height: 6),
            SizedBox(
                width: 220,
                child: TextField(
                    controller: whatsappCountryCode,
                    decoration: const InputDecoration(
                        labelText: 'Default WhatsApp country code',
                        prefixText: '+'))),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, box) {
              final fieldWidth =
                  box.maxWidth > 900 ? (box.maxWidth - 12) / 2 : box.maxWidth;
              return Wrap(spacing: 12, runSpacing: 10, children: [
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappInvoiceTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Sales invoice message',
                            helperText:
                                '{customer} {company} {invoice} {currency} {total}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappStatementTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Customer statement message',
                            helperText:
                                '{customer} {company} {currency} {balance}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappReminderTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Payment reminder message',
                            helperText:
                                '{customer} {company} {currency} {balance}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappQuotationTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Quotation message',
                            helperText:
                                '{customer} {quotation} {company} {currency} {total} {valid_until}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappQuotationFollowupTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Quotation follow-up message',
                            helperText:
                                '{customer} {quotation} {company} {currency} {total}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappPoTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Purchase order message',
                            helperText:
                                '{supplier} {po} {company} {currency} {total}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappReceiptTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Customer receipt message',
                            helperText:
                                '{party} {receipt} {company} {currency} {amount} {balance}'))),
                SizedBox(
                    width: fieldWidth,
                    child: TextField(
                        controller: whatsappSupplierPaymentTemplate,
                        decoration: const InputDecoration(
                            labelText: 'Supplier payment advice message',
                            helperText:
                                '{party} {payment} {company} {currency} {amount} {balance}'))),
              ]);
            }),
          ],
        ),
      ]);

  Widget _documentPreview() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                  child: Text('Live design preview',
                      style: TextStyle(fontWeight: FontWeight.w800))),
              IconButton(
                  tooltip: 'Open PDF sample',
                  onPressed: testPrint,
                  icon: const Icon(Icons.open_in_new, size: 18))
            ]),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(minHeight: 420),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFDDE4EA)),
                  borderRadius: BorderRadius.circular(10)),
              child: DefaultTextStyle(
                style: const TextStyle(color: Color(0xFF1D2935), fontSize: 10),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showLogo)
                        Align(
                            alignment: logoPosition == 'Left'
                                ? Alignment.centerLeft
                                : logoPosition == 'Right'
                                    ? Alignment.centerRight
                                    : Alignment.center,
                            child: Container(
                                width: 52,
                                height: 32,
                                decoration: BoxDecoration(
                                    color: const Color(0xFFEAF1FF),
                                    borderRadius: BorderRadius.circular(6)),
                                child: const Icon(Icons.image_outlined,
                                    size: 18, color: V3Style.blue))),
                      const SizedBox(height: 6),
                      Text(
                          business.text.trim().isEmpty
                              ? 'YOUR BUSINESS'
                              : business.text.trim().toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w900)),
                      if (address.text.trim().isNotEmpty)
                        Text(address.text.trim(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 8)),
                      const Divider(height: 18),
                      Text(
                          invoiceTitle.text.trim().isEmpty
                              ? 'SALES INVOICE'
                              : invoiceTitle.text.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      const Text('Invoice: SAMPLE-001'),
                      if (showCustomer) const Text('Customer: Sample Customer'),
                      const SizedBox(height: 8),
                      _previewLine('Sample Product', '2 × 1.250', '2.500'),
                      if (showDiscount)
                        const Align(
                            alignment: Alignment.centerRight,
                            child: Text('Discount -0.100',
                                style: TextStyle(fontSize: 8))),
                      if (showTax)
                        const Align(
                            alignment: Alignment.centerRight,
                            child: Text('Tax 0.120',
                                style: TextStyle(fontSize: 8))),
                      const Divider(height: 18),
                      _previewMoney('Subtotal', '6.000'),
                      if (showTax) _previewMoney('Tax', '0.295'),
                      _previewMoney('TOTAL', '6.695', strong: true),
                      if (showPayment) _previewMoney('Paid', '6.695'),
                      const SizedBox(height: 24),
                      if (invoiceFooter.text.trim().isNotEmpty)
                        Text(invoiceFooter.text.trim(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 8)),
                      if (thankYou.text.trim().isNotEmpty)
                        Text(thankYou.text.trim(),
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
              ),
            ),
          ]),
        ),
      );

  Widget _previewLine(String a, String b, String c) => Row(children: [
        Expanded(
            child:
                Text(a, style: const TextStyle(fontWeight: FontWeight.w700))),
        Text(b),
        const SizedBox(width: 8),
        Text(c, style: const TextStyle(fontWeight: FontWeight.w700))
      ]);
  Widget _previewMoney(String label, String value, {bool strong = false}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontWeight:
                            strong ? FontWeight.w900 : FontWeight.w400))),
            Text(
                '${currency.text.trim().isEmpty ? 'KWD' : currency.text.trim().toUpperCase()} $value',
                style: TextStyle(
                    fontWeight: strong ? FontWeight.w900 : FontWeight.w500))
          ]));

  Widget _switchWrap(List<(String, bool, ValueChanged<bool>)> items) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items
            .map((e) => FilterChip(
                selected: e.$2,
                label: Text(e.$1),
                onSelected: e.$3,
                showCheckmark: true))
            .toList(),
      );

  Widget _posSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'POS Defaults',
            'Choose the startup behavior for counter staff and touch devices.',
            Icons.point_of_sale_outlined),
        _card(title: 'Counter workflow', children: [
          Row(children: [
            Expanded(
                child: DropdownButtonFormField<String>(
                    value: posDefaultView,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Default POS interface'),
                    items: const ['Tiles', 'Normal']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => posDefaultView = v ?? posDefaultView))),
            const SizedBox(width: 10),
            Expanded(
                child: DropdownButtonFormField<String>(
                    value: defaultPaymentMethod,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Default payment method'),
                    items: const ['Cash', 'Card', 'Bank', 'Cheque', 'Other']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) => setState(() =>
                        defaultPaymentMethod = v ?? defaultPaymentMethod))),
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start in Touch Mode'),
              subtitle: const Text(
                  'Larger rows, icons, inputs and buttons on launch.'),
              value: touchDefault,
              onChanged: (v) => setState(() => touchDefault = v)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
              value: themeDefault,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: 'Default appearance'),
              items: const ['Light', 'Dark']
                  .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                  .toList(),
              onChanged: (v) =>
                  setState(() => themeDefault = v ?? themeDefault)),
        ]),
        const SizedBox(height: 14),
        _card(
            title: 'Keyboard-first operation',
            subtitle:
                'Normal POS remains optimized for barcode scanners and keyboard entry.',
            children: const [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.keyboard_alt_outlined, color: V3Style.blue),
                  title: Text('Type / scan → Enter'),
                  subtitle: Text(
                      'The first or exact matching product is added without reaching for the mouse.')),
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.qr_code_scanner_outlined, color: V3Style.blue),
                  title: Text('Barcode-ready search'),
                  subtitle: Text(
                      'External barcode, internal barcode and SKU all resolve through the same field.')),
            ]),
      ]);

  Widget _keyboardSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Keyboard & Productivity',
            'Control keyboard hints while keeping every configured shortcut active.',
            Icons.keyboard_alt_outlined),
        _card(title: 'Shortcut helpers', children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show keyboard shortcut helpers'),
            subtitle: const Text(
                'Shows shortcut badges in navigation and contextual key strips on supported screens. Turning this off hides the hints only; the shortcuts still work.'),
            value: shortcutHelpersEnabled,
            onChanged: (v) => setState(() => shortcutHelpersEnabled = v),
          ),
          const Divider(height: 26),
          const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.search_outlined, color: V3Style.blue),
              title: Text('Ctrl/Cmd + F'),
              subtitle: Text(
                  'Universal RELIQ Lookup: find products, customers and suppliers from any screen; customer/supplier results open their ledgers.')),
          const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.help_outline, color: V3Style.blue),
              title: Text('Shift + ?'),
              subtitle: Text(
                  'Open the Keyboard Shortcuts guide from anywhere supported.')),
        ]),
      ]);

  Widget _inventorySection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Inventory Defaults',
            'Rules used when products are created and when inventory needs attention.',
            Icons.inventory_2_outlined),
        _card(title: 'Product codes', children: [
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-generate SKU when blank'),
              subtitle: const Text(
                  'Recommended for consistent product lookup and reports.'),
              value: autoSku,
              onChanged: (v) => setState(() => autoSku = v)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-generate EAN-13 barcode when blank'),
              value: autoBarcode,
              onChanged: (v) => setState(() => autoBarcode = v)),
        ]),
        const SizedBox(height: 14),
        _card(title: 'Alerts & planning', children: [
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Low-stock alerts'),
              value: lowStockAlerts,
              onChanged: (v) => setState(() => lowStockAlerts = v)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Expiry alerts'),
              value: expiryAlerts,
              onChanged: (v) => setState(() => expiryAlerts = v)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: expiryWarningDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Expiry warning horizon (days)'))),
            const SizedBox(width: 10),
            Expanded(
                child: TextField(
                    controller: targetCoverageDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Default target stock coverage (days)'))),
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
                'Auto-fill Minimum Stock & Target Stock from demand forecast'),
            subtitle: const Text(
                'When forecast confidence is Medium or High, RELIQ updates product Min Stock and Target Stock automatically. MOQ, order multiple and case pack are never changed.'),
            value: autoForecastStockLevels,
            onChanged: (v) => setState(() => autoForecastStockLevels = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use last-year seasonality when available'),
            subtitle: const Text(
                'Blends the equivalent period from last year with recent trend, weekday pattern, demand variability and intermittent-demand behavior. Requires enough history.'),
            value: useLastYearSeasonality,
            onChanged: (v) => setState(() => useLastYearSeasonality = v),
          ),
          const SizedBox(height: 8),
          const Text(
              'Forecast planning uses 7/30/60/90-day demand, lead time, safety stock, weekday patterns, recent momentum and last-year seasonality. The coverage setting controls how far beyond supplier lead time RELIQ builds the target stock.',
              style: TextStyle(fontSize: 11, color: V3Style.muted)),
        ]),
      ]);

  static const _printActions = ['None', 'Preview', 'Print directly'];

  Widget _printingSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Printing & Documents',
            'Choose preview or direct printing independently for every document workflow.',
            Icons.print_outlined),
        _card(
          title: 'Installed printers',
          subtitle:
              'RELIQ reads printers from the operating system. Set a printer per document type or leave it on System default.',
          children: [
            Row(children: [
              Expanded(
                  child: Text(
                      loadingPrinters
                          ? 'Checking printers…'
                          : printers.isEmpty
                              ? 'No printers reported by the operating system. Preview remains available.'
                              : '${printers.length} printer${printers.length == 1 ? '' : 's'} available',
                      style: const TextStyle(color: V3Style.muted))),
              OutlinedButton.icon(
                  onPressed: loadingPrinters ? null : _loadPrinters,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('Refresh printers')),
            ]),
          ],
        ),
        const SizedBox(height: 14),
        _printPolicyCard(
          title: 'Sales invoice / POS receipt',
          subtitle: 'This setting applies only after completing a sale.',
          icon: Icons.point_of_sale_outlined,
          action: salesPrintAction,
          printer: salesPrinter,
          formatWidget: DropdownButtonFormField<String>(
              value: documentFormat,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: 'Paper / document format'),
              items: const ['Thermal 58mm', 'Thermal 80mm', 'A4']
                  .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                  .toList(),
              onChanged: (v) =>
                  setState(() => documentFormat = v ?? documentFormat)),
          onAction: (v) => setState(() => salesPrintAction = v),
          onPrinter: (v) => setState(() => salesPrinter = v),
        ),
        const SizedBox(height: 14),
        _printPolicyCard(
          title: 'Customer cash receipt',
          subtitle:
              'Independent from sales invoices. Keep this manual even when sales auto-print.',
          icon: Icons.receipt_long_outlined,
          action: customerReceiptPrintAction,
          printer: customerReceiptPrinter,
          onAction: (v) => setState(() => customerReceiptPrintAction = v),
          onPrinter: (v) => setState(() => customerReceiptPrinter = v),
        ),
        const SizedBox(height: 14),
        _printPolicyCard(
          title: 'Purchase invoice / goods receipt',
          subtitle:
              'Controls printing after receiving a purchase. It does not follow the sales setting.',
          icon: Icons.shopping_cart_checkout_outlined,
          action: purchasePrintAction,
          printer: purchasePrinter,
          formatWidget: DropdownButtonFormField<String>(
              value: purchaseDocumentFormat,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: 'Purchase document format'),
              items: const ['Thermal 58mm', 'Thermal 80mm', 'A4']
                  .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                  .toList(),
              onChanged: (v) => setState(
                  () => purchaseDocumentFormat = v ?? purchaseDocumentFormat)),
          onAction: (v) => setState(() => purchasePrintAction = v),
          onPrinter: (v) => setState(() => purchasePrinter = v),
        ),
        const SizedBox(height: 14),
        _printPolicyCard(
          title: 'Supplier payment voucher',
          subtitle: 'Independent supplier-payment printing policy.',
          icon: Icons.payments_outlined,
          action: supplierPaymentPrintAction,
          printer: supplierPaymentPrinter,
          onAction: (v) => setState(() => supplierPaymentPrintAction = v),
          onPrinter: (v) => setState(() => supplierPaymentPrinter = v),
        ),
        const SizedBox(height: 14),
        _card(title: 'Test & barcode labels', children: [
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.tonalIcon(
                onPressed: testPrint,
                icon: const Icon(Icons.preview_outlined),
                label: const Text('Save & preview sample sales invoice')),
          ]),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            final narrow = c.maxWidth < 620;
            final fields = [
              TextField(
                  controller: barcodeWidth,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Barcode label width (mm)')),
              TextField(
                  controller: barcodeHeight,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Barcode label height (mm)')),
            ];
            return narrow
                ? Column(children: [
                    fields[0],
                    const SizedBox(height: 10),
                    fields[1]
                  ])
                : Row(children: [
                    Expanded(child: fields[0]),
                    const SizedBox(width: 12),
                    Expanded(child: fields[1])
                  ]);
          }),
          const SizedBox(height: 8),
          _switchWrap([
            (
              'Show SKU',
              barcodeShowSku,
              (v) => setState(() => barcodeShowSku = v)
            ),
            (
              'Show selling price',
              barcodeShowPrice,
              (v) => setState(() => barcodeShowPrice = v)
            ),
          ]),
        ]),
      ]);

  Widget _printPolicyCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String action,
    required String printer,
    required ValueChanged<String> onAction,
    required ValueChanged<String> onPrinter,
    Widget? formatWidget,
  }) =>
      _card(title: title, subtitle: subtitle, children: [
        LayoutBuilder(builder: (context, c) {
          final printerValues = <String>{
            '',
            ...printers.map((p) => p.name),
            if (printer.isNotEmpty) printer
          }.toList();
          final actionField = DropdownButtonFormField<String>(
            value: _printActions.contains(action) ? action : 'None',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'After saving'),
            items: _printActions
                .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                .toList(),
            onChanged: (v) {
              if (v != null) onAction(v);
            },
          );
          final printerField = DropdownButtonFormField<String>(
            value: printerValues.contains(printer) ? printer : '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Printer'),
            items: printerValues
                .map((x) => DropdownMenuItem(
                    value: x, child: Text(x.isEmpty ? 'System default' : x)))
                .toList(),
            onChanged:
                action == 'Print directly' ? (v) => onPrinter(v ?? '') : null,
          );
          final widgets = <Widget>[
            actionField,
            printerField,
            if (formatWidget != null) formatWidget
          ];
          if (c.maxWidth < 760)
            return Column(children: [
              for (int i = 0; i < widgets.length; i++) ...[
                widgets[i],
                if (i < widgets.length - 1) const SizedBox(height: 10)
              ]
            ]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (int i = 0; i < widgets.length; i++) ...[
              Expanded(child: widgets[i]),
              if (i < widgets.length - 1) const SizedBox(width: 12)
            ]
          ]);
        }),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              action == 'Print directly'
                  ? Icons.print_outlined
                  : action == 'Preview'
                      ? Icons.preview_outlined
                      : Icons.check_circle_outline,
              size: 18,
              color: V3Style.blue),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  action == 'Print directly'
                      ? 'The document is sent straight to the selected/default printer without opening a preview.'
                      : action == 'Preview'
                          ? 'The document opens for review first. Printing is then optional.'
                          : 'The transaction is saved without opening or printing a document. Staff can print it manually later.',
                  style: const TextStyle(color: V3Style.muted, fontSize: 11))),
        ]),
      ]);

  Widget _taxSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Tax Configuration',
            'Reusable rates shared by products, purchases, sales, expenses and reports.',
            Icons.percent_outlined),
        _card(title: 'Tax profiles', children: [
          const Text(
              'Create rates such as VAT 5%, exempt/zero-rate, inclusive or exclusive pricing. The default tax profile can be selected when products are created.',
              style: TextStyle(color: V3Style.muted, fontSize: 12)),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
              onPressed: manageTaxProfiles,
              icon: const Icon(Icons.settings_suggest_outlined),
              label: const Text('Manage tax profiles')),
        ]),
      ]);

  String _formatBytes(Object? raw) {
    var value = (raw as num?)?.toDouble() ?? 0;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
  }

  Widget _auditMetric(String label, String value) => Container(
        width: 175,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10,
                  color: V3Style.muted,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _dataSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(
            'Data Safety & Security',
            'Keep the live database local; back it up to a safe folder as often as required.',
            Icons.shield_outlined),
        _card(title: 'Database', children: [
          SelectableText('Live database folder: $dataPath',
              style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 12),
          Wrap(spacing: 9, runSpacing: 9, children: [
            FilledButton.tonalIcon(
                onPressed: backup,
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Backup now')),
            OutlinedButton.icon(
                onPressed: restoreBackup,
                icon: const Icon(Icons.restore_outlined),
                label: const Text('Restore backup')),
            OutlinedButton.icon(
                onPressed: checkDb,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('Check database integrity')),
            FilledButton.icon(
                onPressed: () => widget.onNavigate?.call(23),
                icon: const Icon(Icons.move_up_outlined),
                label: const Text('Migration Center')),
          ]),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: autoBackupEnabled,
            onChanged: (v) => setState(() => autoBackupEnabled = v),
            title: const Text('Automatic local backups'),
            subtitle: const Text(
                'Creates versioned SQLite snapshots inside the application-data folder. Older backups are rotated automatically.'),
          ),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: backupReminderDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Automatic backup interval (days)'))),
            const SizedBox(width: 10),
            Expanded(
                child: TextField(
                    controller: backupRetentionCount,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Backups to keep'))),
          ]),
          const SizedBox(height: 8),
          const Text(
              'For off-device protection, copy the generated backup folder to an external disk or a mounted Google Drive / OneDrive folder. Never place the live SQLite database itself in a synchronized folder.',
              style: TextStyle(fontSize: 11, color: V3Style.muted)),
        ]),
        const SizedBox(height: 14),
        _card(title: 'Audit log', children: [
          const Text(
            'Important business and security changes are stored in an append-only audit trail. The live view is indexed and paginated so a long history does not need to be loaded into memory.',
            style: TextStyle(color: V3Style.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, Object?>>(
            future: auditStatsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator(minHeight: 2);
              }
              if (snapshot.hasError) {
                return Text('Audit statistics unavailable: ${snapshot.error}',
                    style: const TextStyle(color: V3Style.muted, fontSize: 11));
              }
              final data = snapshot.data ?? const <String, Object?>{};
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _auditMetric('Live events', '${data['total'] ?? 0}'),
                  _auditMetric('Last 30 days', '${data['last_30_days'] ?? 0}'),
                  _auditMetric('Estimated audit data',
                      _formatBytes(data['estimated_bytes'])),
                  _auditMetric(
                      'Live database', _formatBytes(data['database_bytes'])),
                  _auditMetric(
                      'Archive files', '${data['archive_count'] ?? 0}'),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 9, runSpacing: 9, children: [
            FilledButton.tonalIcon(
              onPressed: () => widget.onNavigate?.call(24),
              icon: const Icon(Icons.manage_search_outlined),
              label: const Text('Open Audit Trail'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(
                  () => auditStatsFuture = AppDatabase.instance.auditStats()),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh audit size'),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Older events are never deleted automatically. Use Archive old history inside Audit Trail to create and verify a separate SQLite archive before removing old rows from the live database.',
            style: TextStyle(fontSize: 11, color: V3Style.muted),
          ),
        ]),
        const SizedBox(height: 14),
        _card(title: 'Session security', children: [
          TextField(
              controller: sessionTimeoutMinutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Idle session timeout (minutes)',
                  helperText:
                      'RELIQ automatically locks the signed-in session after this period of inactivity.')),
          const SizedBox(height: 10),
          const ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.manage_accounts_outlined, color: V3Style.blue),
              title: Text('Users, passwords and role permissions'),
              subtitle: Text(
                  'Use Users & Roles from the Admin section to add, edit, disable, reset passwords and assign branch access.')),
          const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.store_mall_directory_outlined,
                  color: V3Style.blue),
              title: Text('Branches & terminals'),
              subtitle: Text('Managed from Users & Roles / Team & Locations.')),
          const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.verified_user_outlined, color: V3Style.blue),
              title: Text('License'),
              subtitle: Text(
                  'Activation, entitlements and expiry remain on the dedicated License page.')),
        ]),
      ]);
}

class _TaxProfilesDialog extends StatefulWidget {
  const _TaxProfilesDialog();

  @override
  State<_TaxProfilesDialog> createState() => _TaxProfilesDialogState();
}

class _TaxProfilesDialogState extends State<_TaxProfilesDialog> {
  int refresh = 0;

  Future<void> _edit({Map<String, Object?>? existing}) async {
    String code = existing?['code']?.toString() ?? '';
    String name = existing?['name']?.toString() ?? '';
    String rate = ((existing?['rate'] as num?) ?? 0).toString();
    bool inclusive = ((existing?['price_inclusive'] as num?) ?? 0).toInt() == 1;
    bool makeDefault = ((existing?['is_default'] as num?) ?? 0).toInt() == 1;
    final isNoTax = code == 'NONE';

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title:
              Text(existing == null ? 'Add Tax Profile' : 'Edit Tax Profile'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: code,
                      enabled: existing == null && !isNoTax,
                      autofocus: existing == null,
                      decoration: const InputDecoration(
                          labelText: 'Code', hintText: 'VAT5'),
                      onChanged: (v) => code = v,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      initialValue: name,
                      enabled: !isNoTax,
                      decoration: const InputDecoration(labelText: 'Name'),
                      onChanged: (v) => name = v,
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextFormField(
                  initialValue: rate,
                  enabled: !isNoTax,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Tax rate %'),
                  onChanged: (v) => rate = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Price is tax inclusive'),
                  subtitle: const Text(
                      'Tax is extracted from the entered price instead of added on top.'),
                  value: inclusive,
                  onChanged:
                      isNoTax ? null : (v) => setDialog(() => inclusive = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default profile'),
                  value: makeDefault,
                  onChanged: (v) => setDialog(() => makeDefault = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.saveTaxProfile(
        code: isNoTax ? 'NONE' : code,
        name: isNoTax ? 'No Tax / Exempt' : name,
        rate: isNoTax ? 0 : (double.tryParse(rate) ?? 0),
        inclusive: isNoTax ? false : inclusive,
        makeDefault: makeDefault,
      );
      if (mounted) setState(() => refresh++);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Tax Profiles',
                            style: TextStyle(
                                fontSize: 21, fontWeight: FontWeight.w800)),
                        Text(
                            'Create reusable tax rates for sales, purchases and expenses.',
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Tax')),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close)),
                ]),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<List<Map<String, Object?>>>(
                    key: ValueKey(refresh),
                    future: AppDatabase.instance.taxProfiles(activeOnly: false),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData)
                        return const Center(child: CircularProgressIndicator());
                      final rows = snapshot.data!;
                      return ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          final active =
                              ((r['active'] as num?) ?? 0).toInt() == 1;
                          final isDefault =
                              ((r['is_default'] as num?) ?? 0).toInt() == 1;
                          final inclusive =
                              ((r['price_inclusive'] as num?) ?? 0).toInt() ==
                                  1;
                          final code = r['code'].toString();
                          final rate = ((r['rate'] as num?) ?? 0).toDouble();
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                                child: Text(
                                    '${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 1)}%')),
                            title: Text('${r['name']} • $code',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                                '${rate.toStringAsFixed(3)}% • ${inclusive ? 'Inclusive' : 'Exclusive'}${isDefault ? ' • Default' : ''}'),
                            onTap: () => _edit(existing: r),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                    tooltip: 'Edit',
                                    onPressed: () => _edit(existing: r),
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 19)),
                                Switch(
                                  value: active,
                                  onChanged: code == 'NONE'
                                      ? null
                                      : (v) async {
                                          await AppDatabase.instance
                                              .setTaxProfileActive(code, v);
                                          if (mounted)
                                            setState(() => refresh++);
                                        },
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
