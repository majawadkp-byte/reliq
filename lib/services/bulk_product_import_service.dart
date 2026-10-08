import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';
import 'license_manager.dart';

class BulkProductRow {
  final int rowNumber;
  final Map<String, Object?> values;
  final String? error;

  const BulkProductRow(this.rowNumber, this.values, this.error);

  bool get valid => error == null;
}

class BulkPickedFile {
  final String name;
  final Uint8List bytes;

  const BulkPickedFile({required this.name, required this.bytes});

  String get extension => p.extension(name).toLowerCase();
}

class BulkProductImportResult {
  final int imported;
  final int skipped;
  final List<String> errors;

  const BulkProductImportResult({
    required this.imported,
    required this.skipped,
    required this.errors,
  });
}

class BulkProductImportService {
  static const templateHeaders = <String>[
    'product_name',
    'sku',
    'barcode',
    'category',
    'unit',
    'product_type',
    'cost',
    'selling_price',
    'opening_stock',
    'minimum_stock',
    'target_stock',
    'location',
    'supplier',
    'tax_code',
    'tax_inclusive',
    'purchase_moq',
    'order_multiple',
    'case_pack',
    'sellable',
    'purchasable',
    'lifecycle_status',
    'replacement_product_code',
    'demand_family',
    'inherit_predecessor_history',
    'active',
    'track_batch',
    'track_expiry',
  ];

  static Future<BulkPickedFile?> chooseFile() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose product import file',
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    final ext = p.extension(file.name).toLowerCase();
    if (ext != '.csv' && ext != '.xlsx') {
      throw Exception('Choose a CSV or XLSX product file.');
    }
    Uint8List? bytes;
    if (file.path != null && file.path!.trim().isNotEmpty) {
      bytes = await File(file.path!).readAsBytes();
    } else {
      bytes = file.bytes;
    }
    if (bytes == null)
      throw Exception(
          'The selected file could not be read. Please choose it again.');
    return BulkPickedFile(name: file.name, bytes: bytes);
  }

  static Future<String?> saveTemplate() async {
    String? chosen;
    try {
      chosen = await FilePicker.platform.saveFile(
        dialogTitle: 'Save product import template',
        fileName: 'RELIQ_Product_Import_Template.csv',
        type: FileType.any,
      );
    } catch (_) {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) rethrow;
      await downloads.create(recursive: true);
      chosen = p.join(downloads.path, 'RELIQ_Product_Import_Template.csv');
    }
    if (chosen == null) return null;

    const sampleRows = <List<String>>[
      [
        'Sample Product',
        '',
        '',
        'General',
        'pcs',
        'Stocked',
        '1.250',
        '2.000',
        '25',
        '5',
        '20',
        'A1',
        'Sample Supplier',
        'NONE',
        'no',
        '1',
        '1',
        '1',
        'yes',
        'yes',
        'Active',
        '',
        '',
        'yes',
        'yes',
        'no',
        'no'
      ],
      [
        'Installation Service',
        '',
        '',
        'Services',
        'pcs',
        'Service',
        '0.000',
        '10.000',
        '0',
        '0',
        '0',
        '',
        '',
        'NONE',
        'no',
        '0',
        '1',
        '1',
        'yes',
        'no',
        'Active',
        '',
        '',
        'yes',
        'yes',
        'no',
        'no'
      ],
    ];
    final b = StringBuffer()..writeln(templateHeaders.join(','));
    for (final row in sampleRows) {
      b.writeln(row.map(_csvCell).join(','));
    }
    final target =
        chosen.toLowerCase().endsWith('.csv') ? chosen : '$chosen.csv';
    final file = File(target);
    await file.writeAsString(b.toString(), flush: true);
    return file.path;
  }

  static Future<List<BulkProductRow>> parse(BulkPickedFile file) async {
    final rows = file.extension == '.xlsx'
        ? _readXlsx(file.bytes)
        : _readCsv(utf8.decode(file.bytes, allowMalformed: true));
    if (rows.isEmpty) {
      return const [BulkProductRow(1, {}, 'The file is empty.')];
    }

    final headers = rows.first.map(_normaliseHeader).toList();
    if (!headers
        .any((h) => const ['product_name', 'product', 'name'].contains(h))) {
      return const [
        BulkProductRow(
            1, {}, 'The template must contain a product_name column.')
      ];
    }

    final result = <BulkProductRow>[];
    for (var r = 1; r < rows.length; r++) {
      final cells = rows[r];
      if (cells.every((e) => e.trim().isEmpty)) continue;

      final raw = <String, String>{};
      for (var c = 0; c < headers.length; c++) {
        if (headers[c].isEmpty) continue;
        raw[headers[c]] = c < cells.length ? cells[c].trim() : '';
      }

      String get(List<String> keys) {
        for (final k in keys) {
          final value = raw[k];
          if (value != null && value.trim().isNotEmpty) return value.trim();
        }
        return '';
      }

      final name = get(const ['product_name', 'product', 'name']);
      final cost = _number(get(const ['cost', 'unit_cost', 'purchase_price']));
      final price = _number(get(const [
        'selling_price',
        'sell_price',
        'price',
        'sale_price',
        'retail_price',
        'selling_rate',
        'sales_price'
      ]));
      final opening =
          _number(get(const ['opening_stock', 'stock', 'opening_qty']));
      final minStock =
          _number(get(const ['minimum_stock', 'min_stock', 'reorder_level']));
      final target =
          _number(get(const ['target_stock', 'target', 'desired_stock']));

      String? error;
      if (name.isEmpty) {
        error = 'Product name is required.';
      } else if (cost < 0 ||
          price < 0 ||
          opening < 0 ||
          minStock < 0 ||
          target < 0) {
        error =
            'Cost, price and stock values must be valid non-negative numbers.';
      }

      result.add(BulkProductRow(
          r + 1,
          {
            'name': name,
            'sku': _nullable(get(const ['sku', 'item_code', 'product_code'])),
            'external_barcode': _nullable(get(const ['barcode', 'ean', 'upc'])),
            'category': get(const ['category']).isEmpty
                ? 'General'
                : get(const ['category']),
            'unit': get(const ['unit', 'uom']).isEmpty
                ? 'pcs'
                : get(const ['unit', 'uom']),
            'product_type':
                _normaliseProductType(get(const ['product_type', 'type'])),
            'cost': cost,
            'price': price,
            'stock': opening,
            'min_stock': minStock,
            'target_stock': target,
            'location':
                _nullable(get(const ['location', 'bin_location', 'rack'])),
            'supplier':
                _nullable(get(const ['supplier', 'supplier_name', 'vendor'])),
            'tax_code': get(const ['tax_code', 'tax']).isEmpty
                ? 'NONE'
                : get(const ['tax_code', 'tax']),
            'tax_inclusive': _bool(
                    get(const ['tax_inclusive', 'price_includes_tax']),
                    defaultValue: false)
                ? 1
                : 0,
            'purchase_moq': _number(get(const ['purchase_moq', 'moq'])),
            'order_multiple': _numberOrDefault(
                get(const ['order_multiple', 'order_qty_multiple']), 1),
            'case_pack':
                _numberOrDefault(get(const ['case_pack', 'pack_size']), 1),
            'sellable':
                _bool(get(const ['sellable', 'can_sell']), defaultValue: true)
                    ? 1
                    : 0,
            'purchasable': _bool(get(const ['purchasable', 'can_purchase']),
                    defaultValue: true)
                ? 1
                : 0,
            'lifecycle_status':
                _normaliseLifecycle(get(const ['lifecycle_status', 'status'])),
            'replacement_product_id': null,
            'demand_family':
                _nullable(get(const ['demand_family', 'equivalent_group'])),
            'inherit_predecessor_history': _bool(
                    get(const [
                      'inherit_predecessor_history',
                      'inherit_history'
                    ]),
                    defaultValue: true)
                ? 1
                : 0,
            'active':
                _bool(get(const ['active', 'enabled']), defaultValue: true)
                    ? 1
                    : 0,
            'track_batch':
                _bool(get(const ['track_batch', 'batch']), defaultValue: false)
                    ? 1
                    : 0,
            'track_expiry': _bool(get(const ['track_expiry', 'expiry']),
                    defaultValue: false)
                ? 1
                : 0,
          },
          error));
    }
    return result;
  }

  static Future<BulkProductImportResult> importRows(
      List<BulkProductRow> rows) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.bulkTools);
    var imported = 0;
    var skipped = 0;
    final errors = <String>[];

    for (final row in rows) {
      if (!row.valid) {
        skipped++;
        errors.add('Row ${row.rowNumber}: ${row.error}');
        continue;
      }
      try {
        final sku = row.values['sku']?.toString().trim() ?? '';
        final barcode = row.values['external_barcode']?.toString().trim() ?? '';

        if (sku.isNotEmpty) {
          final existing = await AppDatabase.instance.products(search: sku);
          if (existing.any((p) =>
              (p['sku'] ?? '').toString().toLowerCase() == sku.toLowerCase())) {
            skipped++;
            errors.add('Row ${row.rowNumber}: SKU "$sku" already exists.');
            continue;
          }
        }
        if (barcode.isNotEmpty) {
          final existing = await AppDatabase.instance.products(search: barcode);
          if (existing.any((p) =>
              (p['external_barcode'] ?? '').toString() == barcode ||
              (p['internal_barcode'] ?? '').toString() == barcode)) {
            skipped++;
            errors.add(
                'Row ${row.rowNumber}: Barcode "$barcode" already exists.');
            continue;
          }
        }

        await AppDatabase.instance
            .saveProduct(Map<String, Object?>.from(row.values));
        imported++;
      } catch (e) {
        skipped++;
        errors.add(
            'Row ${row.rowNumber}: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }

    return BulkProductImportResult(
        imported: imported, skipped: skipped, errors: errors);
  }

  static List<List<String>> _readCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        row.add(field.toString());
        field = StringBuffer();
      } else if ((ch == '\n' || ch == '\r') && !inQuotes) {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field = StringBuffer();
        if (row.any((e) => e.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.write(ch);
      }
    }
    row.add(field.toString());
    if (row.any((e) => e.isNotEmpty)) rows.add(row);
    return rows;
  }

  static List<List<String>> _readXlsx(Uint8List bytes) {
    final book = Excel.decodeBytes(bytes);
    if (book.tables.isEmpty) return const [];
    final sheet = book.tables.values.first;
    return [
      for (final row in sheet.rows)
        [for (final cell in row) cell?.value?.toString() ?? '']
    ];
  }

  static String _csvCell(String value) {
    if (!value.contains(',') && !value.contains('"') && !value.contains('\n'))
      return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  static String _normaliseHeader(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  static String _normaliseProductType(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'recipe' || v == 'receipe') return 'Recipe';
    if (v == 'combo' || v == 'bundle') return 'Combo';
    if (v == 'service' || v == 'services') return 'Service';
    if (v == 'non-stocked' ||
        v == 'non stocked' ||
        v == 'nonstocked' ||
        v == 'non-stock' ||
        v == 'nonstock') return 'Non-stocked';
    return 'Stocked';
  }

  static String _normaliseLifecycle(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'discontinued') return 'Discontinued';
    if (v == 'replaced') return 'Replaced';
    if (v == 'archived' || v == 'inactive') return 'Archived';
    return 'Active';
  }

  static double _number(String value) {
    final cleaned = value.replaceAll(',', '').trim();
    if (cleaned.isEmpty) return 0;
    return double.tryParse(cleaned) ?? -1;
  }

  static double _numberOrDefault(String value, double fallback) {
    final cleaned = value.replaceAll(',', '').trim();
    if (cleaned.isEmpty) return fallback;
    return double.tryParse(cleaned) ?? fallback;
  }

  static bool _bool(String value, {required bool defaultValue}) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return defaultValue;
    return const ['1', 'true', 'yes', 'y', 'active', 'on'].contains(v);
  }

  static String? _nullable(String value) =>
      value.trim().isEmpty ? null : value.trim();
}
