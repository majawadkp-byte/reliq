import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/app_database.dart';

enum ReliqPrintAction { none, preview, direct }

class ReliqPrinterOption {
  final String name;
  const ReliqPrinterOption(this.name);
}

class PrintService {
  static Future<Map<String, String>> _business() async => AppDatabase.instance.settings();

  // Font discovery and file reads are surprisingly expensive on desktop. Cache
  // the resolved PDF theme for the process so repeated invoice/receipt previews
  // do not reread the same multi-megabyte system font files every time.
  static Future<pw.ThemeData?>? _pdfThemeFuture;
  static String? _logoCachePath;
  static int? _logoCacheModifiedMs;
  static pw.ImageProvider? _logoCacheImage;

  static String _safeName(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  static bool _yes(Map<String, String> s, String key, {bool fallback = true}) {
    final v = s[key];
    if (v == null || v.isEmpty) return fallback;
    return v == '1' || v.toLowerCase() == 'true' || v.toLowerCase() == 'yes';
  }

  static int _decimals(Map<String, String> s) {
    final value = int.tryParse(s['currency_decimals'] ?? '3') ?? 3;
    return value.clamp(0, 4);
  }

  static String _money(Map<String, String> s, num value) {
    final currency = (s['currency'] ?? 'KWD').trim();
    return '$currency ${value.toDouble().toStringAsFixed(_decimals(s))}';
  }

  static ReliqPrintAction actionFromSetting(String? value) {
    switch ((value ?? '').trim().toLowerCase()) {
      case 'print directly':
      case 'direct':
      case 'print':
        return ReliqPrintAction.direct;
      case 'preview':
      case 'view / preview':
        return ReliqPrintAction.preview;
      default:
        return ReliqPrintAction.none;
    }
  }

  static Future<List<ReliqPrinterOption>> availablePrinters() async {
    try {
      final printers = await Printing.listPrinters();
      return printers.map((p) => ReliqPrinterOption(p.name)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _openSystemPreview(Uint8List bytes, String fileName) async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
      return;
    }
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, 'reliq_solutions_prints'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, _safeName(fileName.endsWith('.pdf') ? fileName : '$fileName.pdf')));
    await file.writeAsBytes(bytes, flush: true);
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', ['-a', 'Preview', file.path]);
    } else if (Platform.isWindows) {
      result = await Process.run('cmd', ['/c', 'start', '', file.path], runInShell: true);
    } else {
      result = await Process.run('xdg-open', [file.path]);
    }
    if (result.exitCode != 0) {
      throw Exception('Could not open the document preview. ${result.stderr}'.trim());
    }
  }

  static Future<void> _directPrint(Uint8List bytes, String fileName, String printerName) async {
    final printers = await Printing.listPrinters();
    if (printers.isEmpty) throw Exception('No printers are available on this computer.');
    final wanted = printerName.trim().toLowerCase();
    final printer = wanted.isEmpty
        ? printers.firstWhere((p) => p.isDefault, orElse: () => printers.first)
        : printers.firstWhere(
            (p) => p.name.trim().toLowerCase() == wanted,
            orElse: () => throw Exception('Configured printer "$printerName" is not currently available.'),
          );
    final ok = await Printing.directPrintPdf(
      printer: printer,
      name: fileName,
      onLayout: (_) async => bytes,
    );
    if (!ok) throw Exception('The printer did not accept the document.');
  }

  static Future<void> _outputPdf(
    Uint8List bytes,
    String fileName, {
    ReliqPrintAction action = ReliqPrintAction.preview,
    String printerName = '',
  }) async {
    switch (action) {
      case ReliqPrintAction.none:
        return;
      case ReliqPrintAction.preview:
        await _openSystemPreview(bytes, fileName);
        return;
      case ReliqPrintAction.direct:
        await _directPrint(bytes, fileName, printerName);
        return;
    }
  }


  /// Builds a PDF document with a Unicode-capable system font when one is
  /// available. No font file is bundled with V4; the installed OS font is
  /// loaded at runtime. This removes the Helvetica Unicode warnings for
  /// multilingual customer/product/company text on supported systems.
  static Future<pw.ThemeData?> _loadPdfTheme() async {
    final candidates = <List<String>>[
      if (Platform.isMacOS) ...[
        ['/System/Library/Fonts/Supplemental/Arial Unicode.ttf', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'],
        ['/Library/Fonts/Arial Unicode.ttf', '/Library/Fonts/Arial Unicode.ttf'],
        ['/System/Library/Fonts/Supplemental/Arial.ttf', '/System/Library/Fonts/Supplemental/Arial Bold.ttf'],
      ],
      if (Platform.isWindows) ...[
        [r'C:\Windows\Fonts\arial.ttf', r'C:\Windows\Fonts\arialbd.ttf'],
        [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf'],
      ],
      if (Platform.isLinux) ...[
        ['/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf', '/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf'],
        ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'],
      ],
    ];
    for (final pair in candidates) {
      final regular = File(pair[0]);
      if (!await regular.exists()) continue;
      try {
        final boldFile = File(pair[1]);
        final base = pw.Font.ttf(ByteData.sublistView(await regular.readAsBytes()));
        final bold = await boldFile.exists()
            ? pw.Font.ttf(ByteData.sublistView(await boldFile.readAsBytes()))
            : base;
        return pw.ThemeData.withFont(base: base, bold: bold);
      } catch (_) {
        // Try the next installed font. Helvetica remains the final fallback.
      }
    }
    return null;
  }

  static Future<pw.Document> _newDocument() async {
    final theme = await (_pdfThemeFuture ??= _loadPdfTheme());
    return theme == null ? pw.Document() : pw.Document(theme: theme);
  }

  static Future<pw.ImageProvider?> _logo(Map<String, String> s) async {
    if (!_yes(s, 'document_show_logo')) return null;
    final path = (s['logo_path'] ?? '').trim();
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final modifiedMs = (await file.lastModified()).millisecondsSinceEpoch;
      if (_logoCachePath == path && _logoCacheModifiedMs == modifiedMs && _logoCacheImage != null) {
        return _logoCacheImage;
      }
      final image = pw.MemoryImage(await file.readAsBytes());
      _logoCachePath = path;
      _logoCacheModifiedMs = modifiedMs;
      _logoCacheImage = image;
      return image;
    } catch (_) {
      return null;
    }
  }

  static PdfPageFormat _salePageFormat(Map<String, String> s, int itemCount) {
    final format = s['document_format'] ?? 'Thermal 80mm';
    if (format == 'A4') return PdfPageFormat.a4;
    final widthMm = format == 'Thermal 58mm' ? 58.0 : 80.0;
    final marginMm = format == 'Thermal 58mm' ? 3.5 : 5.0;
    final heightMm = (105 + itemCount * 16).clamp(170, 900).toDouble();
    return PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm, marginAll: marginMm * PdfPageFormat.mm);
  }

  static pw.Alignment _logoAlignment(Map<String, String> s) {
    switch (s['logo_position']) {
      case 'Left':
        return pw.Alignment.centerLeft;
      case 'Right':
        return pw.Alignment.centerRight;
      default:
        return pw.Alignment.center;
    }
  }

  static Future<Uint8List> _barcodePdf(Map<String, Object?> product) async {
    final settings = await _business();
    final name = (product['name'] ?? 'Product').toString();
    final sku = (product['sku'] ?? '').toString();
    final barcode = (product['external_barcode'] ?? product['internal_barcode'] ?? '').toString().trim();
    if (barcode.isEmpty) throw Exception('This product has no barcode.');

    final widthMm = (double.tryParse(settings['barcode_label_width_mm'] ?? '') ?? 55).clamp(30, 100).toDouble();
    final heightMm = (double.tryParse(settings['barcode_label_height_mm'] ?? '') ?? 32).clamp(20, 80).toDouble();
    final showSku = _yes(settings, 'barcode_show_sku');
    final showPrice = _yes(settings, 'barcode_show_price', fallback: false);
    final doc = await _newDocument();
    final isEan13 = RegExp(r'^\d{13}$').hasMatch(barcode);
    final format = PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm, marginAll: 3 * PdfPageFormat.mm);
    doc.addPage(
      pw.Page(
        pageFormat: format,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if ((settings['business_name'] ?? '').trim().isNotEmpty)
              pw.Text(settings['business_name']!, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text(name, maxLines: 2, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
            pw.Spacer(),
            pw.BarcodeWidget(
              barcode: isEan13 ? pw.Barcode.ean13() : pw.Barcode.code128(),
              data: barcode,
              width: (widthMm - 10) * PdfPageFormat.mm,
              height: (heightMm * .35).clamp(8, 18) * PdfPageFormat.mm,
              drawText: true,
            ),
            if (showSku && sku.isNotEmpty) pw.Text(sku, style: const pw.TextStyle(fontSize: 6)),
            if (showPrice) pw.Text(_money(settings, (product['price'] as num? ?? 0)), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
          ],
        ),
      ),
    );
    return doc.save();
  }

  static Future<void> printBarcodeLabel(Map<String, Object?> product) async {
    final sku = (product['sku'] ?? 'product').toString();
    final bytes = await _barcodePdf(product);
    await _outputPdf(bytes, 'Barcode_$sku.pdf');
  }

  static Future<Uint8List> _saleReceiptPdf({
    required String saleNo,
    required List<Map<String, Object?>> items,
    required double subtotal,
    required double itemDiscount,
    required double discount,
    required double tax,
    required double delivery,
    required double other,
    required double total,
    required double paid,
    required double balance,
    required String paymentMethod,
    required String customerName,
    DateTime? createdAt,
    String cashier = '',
  }) async {
    final settings = await _business();
    final businessName = (settings['business_name'] ?? 'RELIQ Solutions').trim();
    final legalName = (settings['legal_name'] ?? '').trim();
    final phone = (settings['business_phone'] ?? '').trim();
    final email = (settings['business_email'] ?? '').trim();
    final address = (settings['business_address'] ?? '').trim();
    final taxNo = (settings['tax_number'] ?? '').trim();
    final customFields = <Map<String,dynamic>>[];
    try { customFields.addAll((jsonDecode(settings['document_custom_fields'] ?? '[]') as List).map((e)=>Map<String,dynamic>.from(e as Map))); } catch (_) {}
    final title = (settings['invoice_title'] ?? 'SALES INVOICE').trim();
    final footer = (settings['invoice_footer'] ?? '').trim();
    final thankYou = (settings['receipt_thank_you'] ?? 'Thank you').trim();
    final logo = await _logo(settings);
    final pageFormat = _salePageFormat(settings, items.length);
    final isA4 = (settings['document_format'] ?? '') == 'A4';
    final showSku = _yes(settings, 'document_show_sku');
    final showBarcode = _yes(settings, 'document_show_barcode', fallback: false);
    final showTax = _yes(settings, 'document_show_tax');
    final showDiscount = _yes(settings, 'document_show_discount');
    final showPayment = _yes(settings, 'document_show_payment');
    final showCustomer = _yes(settings, 'document_show_customer');
    final showCashier = _yes(settings, 'document_show_cashier', fallback: false);
    final date = createdAt ?? DateTime.now();

    final doc = await _newDocument();
    final content = <pw.Widget>[
      if (logo != null)
        pw.Align(
          alignment: _logoAlignment(settings),
          child: pw.Image(logo, width: isA4 ? 90 : 55, height: isA4 ? 55 : 34, fit: pw.BoxFit.contain),
        ),
      pw.Text(businessName.isEmpty ? 'RELIQ Solutions' : businessName, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 18 : 13, fontWeight: pw.FontWeight.bold)),
      if (legalName.isNotEmpty && legalName != businessName) pw.Text(legalName, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      if (address.isNotEmpty) pw.Text(address, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      if (phone.isNotEmpty || email.isNotEmpty)
        pw.Text([phone, email].where((x) => x.isNotEmpty).join(' • '), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      if (taxNo.isNotEmpty) pw.Text('Tax / Reg: $taxNo', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      for (final f in customFields.where((f)=>f['invoice'] != false && (f['label']??'').toString().trim().isNotEmpty && (f['value']??'').toString().trim().isNotEmpty))
        pw.Text('${f['label']}: ${f['value']}', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      pw.SizedBox(height: isA4 ? 14 : 6),
      pw.Divider(),
      pw.Text(title.isEmpty ? 'SALES INVOICE' : title, style: pw.TextStyle(fontSize: isA4 ? 14 : 9, fontWeight: pw.FontWeight.bold)),
      pw.Text('Invoice: $saleNo', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      pw.Text('Date: ${date.toLocal().toString().substring(0, 19)}', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      if (showCustomer) pw.Text('Customer: $customerName', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      if (showPayment) pw.Text('Payment: $paymentMethod', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      if (showCashier && cashier.isNotEmpty) pw.Text('Cashier: $cashier', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      pw.SizedBox(height: 4),
      pw.Divider(),
      if (isA4) _a4SaleTable(settings, items, showSku: showSku, showTax: showTax, showDiscount: showDiscount) else ..._thermalSaleLines(settings, items, showSku: showSku, showBarcode: showBarcode, showTax: showTax, showDiscount: showDiscount),
      pw.Divider(),
      _moneyRow(settings, 'Subtotal', subtotal),
      if (showDiscount && itemDiscount != 0) _moneyRow(settings, 'Item discounts', -itemDiscount),
      if (showDiscount && discount != 0) _moneyRow(settings, 'Bill discount', -discount),
      if (showTax && tax != 0) _moneyRow(settings, 'Tax', tax),
      if (delivery != 0) _moneyRow(settings, 'Delivery', delivery),
      if (other != 0) _moneyRow(settings, 'Other charges', other),
      pw.SizedBox(height: 3),
      _moneyRow(settings, 'TOTAL', total, strong: true),
      if (showPayment) ...[
        _moneyRow(settings, 'Paid', paid),
        _moneyRow(settings, 'Balance', balance),
      ],
      pw.SizedBox(height: isA4 ? 16 : 8),
      if (footer.isNotEmpty) pw.Text(footer, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
      if (thankYou.isNotEmpty) pw.Text(thankYou, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 10 : 8, fontWeight: pw.FontWeight.bold)),
    ];

    doc.addPage(pw.Page(pageFormat: pageFormat, build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: content)));
    return doc.save();
  }

  static pw.Widget _a4SaleTable(Map<String, String> settings, List<Map<String, Object?>> items, {required bool showSku, required bool showTax, required bool showDiscount}) {
    final headers = <String>['Item', if (showSku) 'SKU', 'Qty', 'Price', if (showDiscount) 'Discount', if (showTax) 'Tax', 'Total'];
    pw.Widget cell(String text, {bool head = false, pw.TextAlign align = pw.TextAlign.left}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text(text, textAlign: align, style: pw.TextStyle(fontSize: head ? 8 : 8, fontWeight: head ? pw.FontWeight.bold : pw.FontWeight.normal)),
    );
    final rows = <pw.TableRow>[
      pw.TableRow(decoration: pw.BoxDecoration(color: PdfColors.grey200), children: headers.map((h) => cell(h, head: true)).toList()),
      for (final item in items)
        pw.TableRow(children: [
          cell((item['name'] ?? '').toString()),
          if (showSku) cell((item['sku'] ?? '').toString()),
          cell((item['qty'] as num? ?? 0).toStringAsFixed(2), align: pw.TextAlign.right),
          cell(_money(settings, item['price'] as num? ?? item['unit_price'] as num? ?? 0), align: pw.TextAlign.right),
          if (showDiscount) cell(_money(settings, item['line_discount'] as num? ?? item['discount'] as num? ?? 0), align: pw.TextAlign.right),
          if (showTax) cell(_money(settings, item['tax_amount'] as num? ?? item['tax'] as num? ?? 0), align: pw.TextAlign.right),
          cell(_money(settings, item['line_total'] as num? ?? 0), align: pw.TextAlign.right),
        ]),
    ];
    return pw.Table(border: pw.TableBorder.all(color: PdfColors.grey300, width: .5), children: rows);
  }

  static List<pw.Widget> _thermalSaleLines(Map<String, String> settings, List<Map<String, Object?>> items, {required bool showSku, required bool showBarcode, required bool showTax, required bool showDiscount}) {
    final out = <pw.Widget>[];
    for (final item in items) {
      final qty = (item['qty'] as num? ?? 0).toDouble();
      final price = (item['price'] as num? ?? item['unit_price'] as num? ?? 0).toDouble();
      out.add(pw.Row(children: [
        pw.Expanded(child: pw.Text((item['name'] ?? '').toString(), style: const pw.TextStyle(fontSize: 7))),
        pw.Text('${qty.toStringAsFixed(2)} × ${price.toStringAsFixed(_decimals(settings))}', style: const pw.TextStyle(fontSize: 7)),
      ]));
      if (showSku && (item['sku'] ?? '').toString().isNotEmpty) out.add(pw.Text('SKU: ${item['sku']}', style: const pw.TextStyle(fontSize: 6)));
      if (showBarcode) {
        final barcode = (item['external_barcode'] ?? item['internal_barcode'] ?? '').toString();
        if (barcode.isNotEmpty) out.add(pw.Text('Barcode: $barcode', style: const pw.TextStyle(fontSize: 6)));
      }
      final lineDiscount = (item['line_discount'] as num? ?? item['discount'] as num? ?? 0).toDouble();
      final lineTax = (item['tax_amount'] as num? ?? item['tax'] as num? ?? 0).toDouble();
      if (showDiscount && lineDiscount > 0) out.add(pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Discount -${_money(settings, lineDiscount)}', style: const pw.TextStyle(fontSize: 6))));
      if (showTax && lineTax > 0) out.add(pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Tax ${_money(settings, lineTax)}', style: const pw.TextStyle(fontSize: 6))));
      out.add(pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text(_money(settings, item['line_total'] as num? ?? qty * price), style: const pw.TextStyle(fontSize: 7))));
      out.add(pw.SizedBox(height: 2));
    }
    return out;
  }

  static Future<void> printSaleReceipt({
    required String saleNo,
    required List<Map<String, Object?>> items,
    required double subtotal,
    required double itemDiscount,
    required double discount,
    required double tax,
    required double delivery,
    required double other,
    required double total,
    required double paid,
    required double balance,
    required String paymentMethod,
    required String customerName,
    DateTime? createdAt,
    String cashier = '',
    ReliqPrintAction action = ReliqPrintAction.preview,
    String printerName = '',
  }) async {
    final bytes = await _saleReceiptPdf(
      saleNo: saleNo,
      items: items,
      subtotal: subtotal,
      itemDiscount: itemDiscount,
      discount: discount,
      tax: tax,
      delivery: delivery,
      other: other,
      total: total,
      paid: paid,
      balance: balance,
      paymentMethod: paymentMethod,
      customerName: customerName,
      createdAt: createdAt,
      cashier: cashier,
    );
    await _outputPdf(bytes, 'Sale_$saleNo.pdf', action: action, printerName: printerName);
  }

  static Future<void> printSaleFromData(Map<String, Object?> data) async {
    final h = Map<String, Object?>.from(data['header'] as Map);
    final raw = (data['lines'] as List).map((e) => Map<String, Object?>.from(e as Map)).toList();
    final items = raw.map((x) => <String, Object?>{
      ...x,
      'price': x['unit_price'],
      'line_discount': x['discount'],
      'tax_amount': x['tax'],
    }).toList();
    final itemDiscount = items.fold<double>(0, (s, x) => s + (x['line_discount'] as num? ?? 0).toDouble());
    await printSaleReceipt(
      saleNo: (h['no'] ?? '').toString(),
      items: items,
      subtotal: (h['subtotal'] as num? ?? 0).toDouble(),
      itemDiscount: itemDiscount,
      discount: (h['discount'] as num? ?? 0).toDouble(),
      tax: (h['tax'] as num? ?? 0).toDouble(),
      delivery: (h['delivery_charge'] as num? ?? 0).toDouble(),
      other: (h['other_charge'] as num? ?? 0).toDouble(),
      total: (h['total'] as num? ?? 0).toDouble(),
      paid: (h['paid'] as num? ?? 0).toDouble(),
      balance: (h['balance'] as num? ?? 0).toDouble(),
      paymentMethod: (h['payment_method'] ?? '').toString(),
      customerName: (h['customer_name'] ?? 'Walk-in customer').toString(),
      createdAt: DateTime.tryParse((h['created_at'] ?? '').toString()),
      cashier: (h['edited_by'] ?? h['user_id'] ?? '').toString(),
    );
  }

  static Future<void> printPurchaseFromData(Map<String, Object?> data, {ReliqPrintAction action = ReliqPrintAction.preview, String printerName = ''}) async {
    final settings = await _business();
    final h = Map<String, Object?>.from(data['header'] as Map);
    final items = (data['lines'] as List).map((e) => Map<String, Object?>.from(e as Map)).toList();
    final logo = await _logo(settings);
    final isA4 = (settings['purchase_document_format'] ?? settings['document_format'] ?? 'A4') == 'A4';
    final pageFormat = isA4 ? PdfPageFormat.a4 : _salePageFormat(settings, items.length);
    final title = (settings['purchase_title'] ?? 'PURCHASE RECEIPT').trim();
    final footer = (settings['purchase_footer'] ?? '').trim();
    final doc = await _newDocument();
    final businessName = (settings['business_name'] ?? 'RELIQ Solutions').trim();
    final showTax = _yes(settings, 'purchase_show_tax');
    final showDiscount = _yes(settings, 'purchase_show_discount');

    final body = <pw.Widget>[
      if (logo != null) pw.Align(alignment: _logoAlignment(settings), child: pw.Image(logo, width: isA4 ? 90 : 55, height: isA4 ? 55 : 34, fit: pw.BoxFit.contain)),
      pw.Text(businessName, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 18 : 13, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 10),
      pw.Divider(),
      pw.Text(title, style: pw.TextStyle(fontSize: isA4 ? 14 : 9, fontWeight: pw.FontWeight.bold)),
      pw.Text('Purchase: ${h['no'] ?? ''}', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      pw.Text('Supplier: ${h['supplier_name'] ?? 'Supplier'}', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      if ((h['document_no'] ?? '').toString().isNotEmpty) pw.Text('Supplier document: ${h['document_no']}', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      pw.Text('Date: ${(h['created_at'] ?? '').toString().replaceFirst('T', ' ')}', style: pw.TextStyle(fontSize: isA4 ? 10 : 7)),
      pw.Divider(),
      for (final item in items) ...[
        pw.Row(children: [
          pw.Expanded(child: pw.Text((item['name'] ?? '').toString(), style: pw.TextStyle(fontSize: isA4 ? 9 : 7))),
          pw.Text('${(item['qty'] as num? ?? 0).toStringAsFixed(2)} × ${_money(settings, item['unit_cost'] as num? ?? 0)}', style: pw.TextStyle(fontSize: isA4 ? 9 : 7)),
        ]),
        if (showDiscount && (item['discount'] as num? ?? 0).toDouble() > 0) pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Discount -${_money(settings, item['discount'] as num)}', style: pw.TextStyle(fontSize: isA4 ? 8 : 6))),
        if (showTax && (item['tax'] as num? ?? 0).toDouble() > 0) pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Tax ${_money(settings, item['tax'] as num)}', style: pw.TextStyle(fontSize: isA4 ? 8 : 6))),
        pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text(_money(settings, item['line_total'] as num? ?? 0), style: pw.TextStyle(fontSize: isA4 ? 9 : 7))),
        pw.SizedBox(height: 2),
      ],
      pw.Divider(),
      _moneyRow(settings, 'Subtotal', (h['subtotal'] as num? ?? 0).toDouble()),
      if (showDiscount && (h['discount'] as num? ?? 0).toDouble() != 0) _moneyRow(settings, 'Discount', -(h['discount'] as num).toDouble()),
      if (showTax && (h['tax'] as num? ?? 0).toDouble() != 0) _moneyRow(settings, 'Tax', (h['tax'] as num).toDouble()),
      if ((h['freight'] as num? ?? 0).toDouble() != 0) _moneyRow(settings, 'Freight', (h['freight'] as num).toDouble()),
      if ((h['other_charges'] as num? ?? 0).toDouble() != 0) _moneyRow(settings, 'Other charges', (h['other_charges'] as num).toDouble()),
      _moneyRow(settings, 'TOTAL', (h['total'] as num? ?? 0).toDouble(), strong: true),
      _moneyRow(settings, 'Paid', (h['paid'] as num? ?? 0).toDouble()),
      _moneyRow(settings, 'Balance', (h['balance'] as num? ?? 0).toDouble()),
      if (footer.isNotEmpty) ...[pw.SizedBox(height: 12), pw.Text(footer, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: isA4 ? 9 : 7))],
    ];
    doc.addPage(pw.Page(pageFormat: pageFormat, build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: body)));
    await _outputPdf(await doc.save(), 'Purchase_${h['no'] ?? 'document'}.pdf', action: action, printerName: printerName);
  }


  static Future<void> printPaymentReceipt({
    required String paymentId,
    required String partyType,
    required String partyName,
    required double amount,
    required String method,
    String reference = '',
    String? createdAt,
    required List<Map<String, Object?>> allocations,
    double accountCredit = 0,
    ReliqPrintAction action = ReliqPrintAction.preview,
    String printerName = '',
  }) async {
    final settings = await _business();
    final logo = await _logo(settings);
    final doc = await _newDocument();
    final businessName = (settings['business_name'] ?? 'RELIQ Solutions').trim();
    final isCustomer = partyType.toLowerCase() == 'customer';
    final title = isCustomer ? 'PAYMENT RECEIPT' : 'SUPPLIER PAYMENT VOUCHER';
    final totalAllocated = allocations.fold<double>(0, (a, x) => a + ((x['amount'] as num?) ?? 0).toDouble());
    final body = <pw.Widget>[
      if (logo != null) pw.Align(alignment: _logoAlignment(settings), child: pw.Image(logo, width: 80, height: 48, fit: pw.BoxFit.contain)),
      pw.Text(businessName, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 10),
      pw.Divider(),
      pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Text('Reference: $paymentId', style: const pw.TextStyle(fontSize: 9)),
      pw.Text('Date: ${(DateTime.tryParse(createdAt ?? '') ?? DateTime.now()).toLocal().toString().substring(0, 19)}', style: const pw.TextStyle(fontSize: 9)),
      pw.Text('${isCustomer ? 'Received from' : 'Paid to'}: $partyName', style: const pw.TextStyle(fontSize: 9)),
      pw.Text('Method: $method${reference.trim().isEmpty ? '' : ' • $reference'}', style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 10),
      _moneyRow(settings, isCustomer ? 'Amount received' : 'Amount paid', amount, strong: true),
      _moneyRow(settings, 'Allocated', totalAllocated),
      if (accountCredit > 0) _moneyRow(settings, isCustomer ? 'Account credit' : 'Supplier advance', accountCredit),
      if (allocations.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('ALLOCATIONS', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Divider(),
        for (final row in allocations)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text((row['document_no'] ?? row['document_id'] ?? 'Document').toString(), style: const pw.TextStyle(fontSize: 8))),
              pw.Text(_money(settings, (row['amount'] as num? ?? 0)), style: const pw.TextStyle(fontSize: 8)),
            ]),
          ),
      ],
      pw.SizedBox(height: 18),
      pw.Text(isCustomer ? 'Payment received with thanks.' : 'Supplier payment recorded.', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9)),
    ];
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: body)));
    await _outputPdf(await doc.save(), '${isCustomer ? 'Receipt' : 'Supplier_Payment'}_$paymentId.pdf', action: action, printerName: printerName);
  }

  static Future<void> handleConfiguredSalePrint({
    required String saleNo,
    required List<Map<String, Object?>> items,
    required double subtotal,
    required double itemDiscount,
    required double discount,
    required double tax,
    required double delivery,
    required double other,
    required double total,
    required double paid,
    required double balance,
    required String paymentMethod,
    required String customerName,
  }) async {
    final s = await _business();
    final action = actionFromSetting(s['sales_print_action']);
    if (action == ReliqPrintAction.none) return;
    await printSaleReceipt(
      saleNo: saleNo, items: items, subtotal: subtotal, itemDiscount: itemDiscount,
      discount: discount, tax: tax, delivery: delivery, other: other, total: total,
      paid: paid, balance: balance, paymentMethod: paymentMethod, customerName: customerName,
      action: action, printerName: s['sales_printer'] ?? '',
    );
  }

  static Future<void> handleConfiguredPaymentPrint({
    required bool customer,
    required String paymentId,
    required String partyName,
    required double amount,
    required String method,
    required String reference,
    required List<Map<String, Object?>> allocations,
    required double accountCredit,
  }) async {
    final s = await _business();
    final key = customer ? 'customer_receipt_print_action' : 'supplier_payment_print_action';
    final printerKey = customer ? 'customer_receipt_printer' : 'supplier_payment_printer';
    final action = actionFromSetting(s[key]);
    if (action == ReliqPrintAction.none) return;
    await printPaymentReceipt(
      paymentId: paymentId, partyType: customer ? 'Customer' : 'Supplier', partyName: partyName,
      amount: amount, method: method, reference: reference, allocations: allocations,
      accountCredit: accountCredit, action: action, printerName: s[printerKey] ?? '',
    );
  }

  static Future<void> printTestDocument() async {
    await printSaleReceipt(
      saleNo: 'SAMPLE-001',
      items: [
        {'name': 'Sample Product', 'sku': 'SKU-001', 'external_barcode': '1234567890128', 'qty': 2.0, 'price': 1.250, 'line_discount': 0.100, 'tax_amount': 0.120, 'line_total': 2.520},
        {'name': 'Another Item', 'sku': 'SKU-002', 'qty': 1.0, 'price': 3.500, 'line_discount': 0.0, 'tax_amount': 0.175, 'line_total': 3.675},
      ],
      subtotal: 6.000,
      itemDiscount: 0.100,
      discount: 0,
      tax: 0.295,
      delivery: 0.500,
      other: 0,
      total: 6.695,
      paid: 6.695,
      balance: 0,
      paymentMethod: 'Cash',
      customerName: 'Sample Customer',
      cashier: 'Owner',
    );
  }

  static pw.Widget _moneyRow(Map<String, String> settings, String label, double value, {bool strong = false}) {
    final style = pw.TextStyle(fontSize: strong ? 10 : 7, fontWeight: strong ? pw.FontWeight.bold : pw.FontWeight.normal);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(children: [
        pw.Expanded(child: pw.Text(label, style: style)),
        pw.Text(_money(settings, value), style: style),
      ]),
    );
  }

  static Future<void> printCustomerStatement({required Map<String,Object?> customer, required List<Map<String,Object?>> rows, ReliqPrintAction action=ReliqPrintAction.preview}) async {
    final settings=await _business(); final doc=await _newDocument(); final logo=await _logo(settings);
    final body=<pw.Widget>[
      if(logo!=null) pw.Align(alignment:_logoAlignment(settings),child:pw.Image(logo,width:80,height:48,fit:pw.BoxFit.contain)),
      pw.Text(settings['business_name']??'RELIQ Solutions',textAlign:pw.TextAlign.center,style:pw.TextStyle(fontSize:17,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:8),
      pw.Text('CUSTOMER STATEMENT',style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold)),pw.Text('Customer: ${customer['name']??''}'),pw.Text('Generated: ${DateTime.now().toLocal().toString().substring(0,16)}'),pw.SizedBox(height:8),
      pw.Table.fromTextArray(headers:['Date','Type','Reference','Debit','Credit'],data:[for(final r in rows)[(r['date']??'').toString().split('T').first,r['type']??'',r['reference']??'',_money(settings,(r['debit'] as num?)??0),_money(settings,(r['credit'] as num?)??0)]],headerStyle:pw.TextStyle(fontWeight:pw.FontWeight.bold,fontSize:8),cellStyle:const pw.TextStyle(fontSize:8)),
      pw.SizedBox(height:10),_moneyRow(settings,'Outstanding balance',((customer['balance'] as num?)??0).toDouble(),strong:true),
    ]; doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>body)); await _outputPdf(await doc.save(),'Statement_${_safeName('${customer['name']??'Customer'}')}.pdf',action:action);
  }

  static Future<void> printSupplierStatement({required Map<String,Object?> supplier, required List<Map<String,Object?>> rows, ReliqPrintAction action=ReliqPrintAction.preview}) async {
    final settings=await _business(); final doc=await _newDocument(); final logo=await _logo(settings);
    final body=<pw.Widget>[
      if(logo!=null) pw.Align(alignment:_logoAlignment(settings),child:pw.Image(logo,width:80,height:48,fit:pw.BoxFit.contain)),
      pw.Text(settings['business_name']??'RELIQ Solutions',textAlign:pw.TextAlign.center,style:pw.TextStyle(fontSize:17,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:8),
      pw.Text('SUPPLIER STATEMENT',style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold)),pw.Text('Supplier: ${supplier['name']??''}'),pw.Text('Generated: ${DateTime.now().toLocal().toString().substring(0,16)}'),pw.SizedBox(height:8),
      pw.Table.fromTextArray(headers:['Date','Type','Reference','Charge','Payment / Credit'],data:[for(final r in rows)[(r['date']??'').toString().split('T').first,r['type']??'',r['reference']??'',_money(settings,(r['debit'] as num?)??0),_money(settings,(r['credit'] as num?)??0)]],headerStyle:pw.TextStyle(fontWeight:pw.FontWeight.bold,fontSize:8),cellStyle:const pw.TextStyle(fontSize:8)),
      pw.SizedBox(height:10),_moneyRow(settings,'Payable balance',((supplier['balance'] as num?)??0).toDouble(),strong:true),
    ]; doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>body)); await _outputPdf(await doc.save(),'Supplier_Statement_${_safeName('${supplier['name']??'Supplier'}')}.pdf',action:action);
  }

  static Future<void> printPurchaseOrder({required Map<String,Object?> order, required List<Map<String,Object?>> items, ReliqPrintAction action=ReliqPrintAction.preview}) async {
    final settings=await _business(); final doc=await _newDocument(); final logo=await _logo(settings);
    final body=<pw.Widget>[
      if(logo!=null) pw.Align(alignment:_logoAlignment(settings),child:pw.Image(logo,width:80,height:48,fit:pw.BoxFit.contain)),
      pw.Text(settings['business_name']??'RELIQ Solutions',textAlign:pw.TextAlign.center,style:pw.TextStyle(fontSize:17,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:8),
      pw.Text('PURCHASE ORDER',style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold)),pw.Text('PO: ${order['no']??''}'),pw.Text('Supplier: ${order['supplier_name']??''}'),pw.Text('Date: ${(order['created_at']??'').toString().split('T').first}'),pw.SizedBox(height:8),
      pw.Table.fromTextArray(headers:['SKU','Product','Qty','Unit cost','Total'],data:[for(final r in items)[r['sku']??'',r['name']??'',((r['ordered_qty'] as num?)??0).toStringAsFixed(2),_money(settings,(r['unit_cost'] as num?)??0),_money(settings,((r['ordered_qty'] as num?)??0)*((r['unit_cost'] as num?)??0))]],headerStyle:pw.TextStyle(fontWeight:pw.FontWeight.bold,fontSize:8),cellStyle:const pw.TextStyle(fontSize:8)),
      pw.SizedBox(height:10),_moneyRow(settings,'ORDER TOTAL',((order['ordered_total'] as num?)??0).toDouble(),strong:true),if((order['notes']??'').toString().trim().isNotEmpty) pw.Text('Notes: ${order['notes']}'),
    ]; doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>body)); await _outputPdf(await doc.save(),'PO_${_safeName('${order['no']??'order'}')}.pdf',action:action);
  }


  static Future<void> printQuotation({required Map<String,Object?> quotation, required List<Map<String,Object?>> items, ReliqPrintAction action=ReliqPrintAction.preview}) async {
    final settings=await _business(); final doc=await _newDocument(); final logo=await _logo(settings);
    final body=<pw.Widget>[if(logo!=null) pw.Align(alignment:_logoAlignment(settings),child:pw.Image(logo,width:80,height:48,fit:pw.BoxFit.contain)),pw.Text(settings['business_name']??'RELIQ Solutions',style:pw.TextStyle(fontSize:17,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:8),pw.Text('QUOTATION',style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold)),pw.Text('Quotation: ${quotation['no']??''}'),pw.Text('Customer: ${quotation['customer_name']??''}'),pw.Text('Valid until: ${(quotation['valid_until']??'').toString().split('T').first}'),pw.SizedBox(height:8),pw.Table.fromTextArray(headers:['SKU','Product','Qty','Price','Total'],data:[for(final r in items)[r['sku']??'',r['name']??'',((r['qty'] as num?)??0).toStringAsFixed(2),_money(settings,(r['unit_price'] as num?)??0),_money(settings,(r['line_total'] as num?)??0)]],headerStyle:pw.TextStyle(fontWeight:pw.FontWeight.bold,fontSize:8),cellStyle:const pw.TextStyle(fontSize:8)),pw.SizedBox(height:10),_moneyRow(settings,'TOTAL',((quotation['total'] as num?)??0).toDouble(),strong:true),if((quotation['notes']??'').toString().trim().isNotEmpty) pw.Text('Notes: ${quotation['notes']}')];
    doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>body)); await _outputPdf(await doc.save(),'Quotation_${_safeName('${quotation['no']??'quote'}')}.pdf',action:action);
  }

}
