import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/app_database.dart';
import 'license_manager.dart';

enum MigrationEntity {
  products,
  customers,
  suppliers,
  sales,
  saleItems,
  purchases,
  purchaseItems,
  customerReceipts,
  customerReceiptAllocations,
  supplierPayments,
  supplierPaymentAllocations,
  expenses,
  salesReturns,
  saleReturnItems,
  purchaseReturns,
  purchaseReturnItems,
  stockAdjustments,
}

extension MigrationEntityX on MigrationEntity {
  String get fileName => switch (this) {
        MigrationEntity.products => 'products.csv',
        MigrationEntity.customers => 'customers.csv',
        MigrationEntity.suppliers => 'suppliers.csv',
        MigrationEntity.sales => 'sales.csv',
        MigrationEntity.saleItems => 'sale_items.csv',
        MigrationEntity.purchases => 'purchases.csv',
        MigrationEntity.purchaseItems => 'purchase_items.csv',
        MigrationEntity.customerReceipts => 'customer_receipts.csv',
        MigrationEntity.customerReceiptAllocations =>
          'customer_receipt_allocations.csv',
        MigrationEntity.supplierPayments => 'supplier_payments.csv',
        MigrationEntity.supplierPaymentAllocations =>
          'supplier_payment_allocations.csv',
        MigrationEntity.expenses => 'expenses.csv',
        MigrationEntity.salesReturns => 'sales_returns.csv',
        MigrationEntity.saleReturnItems => 'sale_return_items.csv',
        MigrationEntity.purchaseReturns => 'purchase_returns.csv',
        MigrationEntity.purchaseReturnItems => 'purchase_return_items.csv',
        MigrationEntity.stockAdjustments => 'stock_adjustments.csv',
      };

  Set<String> get acceptedFileNames => switch (this) {
        MigrationEntity.saleItems => const {
            'sale_items.csv',
            'sales_items.csv'
          },
        MigrationEntity.purchaseItems => const {
            'purchase_items.csv',
            'purchases_items.csv'
          },
        MigrationEntity.salesReturns => const {
            'sales_returns.csv',
            'sale_returns.csv',
            'sales_return.csv'
          },
        MigrationEntity.saleReturnItems => const {
            'sale_return_items.csv',
            'sales_return_items.csv',
            'sales_returns_items.csv'
          },
        MigrationEntity.purchaseReturns => const {
            'purchase_returns.csv',
            'purchases_returns.csv',
            'purchase_return.csv'
          },
        MigrationEntity.purchaseReturnItems => const {
            'purchase_return_items.csv',
            'purchase_returns_items.csv',
            'purchases_return_items.csv'
          },
        _ => {fileName},
      };

  String get title => switch (this) {
        MigrationEntity.products => 'Products',
        MigrationEntity.customers => 'Customers',
        MigrationEntity.suppliers => 'Suppliers',
        MigrationEntity.sales => 'Sales history',
        MigrationEntity.saleItems => 'Sale items',
        MigrationEntity.purchases => 'Purchase history',
        MigrationEntity.purchaseItems => 'Purchase items',
        MigrationEntity.customerReceipts => 'Customer receipts',
        MigrationEntity.customerReceiptAllocations =>
          'Customer receipt allocations',
        MigrationEntity.supplierPayments => 'Supplier payments',
        MigrationEntity.supplierPaymentAllocations =>
          'Supplier payment allocations',
        MigrationEntity.expenses => 'Expenses',
        MigrationEntity.salesReturns => 'Sales returns',
        MigrationEntity.saleReturnItems => 'Sales return items',
        MigrationEntity.purchaseReturns => 'Purchase returns',
        MigrationEntity.purchaseReturnItems => 'Purchase return items',
        MigrationEntity.stockAdjustments => 'Stock adjustments',
      };
}

class MigrationFile {
  final MigrationEntity entity;
  final String sourceName;
  final List<Map<String, String>> rows;
  final List<String> errors;

  const MigrationFile(
      {required this.entity,
      required this.sourceName,
      required this.rows,
      required this.errors});
  bool get valid => errors.isEmpty;
}

class MigrationRunResult {
  final int imported;
  final int skipped;
  final List<String> warnings;
  final String? backupPath;
  final Map<String, num> reconciliation;

  const MigrationRunResult({
    required this.imported,
    required this.skipped,
    required this.warnings,
    this.backupPath,
    this.reconciliation = const {},
  });
}

// CSV validation and ZIP expansion can be CPU-heavy for large takeovers. Keep
// that work off Flutter's UI isolate so Migration Center can continue painting
// progress instead of looking frozen.
Map<String, Object?> _parseMigrationCsvWorker(Map<String, Object?> payload) {
  final entity = MigrationEntity.values[(payload['entity'] as num).toInt()];
  final parsed = MigrationCenterService.parseCsv(
      entity, payload['sourceName'] as String, payload['text'] as String);
  return <String, Object?>{
    'entity': entity.index,
    'sourceName': parsed.sourceName,
    'rows': parsed.rows,
    'errors': parsed.errors
  };
}

List<Map<String, Object?>> _parseMigrationZipWorker(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final out = <Map<String, Object?>>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final base = p.basename(entry.name).toLowerCase();
    if (p.extension(base) != '.csv') continue;
    final data = entry.content;
    final raw = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : null);
    if (raw == null) continue;
    final text = MigrationCenterService._decodeCsvBytes(raw);
    final entity = MigrationCenterService._entityFromFileName(base) ??
        MigrationCenterService._detectEntity(base, text);
    if (entity == null) {
      throw FormatException(
          'Unrecognised CSV file in migration ZIP: $base. Rename it to a supported template name or correct its column headings.');
    }
    final parsed = MigrationCenterService.parseCsv(entity, base, text);
    // Header-only templates are intentionally allowed in the pack. Skip them
    // rather than treating them as data, but keep malformed headers as errors.
    if (parsed.rows.isEmpty && parsed.errors.isEmpty) continue;
    out.add(<String, Object?>{
      'entity': entity.index,
      'sourceName': parsed.sourceName,
      'rows': parsed.rows,
      'errors': parsed.errors
    });
  }
  return out;
}

MigrationFile _migrationFileFromWorker(Map<String, Object?> data) =>
    MigrationFile(
      entity: MigrationEntity.values[(data['entity'] as num).toInt()],
      sourceName: data['sourceName'] as String,
      rows: (data['rows'] as List)
          .map((row) => Map<String, String>.from(row as Map))
          .toList(),
      errors: List<String>.from(data['errors'] as List),
    );

class MigrationCenterService {
  static const Map<MigrationEntity, List<String>> headers = {
    MigrationEntity.products: [
      'product_code',
      'sku',
      'barcode',
      'product_name',
      'category',
      'unit',
      'product_type',
      'purchase_price',
      'selling_price',
      'current_stock',
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
      'track_expiry'
    ],
    MigrationEntity.customers: [
      'customer_code',
      'customer_name',
      'phone',
      'whatsapp',
      'email',
      'contact',
      'address',
      'credit_allowed',
      'credit_limit',
      'terms_days',
      'current_balance',
      'credit_balance',
      'group_id',
      'active'
    ],
    MigrationEntity.suppliers: [
      'supplier_code',
      'supplier_name',
      'phone',
      'whatsapp',
      'email',
      'contact',
      'address',
      'lead_days',
      'terms_days',
      'current_balance',
      'credit_balance',
      'minimum_order_value',
      'active'
    ],
    MigrationEntity.sales: [
      'invoice_no',
      'invoice_date',
      'due_date',
      'customer_code',
      'subtotal',
      'discount',
      'tax',
      'delivery_charge',
      'other_charge',
      'total',
      'paid',
      'balance',
      'payment_method',
      'status',
      'notes'
    ],
    MigrationEntity.saleItems: [
      'invoice_no',
      'product_code',
      'product_name',
      'quantity',
      'unit_price',
      'discount',
      'tax',
      'cost_price',
      'line_total'
    ],
    MigrationEntity.purchases: [
      'purchase_no',
      'purchase_date',
      'due_date',
      'supplier_code',
      'supplier_invoice_no',
      'subtotal',
      'discount',
      'tax',
      'freight',
      'other_charges',
      'total',
      'paid',
      'balance',
      'payment_method',
      'status',
      'notes'
    ],
    MigrationEntity.purchaseItems: [
      'purchase_no',
      'product_code',
      'product_name',
      'quantity',
      'unit_cost',
      'discount',
      'tax',
      'line_total',
      'batch_no',
      'expiry_date'
    ],
    MigrationEntity.customerReceipts: [
      'receipt_no',
      'date',
      'customer_code',
      'amount',
      'payment_method',
      'reference',
      'notes'
    ],
    MigrationEntity.customerReceiptAllocations: [
      'receipt_no',
      'invoice_no',
      'allocated_amount'
    ],
    MigrationEntity.supplierPayments: [
      'payment_no',
      'date',
      'supplier_code',
      'amount',
      'payment_method',
      'reference',
      'notes'
    ],
    MigrationEntity.supplierPaymentAllocations: [
      'payment_no',
      'purchase_no',
      'allocated_amount'
    ],
    MigrationEntity.expenses: [
      'expense_no',
      'date',
      'category',
      'description',
      'amount',
      'tax_amount',
      'tax_code',
      'payment_method',
      'reference',
      'notes'
    ],
    MigrationEntity.salesReturns: [
      'return_no',
      'date',
      'invoice_no',
      'customer_code',
      'total',
      'refund_amount',
      'refund_method',
      'notes'
    ],
    MigrationEntity.saleReturnItems: [
      'return_no',
      'product_code',
      'product_name',
      'quantity',
      'unit_price',
      'discount',
      'tax',
      'cost_price',
      'line_total'
    ],
    MigrationEntity.purchaseReturns: [
      'return_no',
      'date',
      'purchase_no',
      'supplier_code',
      'total',
      'refund_amount',
      'refund_method',
      'notes'
    ],
    MigrationEntity.purchaseReturnItems: [
      'return_no',
      'product_code',
      'product_name',
      'quantity',
      'unit_cost',
      'discount',
      'tax',
      'line_total'
    ],
    MigrationEntity.stockAdjustments: [
      'adjustment_no',
      'date',
      'product_code',
      'quantity_change',
      'reason'
    ],
  };

  static const Map<MigrationEntity, List<String>> requiredHeaders = {
    MigrationEntity.products: ['product_name'],
    MigrationEntity.customers: ['customer_name'],
    MigrationEntity.suppliers: ['supplier_name'],
    MigrationEntity.sales: ['invoice_no', 'invoice_date', 'total'],
    MigrationEntity.saleItems: ['invoice_no', 'quantity'],
    MigrationEntity.purchases: ['purchase_no', 'purchase_date', 'total'],
    MigrationEntity.purchaseItems: ['purchase_no', 'quantity'],
    MigrationEntity.customerReceipts: ['receipt_no', 'date', 'amount'],
    MigrationEntity.customerReceiptAllocations: [
      'receipt_no',
      'invoice_no',
      'allocated_amount'
    ],
    MigrationEntity.supplierPayments: ['payment_no', 'date', 'amount'],
    MigrationEntity.supplierPaymentAllocations: [
      'payment_no',
      'purchase_no',
      'allocated_amount'
    ],
    MigrationEntity.expenses: ['date', 'description', 'amount'],
    MigrationEntity.salesReturns: ['return_no', 'date', 'total'],
    MigrationEntity.saleReturnItems: ['return_no', 'quantity'],
    MigrationEntity.purchaseReturns: ['return_no', 'date', 'total'],
    MigrationEntity.purchaseReturnItems: ['return_no', 'quantity'],
    MigrationEntity.stockAdjustments: [
      'date',
      'product_code',
      'quantity_change'
    ],
  };

  static const Map<String, String> _commonAliases = {
    'ean': 'barcode',
    'upc': 'barcode',
    'bar_code': 'barcode',
    'qty': 'quantity',
    'units': 'quantity',
    'method': 'payment_method',
    'mode': 'payment_method',
  };

  static Map<String, String> _aliasesFor(MigrationEntity entity) {
    final aliases = <String, String>{..._commonAliases};
    switch (entity) {
      case MigrationEntity.products:
        aliases.addAll({
          'name': 'product_name',
          'product': 'product_name',
          'item_name': 'product_name',
          'description_name': 'product_name',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'cost': 'purchase_price',
          'unit_cost': 'purchase_price',
          'buy_price': 'purchase_price',
          'purchase_rate': 'purchase_price',
          'price': 'selling_price',
          'sell_price': 'selling_price',
          'sale_price': 'selling_price',
          'retail_price': 'selling_price',
          'selling_rate': 'selling_price',
          'sales_price': 'selling_price',
          'stock': 'current_stock',
          'opening_stock': 'current_stock',
          'opening_qty': 'current_stock',
          'quantity_on_hand': 'current_stock',
          'min_stock': 'minimum_stock',
          'reorder_level': 'minimum_stock',
          'target': 'target_stock',
          'desired_stock': 'target_stock',
          'vendor_name': 'supplier',
          'vendor': 'supplier',
          'supplier_name': 'supplier',
        });
        break;
      case MigrationEntity.customers:
        aliases.addAll({
          'name': 'customer_name',
          'customer': 'customer_name',
          'party_name': 'customer_name',
          'customer_id': 'customer_code',
          'party_code': 'customer_code',
          'code': 'customer_code'
        });
        break;
      case MigrationEntity.suppliers:
        aliases.addAll({
          'name': 'supplier_name',
          'supplier': 'supplier_name',
          'vendor_name': 'supplier_name',
          'vendor': 'supplier_name',
          'supplier_id': 'supplier_code',
          'vendor_code': 'supplier_code',
          'code': 'supplier_code'
        });
        break;
      case MigrationEntity.sales:
        aliases.addAll({
          'invoice': 'invoice_no',
          'sale_no': 'invoice_no',
          'sales_invoice': 'invoice_no',
          'invoice_number': 'invoice_no',
          'date': 'invoice_date',
          'sale_date': 'invoice_date',
          'invoice_date_time': 'invoice_date',
          'customer_id': 'customer_code',
          'party_code': 'customer_code'
        });
        break;
      case MigrationEntity.saleItems:
        aliases.addAll({
          'invoice': 'invoice_no',
          'sale_no': 'invoice_no',
          'sales_no': 'invoice_no',
          'invoice_number': 'invoice_no',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'name': 'product_name',
          'product': 'product_name',
          'item_name': 'product_name',
          'rate': 'unit_price',
          'sale_rate': 'unit_price',
          'cost': 'cost_price'
        });
        break;
      case MigrationEntity.purchases:
        aliases.addAll({
          'purchase_number': 'purchase_no',
          'purchase_invoice': 'purchase_no',
          'date': 'purchase_date',
          'purchase_date_time': 'purchase_date',
          'supplier_id': 'supplier_code',
          'vendor_code': 'supplier_code',
          'vendor_invoice_no': 'supplier_invoice_no'
        });
        break;
      case MigrationEntity.purchaseItems:
        aliases.addAll({
          'purchase_number': 'purchase_no',
          'purchase_invoice': 'purchase_no',
          'purchase_id': 'purchase_no',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'name': 'product_name',
          'product': 'product_name',
          'item_name': 'product_name',
          'cost': 'unit_cost',
          'purchase_price': 'unit_cost',
          'purchase_rate': 'unit_cost'
        });
        break;
      case MigrationEntity.customerReceipts:
        aliases.addAll({
          'receipt_number': 'receipt_no',
          'receipt_date': 'date',
          'payment_date': 'date',
          'customer_id': 'customer_code',
          'party_code': 'customer_code'
        });
        break;
      case MigrationEntity.customerReceiptAllocations:
        aliases.addAll({
          'receipt_number': 'receipt_no',
          'invoice': 'invoice_no',
          'invoice_number': 'invoice_no',
          'amount': 'allocated_amount',
          'allocation': 'allocated_amount'
        });
        break;
      case MigrationEntity.supplierPayments:
        aliases.addAll({
          'payment_number': 'payment_no',
          'payment_date': 'date',
          'supplier_id': 'supplier_code',
          'vendor_code': 'supplier_code'
        });
        break;
      case MigrationEntity.supplierPaymentAllocations:
        aliases.addAll({
          'payment_number': 'payment_no',
          'purchase_number': 'purchase_no',
          'purchase_invoice': 'purchase_no',
          'amount': 'allocated_amount',
          'allocation': 'allocated_amount'
        });
        break;
      case MigrationEntity.expenses:
        aliases.addAll({
          'expense_date': 'date',
          'expense_number': 'expense_no',
          'expense_no_': 'expense_no'
        });
        break;
      case MigrationEntity.salesReturns:
        aliases.addAll({
          'return_number': 'return_no',
          'sales_return_no': 'return_no',
          'sale_return_no': 'return_no',
          'return_id': 'return_no',
          'return_date': 'date',
          'invoice': 'invoice_no',
          'invoice_number': 'invoice_no',
          'customer_id': 'customer_code'
        });
        break;
      case MigrationEntity.saleReturnItems:
        aliases.addAll({
          'return_number': 'return_no',
          'sales_return_no': 'return_no',
          'sale_return_no': 'return_no',
          'return_id': 'return_no',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'name': 'product_name',
          'product': 'product_name',
          'item_name': 'product_name',
          'qty_returned': 'quantity',
          'return_qty': 'quantity',
          'rate': 'unit_price',
          'cost': 'cost_price'
        });
        break;
      case MigrationEntity.purchaseReturns:
        aliases.addAll({
          'return_number': 'return_no',
          'purchase_return_no': 'return_no',
          'return_id': 'return_no',
          'return_date': 'date',
          'purchase_number': 'purchase_no',
          'purchase_invoice': 'purchase_no',
          'supplier_id': 'supplier_code',
          'vendor_code': 'supplier_code'
        });
        break;
      case MigrationEntity.purchaseReturnItems:
        aliases.addAll({
          'return_number': 'return_no',
          'purchase_return_no': 'return_no',
          'return_id': 'return_no',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'name': 'product_name',
          'product': 'product_name',
          'item_name': 'product_name',
          'qty_returned': 'quantity',
          'return_qty': 'quantity',
          'cost': 'unit_cost',
          'purchase_price': 'unit_cost'
        });
        break;
      case MigrationEntity.stockAdjustments:
        aliases.addAll({
          'adjustment_number': 'adjustment_no',
          'adjustment_date': 'date',
          'item_code': 'product_code',
          'code': 'product_code',
          'product_id': 'product_code',
          'qty_change': 'quantity_change',
          'change': 'quantity_change'
        });
        break;
    }
    return aliases;
  }

  static Future<MigrationFile?> pickCsv(
    MigrationEntity requestedEntity, {
    void Function()? onFileChosen,
  }) async {
    // Do not mark the page busy before the native panel is visible. On macOS a
    // rebuild/disabled control during the click that launches NSOpenPanel can
    // make the picker appear to hang behind the application window.
    await Future<void>.delayed(Duration.zero);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose ${requestedEntity.title} CSV',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      allowMultiple: false,
      // Keep the selected bytes while macOS' security-scoped permission is
      // active. The path fallback remains available for non-sandboxed builds.
      withData: Platform.isMacOS,
    );
    if (result == null || result.files.isEmpty) return null;
    onFileChosen?.call();
    final f = result.files.single;
    if (p.extension(f.name).toLowerCase() != '.csv') {
      throw Exception('Choose a CSV file for ${requestedEntity.title}.');
    }
    final bytes = await _pickedBytes(f, label: 'CSV');
    final text = _decodeCsvBytes(bytes);
    // Individual imports are intentionally strict: the section the user clicked
    // defines the schema. Parse/validate on a worker isolate so a large CSV does
    // not block Flutter's frame loop.
    final parsed = await compute(_parseMigrationCsvWorker, <String, Object?>{
      'entity': requestedEntity.index,
      'sourceName': f.name,
      'text': text,
    });
    final file = _migrationFileFromWorker(parsed);
    if (file.rows.isEmpty && file.errors.isEmpty) {
      throw Exception(
          'The CSV has column headings but no data rows. Fill in at least one row and try again.');
    }
    return file;
  }

  static Future<List<MigrationFile>?> pickMigrationZip({
    void Function()? onFileChosen,
  }) async {
    await Future<void>.delayed(Duration.zero);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose RELIQ migration ZIP',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      allowMultiple: false,
      // Keep the selected bytes while macOS' security-scoped permission is
      // active. The path fallback remains available for non-sandboxed builds.
      withData: Platform.isMacOS,
    );
    if (result == null || result.files.isEmpty) return null;
    onFileChosen?.call();
    final f = result.files.single;
    if (p.extension(f.name).toLowerCase() != '.zip') {
      throw Exception(
          'Choose a ZIP created from the RELIQ migration template pack.');
    }
    final bytes = await _pickedBytes(f, label: 'ZIP');
    final parsed = await compute(_parseMigrationZipWorker, bytes);
    if (parsed.isEmpty) {
      throw Exception(
          'No populated, recognised migration CSV files were found in this ZIP. Fill in at least one template first.');
    }
    return parsed.map(_migrationFileFromWorker).toList();
  }

  static MigrationEntity? _entityFromFileName(String sourceName) {
    final base = p.basename(sourceName).toLowerCase();
    for (final entity in MigrationEntity.values) {
      if (entity.acceptedFileNames.contains(base)) return entity;
    }
    return null;
  }

  static MigrationEntity? _detectEntity(String sourceName, String text,
      {MigrationEntity? preferred}) {
    final named = _entityFromFileName(sourceName);
    final matrix = _readCsv(text);
    if (matrix.isEmpty) return named ?? preferred;
    final rawHeaders =
        matrix.first.map(_normaliseHeader).where((h) => h.isNotEmpty).toList();
    MigrationEntity? best;
    var bestScore = -100000;
    var bestRequiredMatched = -1;
    for (final entity in MigrationEntity.values) {
      final aliases = _aliasesFor(entity);
      final mapped = rawHeaders.map((h) => aliases[h] ?? h).toSet();
      final required = requiredHeaders[entity] ?? const <String>[];
      final requiredMatched = required.where(mapped.contains).length;
      final known = headers[entity]!.where(mapped.contains).length;
      var score = known +
          (requiredMatched * 20) -
          ((required.length - requiredMatched) * 30);
      if (entity == named) score += 8;
      if (entity == preferred) score += 2;
      // Strong discriminator columns stop header/item files from being confused.
      if (entity == MigrationEntity.sales &&
          mapped.contains('invoice_no') &&
          mapped.contains('invoice_date')) score += 25;
      if (entity == MigrationEntity.saleItems &&
          mapped.contains('invoice_no') &&
          mapped.contains('quantity') &&
          !mapped.contains('invoice_date')) score += 25;
      if (entity == MigrationEntity.purchases &&
          mapped.contains('purchase_no') &&
          mapped.contains('purchase_date')) score += 25;
      if (entity == MigrationEntity.purchaseItems &&
          mapped.contains('purchase_no') &&
          mapped.contains('quantity') &&
          !mapped.contains('purchase_date')) score += 25;
      if (entity == MigrationEntity.salesReturns &&
          mapped.contains('return_no') &&
          mapped.contains('date') &&
          mapped.contains('total') &&
          mapped.contains('invoice_no')) score += 35;
      if (entity == MigrationEntity.saleReturnItems &&
          mapped.contains('return_no') &&
          mapped.contains('quantity') &&
          (mapped.contains('unit_price') || mapped.contains('cost_price')) &&
          !mapped.contains('date')) score += 35;
      if (entity == MigrationEntity.purchaseReturns &&
          mapped.contains('return_no') &&
          mapped.contains('date') &&
          mapped.contains('total') &&
          mapped.contains('purchase_no')) score += 35;
      if (entity == MigrationEntity.purchaseReturnItems &&
          mapped.contains('return_no') &&
          mapped.contains('quantity') &&
          mapped.contains('unit_cost') &&
          !mapped.contains('date')) score += 35;
      if (score > bestScore ||
          (score == bestScore && requiredMatched > bestRequiredMatched)) {
        best = entity;
        bestScore = score;
        bestRequiredMatched = requiredMatched;
      }
    }
    if (best == null) return preferred;
    final req = requiredHeaders[best] ?? const <String>[];
    if (bestRequiredMatched < req.length) return preferred;
    return best;
  }

  static MigrationFile parseCsv(
      MigrationEntity entity, String sourceName, String text) {
    final matrix = _readCsv(text);
    if (matrix.isEmpty) {
      return MigrationFile(
          entity: entity,
          sourceName: sourceName,
          rows: const [],
          errors: const ['File is empty.']);
    }
    final sourceHeaders = matrix.first.map(_normaliseHeader).toList();
    final aliases = _aliasesFor(entity);
    final mappedHeaders = sourceHeaders.map((h) => aliases[h] ?? h).toList();
    final required = requiredHeaders[entity] ?? const <String>[];
    final missing = required.where((h) => !mappedHeaders.contains(h)).toList();
    final errors = <String>[];
    if (missing.isNotEmpty)
      errors.add('Missing required column(s): ${missing.join(', ')}');

    final rows = <Map<String, String>>[];
    for (var i = 1; i < matrix.length; i++) {
      final cells = matrix[i];
      if (cells.every((v) => v.trim().isEmpty)) continue;
      final row = <String, String>{};
      for (var c = 0; c < mappedHeaders.length; c++) {
        final h = mappedHeaders[c];
        if (h.isEmpty) continue;
        final value = c < cells.length ? cells[c].trim() : '';
        if (!row.containsKey(h) || ((row[h] ?? '').isEmpty && value.isNotEmpty))
          row[h] = value;
      }
      rows.add(row);
    }
    errors.addAll(_validateRows(entity, rows));
    return MigrationFile(
        entity: entity, sourceName: sourceName, rows: rows, errors: errors);
  }

  static Future<String?> saveTemplate(MigrationEntity entity) async {
    final chosen = await _savePath(
      dialogTitle: 'Save ${entity.title} template',
      fileName: entity.fileName,
    );
    if (chosen == null) return null;
    final path = chosen.toLowerCase().endsWith('.csv') ? chosen : '$chosen.csv';
    await File(path).writeAsString(_templateText(entity), flush: true);
    return path;
  }

  static Future<String?> saveTemplatePack() async {
    final chosen = await _savePath(
      dialogTitle: 'Save RELIQ migration template pack',
      fileName: 'RELIQ_Migration_Template_Pack.zip',
    );
    if (chosen == null) return null;
    final archive = Archive();
    for (final entity in MigrationEntity.values) {
      final bytes = utf8.encode(_templateText(entity));
      archive.addFile(ArchiveFile(entity.fileName, bytes.length, bytes));
    }
    final readme = utf8.encode(_templateReadme);
    archive.addFile(ArchiveFile('README.txt', readme.length, readme));
    final zip = ZipEncoder().encode(archive);
    if (zip == null)
      throw Exception('Could not create migration template ZIP.');
    final path = chosen.toLowerCase().endsWith('.zip') ? chosen : '$chosen.zip';
    await File(path).writeAsBytes(zip, flush: true);
    return path;
  }

  static Future<Uint8List> _pickedBytes(PlatformFile file,
      {required String label}) async {
    // Prefer picker-owned bytes: a sandboxed macOS app may not be permitted
    // to reopen the same file path after the native dialog has closed.
    if (file.bytes != null) return file.bytes!;
    if (file.path != null && file.path!.trim().isNotEmpty) {
      try {
        return await File(file.path!).readAsBytes();
      } on FileSystemException catch (e) {
        throw Exception(
            'Cannot read selected $label file: ${e.message}. On macOS, check the app user-selected file read/write entitlement.');
      }
    }
    throw Exception(
        'The selected $label could not be read. Please choose the file again.');
  }

  static Future<String?> _savePath(
      {required String dialogTitle, required String fileName}) async {
    try {
      return await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: FileType.any,
      );
    } catch (_) {
      // A native save panel can be blocked by a restrictive desktop sandbox.
      // Keep template downloads usable by falling back to Downloads.
      final downloads = await getDownloadsDirectory();
      if (downloads == null) rethrow;
      await downloads.create(recursive: true);
      return p.join(downloads.path, fileName);
    }
  }

  static List<String> packageErrors(List<MigrationFile> files) {
    final errors = <String>[];
    final byEntity = <MigrationEntity, MigrationFile>{};
    for (final file in files) {
      if (byEntity.containsKey(file.entity)) {
        errors.add(
            'The ZIP contains more than one file detected as ${file.entity.title}. Keep only one copy for each migration section.');
      } else {
        byEntity[file.entity] = file;
      }
    }
    return errors;
  }

  static Future<List<String>> referenceErrors(List<MigrationFile> files) async {
    final errors = <String>[];
    final byEntity = <MigrationEntity, MigrationFile>{
      for (final file in files) file.entity: file
    };
    Set<String> packageValues(MigrationEntity entity, String field) =>
        (byEntity[entity]?.rows ?? const <Map<String, String>>[])
            .map((r) => (r[field] ?? '').trim().toLowerCase())
            .where((v) => v.isNotEmpty)
            .toSet();

    final db = AppDatabase.instance.db;
    Future<Set<String>> dbValues(String table, String field,
        {String? where, List<Object?>? whereArgs}) async {
      final rows = await db.query(table,
          columns: [field], where: where, whereArgs: whereArgs);
      return rows
          .map((r) => '${r[field] ?? ''}'.trim().toLowerCase())
          .where((v) => v.isNotEmpty)
          .toSet();
    }

    final sales = {
      ...packageValues(MigrationEntity.sales, 'invoice_no'),
      ...await dbValues('sales', 'no')
    };
    final purchases = {
      ...packageValues(MigrationEntity.purchases, 'purchase_no'),
      ...await dbValues('purchases', 'no')
    };
    final salesReturns = {
      ...packageValues(MigrationEntity.salesReturns, 'return_no'),
      ...await dbValues('sales_returns', 'no')
    };
    final purchaseReturns = {
      ...packageValues(MigrationEntity.purchaseReturns, 'return_no'),
      ...await dbValues('purchase_returns', 'no')
    };
    final receiptIds = await dbValues('payments', 'id',
        where: 'document_type=?', whereArgs: ['Account Receipt']);
    final supplierPaymentIds = await dbValues('payments', 'id',
        where: 'document_type=?', whereArgs: ['Account Payment']);
    final packageReceipts =
        packageValues(MigrationEntity.customerReceipts, 'receipt_no');
    final packageSupplierPayments =
        packageValues(MigrationEntity.supplierPayments, 'payment_no');

    void checkRows(MigrationEntity child, String field, Set<String> allowed,
        String parentLabel,
        {bool optional = false}) {
      final file = byEntity[child];
      if (file == null) return;
      var shown = 0;
      for (var i = 0; i < file.rows.length; i++) {
        final raw = (file.rows[i][field] ?? '').trim();
        if (raw.isEmpty && optional) continue;
        if (raw.isEmpty || allowed.contains(raw.toLowerCase())) continue;
        if (shown < 30)
          errors.add(
              '${file.sourceName} row ${i + 2}: $field "$raw" has no matching $parentLabel. Import the parent/header file first or include it in the same Full Migration ZIP.');
        shown++;
      }
      if (shown > 30)
        errors.add(
            '${file.sourceName}: ${shown - 30} more missing $parentLabel reference(s).');
    }

    checkRows(MigrationEntity.saleItems, 'invoice_no', sales, 'sales invoice');
    checkRows(
        MigrationEntity.purchaseItems, 'purchase_no', purchases, 'purchase');
    checkRows(MigrationEntity.saleReturnItems, 'return_no', salesReturns,
        'sales return header');
    checkRows(MigrationEntity.purchaseReturnItems, 'return_no', purchaseReturns,
        'purchase return header');
    checkRows(
        MigrationEntity.salesReturns, 'invoice_no', sales, 'sales invoice',
        optional: true);
    checkRows(
        MigrationEntity.purchaseReturns, 'purchase_no', purchases, 'purchase',
        optional: true);

    final receiptAlloc = byEntity[MigrationEntity.customerReceiptAllocations];
    if (receiptAlloc != null) {
      var shown = 0;
      for (var i = 0; i < receiptAlloc.rows.length; i++) {
        final row = receiptAlloc.rows[i];
        final receipt = (row['receipt_no'] ?? '').trim();
        final invoice = (row['invoice_no'] ?? '').trim();
        final receiptExists = packageReceipts.contains(receipt.toLowerCase()) ||
            receiptIds.contains(_docId('CREC', receipt).toLowerCase());
        if (receipt.isNotEmpty && !receiptExists && shown < 30) {
          errors.add(
              '${receiptAlloc.sourceName} row ${i + 2}: receipt_no "$receipt" has no matching customer receipt.');
          shown++;
        }
        if (invoice.isNotEmpty &&
            !sales.contains(invoice.toLowerCase()) &&
            shown < 30) {
          errors.add(
              '${receiptAlloc.sourceName} row ${i + 2}: invoice_no "$invoice" has no matching sales invoice.');
          shown++;
        }
      }
    }
    final supplierAlloc = byEntity[MigrationEntity.supplierPaymentAllocations];
    if (supplierAlloc != null) {
      var shown = 0;
      for (var i = 0; i < supplierAlloc.rows.length; i++) {
        final row = supplierAlloc.rows[i];
        final payment = (row['payment_no'] ?? '').trim();
        final purchase = (row['purchase_no'] ?? '').trim();
        final paymentExists = packageSupplierPayments
                .contains(payment.toLowerCase()) ||
            supplierPaymentIds.contains(_docId('SPAY', payment).toLowerCase());
        if (payment.isNotEmpty && !paymentExists && shown < 30) {
          errors.add(
              '${supplierAlloc.sourceName} row ${i + 2}: payment_no "$payment" has no matching supplier payment.');
          shown++;
        }
        if (purchase.isNotEmpty &&
            !purchases.contains(purchase.toLowerCase()) &&
            shown < 30) {
          errors.add(
              '${supplierAlloc.sourceName} row ${i + 2}: purchase_no "$purchase" has no matching purchase.');
          shown++;
        }
      }
    }
    return errors;
  }

  static Future<MigrationRunResult> importOne(MigrationFile file,
      {void Function(int done, int total, String stage)? onProgress}) async {
    await AppDatabase.instance
        .requirePermission('migration', 'import migration data');
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.bulkTools);
    if (!file.valid) throw Exception(file.errors.join('\n'));
    final refs = await referenceErrors([file]);
    if (refs.isNotEmpty) throw Exception(refs.join('\n'));
    final result = await AppDatabase.instance.db
        .transaction((t) => _importFilesTx(t, [file], onProgress: onProgress));
    return MigrationRunResult(
        imported: result.$1,
        skipped: result.$2,
        warnings: result.$3,
        reconciliation: await reconciliation());
  }

  static Future<MigrationRunResult> importFull(List<MigrationFile> files,
      {void Function(int done, int total, String stage)? onProgress}) async {
    await AppDatabase.instance
        .requirePermission('migration', 'run a full business migration');
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.bulkTools);
    if (files.isEmpty || files.every((f) => f.rows.isEmpty)) {
      throw Exception(
          'No populated migration CSV files were found in the ZIP.');
    }
    final invalid = files.where((f) => !f.valid).toList();
    if (invalid.isNotEmpty) {
      throw Exception(invalid
          .map((f) => '${f.sourceName}: ${f.errors.join('; ')}')
          .join('\n'));
    }
    final packageValidation = packageErrors(files);
    if (packageValidation.isNotEmpty)
      throw Exception(packageValidation.join('\n'));
    final refs = await referenceErrors(files);
    if (refs.isNotEmpty) throw Exception(refs.join('\n'));
    final backupDir = Directory(
        p.join(await AppDatabase.instance.dataDir, 'migration_backups'));
    await backupDir.create(recursive: true);
    final backup = await AppDatabase.instance
        .backupTo(backupDir.path, enforcePermission: false);
    final ordered = [...files]
      ..sort((a, b) => _order(a.entity).compareTo(_order(b.entity)));
    final result = await AppDatabase.instance.db
        .transaction((t) => _importFilesTx(t, ordered, onProgress: onProgress));
    return MigrationRunResult(
        imported: result.$1,
        skipped: result.$2,
        warnings: result.$3,
        backupPath: backup,
        reconciliation: await reconciliation());
  }

  static Future<Map<String, num>> reconciliation() async {
    final db = AppDatabase.instance.db;
    Future<num> scalar(String sql) async {
      final rows = await db.rawQuery(sql);
      if (rows.isEmpty || rows.first.isEmpty) return 0;
      final v = rows.first.values.first;
      return v is num ? v : num.tryParse('$v') ?? 0;
    }

    return {
      'products': await scalar('SELECT COUNT(*) FROM products'),
      'customers': await scalar('SELECT COUNT(*) FROM customers'),
      'suppliers': await scalar('SELECT COUNT(*) FROM suppliers'),
      'sales': await scalar('SELECT COUNT(*) FROM sales'),
      'sales_total': await scalar('SELECT COALESCE(SUM(total),0) FROM sales'),
      'purchases': await scalar('SELECT COUNT(*) FROM purchases'),
      'purchases_total':
          await scalar('SELECT COALESCE(SUM(total),0) FROM purchases'),
      'customer_receivables':
          await scalar('SELECT COALESCE(SUM(balance),0) FROM customers'),
      'supplier_payables':
          await scalar('SELECT COALESCE(SUM(balance),0) FROM suppliers'),
      'stock_qty':
          await scalar('SELECT COALESCE(SUM(qty),0) FROM branch_stock'),
      'expenses_total': await scalar(
          "SELECT COALESCE(SUM(amount+tax_amount),0) FROM expenses WHERE status!='Voided'"),
    };
  }

  static Future<(int, int, List<String>)> _importFilesTx(
      DatabaseExecutor t, List<MigrationFile> files,
      {void Function(int done, int total, String stage)? onProgress}) async {
    final totalRows = files.fold<int>(0, (sum, file) => sum + file.rows.length);
    var processed = 0;
    final ctx = await AppDatabase.instance.operationalContext(t);
    var imported = 0;
    var skipped = 0;
    final warnings = <String>[];
    final clearedSaleItems = <String>{};
    final clearedPurchaseItems = <String>{};
    final clearedSaleReturnItems = <String>{};
    final clearedPurchaseReturnItems = <String>{};

    for (final file in files) {
      onProgress?.call(processed, totalRows, 'Importing ${file.entity.title}');
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < file.rows.length; i++) {
        final row = file.rows[i];
        try {
          switch (file.entity) {
            case MigrationEntity.products:
              await _importProduct(t, row, ctx);
              break;
            case MigrationEntity.customers:
              await _importCustomer(t, row);
              break;
            case MigrationEntity.suppliers:
              await _importSupplier(t, row);
              break;
            case MigrationEntity.sales:
              await _importSale(t, row, ctx);
              break;
            case MigrationEntity.saleItems:
              final id = _docId('SALE', _get(row, ['invoice_no']));
              if (clearedSaleItems.add(id))
                await t
                    .delete('sale_items', where: 'sale_id=?', whereArgs: [id]);
              await _importSaleItem(t, row, id);
              break;
            case MigrationEntity.purchases:
              await _importPurchase(t, row, ctx);
              break;
            case MigrationEntity.purchaseItems:
              final id = _docId('PUR', _get(row, ['purchase_no']));
              if (clearedPurchaseItems.add(id))
                await t.delete('purchase_items',
                    where: 'purchase_id=?', whereArgs: [id]);
              await _importPurchaseItem(t, row, id);
              break;
            case MigrationEntity.customerReceipts:
              await _importPartyPayment(t, row, ctx, customer: true);
              break;
            case MigrationEntity.customerReceiptAllocations:
              await _importAllocation(t, row, customer: true);
              break;
            case MigrationEntity.supplierPayments:
              await _importPartyPayment(t, row, ctx, customer: false);
              break;
            case MigrationEntity.supplierPaymentAllocations:
              await _importAllocation(t, row, customer: false);
              break;
            case MigrationEntity.expenses:
              await _importExpense(t, row, ctx);
              break;
            case MigrationEntity.salesReturns:
              await _importReturn(t, row, ctx, purchase: false);
              break;
            case MigrationEntity.saleReturnItems:
              final id = _docId('SRET', _get(row, ['return_no']));
              if (clearedSaleReturnItems.add(id))
                await t.delete('sale_return_items',
                    where: 'return_id=?', whereArgs: [id]);
              await _importReturnItem(t, row, id, purchase: false);
              break;
            case MigrationEntity.purchaseReturns:
              await _importReturn(t, row, ctx, purchase: true);
              break;
            case MigrationEntity.purchaseReturnItems:
              final id = _docId('PRET', _get(row, ['return_no']));
              if (clearedPurchaseReturnItems.add(id))
                await t.delete('purchase_return_items',
                    where: 'return_id=?', whereArgs: [id]);
              await _importReturnItem(t, row, id, purchase: true);
              break;
            case MigrationEntity.stockAdjustments:
              await _importStockAdjustment(t, row, ctx);
              break;
          }
          imported++;
        } catch (e) {
          // Financial migrations must be atomic. Do not commit successful
          // rows if a later row fails: rethrow to roll back the transaction.
          throw Exception(
              '${file.sourceName} row ${i + 2}: ${e.toString().replaceFirst('Exception: ', '')}');
        }
        processed++;
        if (processed % 100 == 0 || processed == totalRows) {
          onProgress?.call(
              processed, totalRows, 'Importing ${file.entity.title}');
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    return (imported, skipped, warnings);
  }

  static Future<void> _importProduct(DatabaseExecutor t, Map<String, String> r,
      Map<String, String> ctx) async {
    final name = _required(r, ['product_name'], 'Product name');

    // product_code is the migration/reference identity while sku is the value
    // written to products.sku. Older imports only looked up `code` before an
    // insert. When product_code and sku differed, an already-existing SKU could
    // therefore be missed and SQLite would abort with products.sku UNIQUE.
    final productCode = _get(r, ['product_code']).trim();
    final suppliedSku = _get(r, ['sku']).trim();
    final sku = suppliedSku.isNotEmpty ? suppliedSku : productCode;
    final code = productCode.isNotEmpty ? productCode : sku;
    final barcode = _get(r, ['barcode']).trim();

    String? id;
    if (sku.isNotEmpty) {
      final bySku = await t.query(
        'products',
        columns: ['id'],
        where: 'LOWER(TRIM(sku))=LOWER(?)',
        whereArgs: [sku],
        limit: 1,
      );
      if (bySku.isNotEmpty) id = bySku.first['id']?.toString();
    }

    id ??= await _resolveProductId(
      t,
      code,
      barcode,
      name,
      createIfMissing: false,
    );
    id ??= _stableId(
      'MIG-P',
      code.isNotEmpty ? code : (sku.isNotEmpty ? sku : name),
    );

    final now = DateTime.now().toIso8601String();
    final category =
        _get(r, ['category']).isEmpty ? 'General' : _get(r, ['category']);
    final unit = _get(r, ['unit']).isEmpty ? 'pcs' : _get(r, ['unit']);
    final rawType = _get(r, ['product_type']).trim();
    final lowerType = rawType.toLowerCase();
    final productType = lowerType == 'service'
        ? 'Service'
        : (lowerType == 'non-stocked' ||
                lowerType == 'non stocked' ||
                lowerType == 'nonstocked' ||
                lowerType == 'non-stock')
            ? 'Non-stocked'
            : lowerType == 'recipe'
                ? 'Recipe'
                : (lowerType == 'combo' || lowerType == 'bundle')
                    ? 'Combo'
                    : 'Stocked';
    final currentStock = productType == 'Stocked'
        ? _num(r, ['current_stock', 'opening_stock', 'stock'])
        : 0.0;
    final values = <String, Object?>{
      'id': id,
      'sku': _null(sku),
      'external_barcode': _null(barcode),
      'name': name,
      'category': category,
      'unit': unit,
      'cost': _num(r, ['purchase_price', 'cost']),
      'price': _num(r, ['selling_price', 'price']),
      'min_stock': _num(r, ['minimum_stock', 'min_stock']),
      'target_stock': _num(r, ['target_stock']),
      'stock': currentStock,
      'location': _null(_get(r, ['location'])),
      'supplier': _null(_get(r, ['supplier'])),
      'active': _boolInt(_get(r, ['active']), fallback: true),
      'created_at': now,
      'updated_at': now,
      'product_type': productType,
      'track_batch': _boolInt(_get(r, ['track_batch'])),
      'track_expiry': _boolInt(_get(r, ['track_expiry'])),
      'tax_code':
          _get(r, ['tax_code']).isEmpty ? 'NONE' : _get(r, ['tax_code']),
      'tax_inclusive': _boolInt(_get(r, ['tax_inclusive'])),
      'purchase_moq': _num(r, ['purchase_moq']),
      'order_multiple': _num(r, ['order_multiple'], fallback: 1),
      'case_pack': _num(r, ['case_pack'], fallback: 1),
      'sellable': _boolInt(_get(r, ['sellable']), fallback: true),
      'purchasable': _boolInt(_get(r, ['purchasable']), fallback: true),
      'lifecycle_status': _get(r, ['lifecycle_status']).isEmpty
          ? 'Active'
          : _get(r, ['lifecycle_status']),
      'replacement_product_id': null,
      'demand_family': _null(_get(r, ['demand_family'])),
      'inherit_predecessor_history':
          _boolInt(_get(r, ['inherit_predecessor_history']), fallback: true),
    };
    final exists = await t.query('products',
        columns: ['id'], where: 'id=?', whereArgs: [id], limit: 1);
    if (exists.isEmpty) {
      await t.insert('products', values,
          conflictAlgorithm: ConflictAlgorithm.abort);
    } else {
      final update = Map<String, Object?>.from(values)
        ..remove('id')
        ..remove('created_at');
      // Blank identifiers in a correction/import file should not erase a
      // working identifier already attached to the matched product.
      if (sku.isEmpty) update.remove('sku');
      if (barcode.isEmpty) update.remove('external_barcode');
      await t.update('products', update, where: 'id=?', whereArgs: [id]);
    }
    await t.insert('product_categories', {'name': category, 'active': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await t.insert('product_units', {'name': unit, 'active': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final branch = ctx['branch_id'];
    if (branch != null && branch.isNotEmpty) {
      await t.insert('branch_stock',
          {'product_id': id, 'branch_id': branch, 'qty': currentStock},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await t.delete('stock_lots',
          where:
              "product_id=? AND branch_id=? AND batch_no='MIGRATION-OPENING'",
          whereArgs: [id, branch]);
      if (currentStock > 0) {
        await t.insert(
            'stock_lots',
            {
              'id': _stableId('MIG-LOT', '$id|$branch'),
              'product_id': id,
              'branch_id': branch,
              'purchase_item_id': null,
              'batch_no': 'MIGRATION-OPENING',
              'expiry_date': null,
              'received_qty': currentStock,
              'remaining_qty': currentStock,
              'unit_cost': values['cost'],
              'created_at': now,
              'status': 'Open'
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  static Future<void> _importCustomer(
      DatabaseExecutor t, Map<String, String> r) async {
    final name = _required(r, ['customer_name'], 'Customer name');
    final code = _get(r, ['customer_code']);
    final id = _stableId('MIG-C', code.isNotEmpty ? code : name);
    final values = <String, Object?>{
      'id': id,
      'name': name,
      'phone': _null(_get(r, ['phone'])),
      'whatsapp': _null(_get(r, ['whatsapp', 'phone'])),
      'email': _null(_get(r, ['email'])),
      'contact': _null(_get(r, ['contact'])),
      'address': _null(_get(r, ['address'])),
      'credit_allowed': _boolInt(_get(r, ['credit_allowed'])),
      'credit_limit': _num(r, ['credit_limit']),
      'terms_days': _num(r, ['terms_days']).round(),
      'active': _boolInt(_get(r, ['active']), fallback: true),
      'balance': _num(r, ['current_balance', 'balance']),
      'credit_balance': _num(r, ['credit_balance']),
      'group_id': _null(_get(r, ['group_id']))
    };
    await t.insert('customers', values,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importSupplier(
      DatabaseExecutor t, Map<String, String> r) async {
    final name = _required(r, ['supplier_name'], 'Supplier name');
    final code = _get(r, ['supplier_code']);
    final id = _stableId('MIG-SUP', code.isNotEmpty ? code : name);
    final values = <String, Object?>{
      'id': id,
      'name': name,
      'phone': _null(_get(r, ['phone'])),
      'whatsapp': _null(_get(r, ['whatsapp', 'phone'])),
      'email': _null(_get(r, ['email'])),
      'contact': _null(_get(r, ['contact'])),
      'address': _null(_get(r, ['address'])),
      'lead_days': _num(r, ['lead_days']).round(),
      'terms_days': _num(r, ['terms_days']).round(),
      'active': _boolInt(_get(r, ['active']), fallback: true),
      'balance': _num(r, ['current_balance', 'balance']),
      'min_order_value': _num(r, ['minimum_order_value', 'min_order_value']),
      'credit_balance': _num(r, ['credit_balance'])
    };
    await t.insert('suppliers', values,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importSale(DatabaseExecutor t, Map<String, String> r,
      Map<String, String> ctx) async {
    final no = _required(r, ['invoice_no'], 'Invoice number');
    final customerId =
        await _resolvePartyId(t, _get(r, ['customer_code']), customer: true);
    final total = _num(r, ['total']);
    final paid = _num(r, ['paid']);
    final balance = r['balance']?.trim().isNotEmpty == true
        ? _num(r, ['balance'])
        : (total - paid).clamp(0, double.infinity).toDouble();
    await t.insert(
        'sales',
        {
          'id': _docId('SALE', no),
          'no': no,
          'created_at': _date(_get(r, ['invoice_date'])),
          'due_date': _nullableDate(_get(r, ['due_date'])),
          'customer_id': customerId,
          'subtotal': _num(r, ['subtotal'], fallback: total),
          'discount': _num(r, ['discount']),
          'tax': _num(r, ['tax']),
          'delivery_charge': _num(r, ['delivery_charge']),
          'other_charge': _num(r, ['other_charge']),
          'total': total,
          'paid': paid,
          'balance': balance,
          'returned_total': 0.0,
          'refunded_total': 0.0,
          'payment_method': _get(r, ['payment_method']).isEmpty
              ? 'Cash'
              : _get(r, ['payment_method']),
          'status': _get(r, ['status']).isEmpty
              ? (balance > 0 ? 'Credit' : 'Completed')
              : _get(r, ['status']),
          'notes': _null(_get(r, ['notes'])),
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id'],
          'revision': 0
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importSaleItem(
      DatabaseExecutor t, Map<String, String> r, String saleId) async {
    final sale = await t.query('sales',
        columns: ['id'], where: 'id=?', whereArgs: [saleId], limit: 1);
    if (sale.isEmpty)
      throw Exception(
          'Sale header was not found for ${_get(r, ['invoice_no'])}.');
    final code = _get(r, ['product_code']);
    final name = _get(r, ['product_name']);
    final productId =
        await _resolveProductId(t, code, '', name, createIfMissing: false);
    final qty = _num(r, ['quantity', 'qty']);
    if (qty == 0) throw Exception('Quantity cannot be zero.');
    final price = _num(r, ['unit_price', 'rate']);
    final lineTotal = r['line_total']?.trim().isNotEmpty == true
        ? _num(r, ['line_total'])
        : qty * price - _num(r, ['discount']) + _num(r, ['tax']);
    await t.insert('sale_items', {
      'sale_id': saleId,
      'product_id': productId,
      'name': name.isEmpty ? (code.isEmpty ? 'Imported item' : code) : name,
      'qty': qty,
      'unit_price': price,
      'discount': _num(r, ['discount']),
      'cost': _num(r, ['cost_price', 'cost']),
      'tax': _num(r, ['tax']),
      'tax_inclusive': 0,
      'line_total': lineTotal
    });
  }

  static Future<void> _importPurchase(DatabaseExecutor t, Map<String, String> r,
      Map<String, String> ctx) async {
    final no = _required(r, ['purchase_no'], 'Purchase number');
    final supplierId =
        await _resolvePartyId(t, _get(r, ['supplier_code']), customer: false);
    final total = _num(r, ['total']);
    final paid = _num(r, ['paid']);
    final balance = r['balance']?.trim().isNotEmpty == true
        ? _num(r, ['balance'])
        : (total - paid).clamp(0, double.infinity).toDouble();
    await t.insert(
        'purchases',
        {
          'id': _docId('PUR', no),
          'no': no,
          'created_at': _date(_get(r, ['purchase_date'])),
          'due_date': _nullableDate(_get(r, ['due_date'])),
          'supplier_id': supplierId,
          'document_no': _null(_get(r, ['supplier_invoice_no'])),
          'subtotal': _num(r, ['subtotal'], fallback: total),
          'discount': _num(r, ['discount']),
          'tax': _num(r, ['tax']),
          'freight': _num(r, ['freight']),
          'other_charges': _num(r, ['other_charges']),
          'total': total,
          'paid': paid,
          'balance': balance,
          'payment_method': _get(r, ['payment_method']).isEmpty
              ? 'Cash'
              : _get(r, ['payment_method']),
          'status': _get(r, ['status']).isEmpty
              ? (balance > 0 ? 'Partially Paid' : 'Received')
              : _get(r, ['status']),
          'notes': _null(_get(r, ['notes'])),
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id'],
          'revision': 0
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importPurchaseItem(
      DatabaseExecutor t, Map<String, String> r, String purchaseId) async {
    final header = await t.query('purchases',
        columns: ['id'], where: 'id=?', whereArgs: [purchaseId], limit: 1);
    if (header.isEmpty)
      throw Exception(
          'Purchase header was not found for ${_get(r, ['purchase_no'])}.');
    final code = _get(r, ['product_code']);
    final name = _get(r, ['product_name']);
    final productId =
        await _resolveProductId(t, code, '', name, createIfMissing: false);
    final qty = _num(r, ['quantity', 'qty']);
    if (qty == 0) throw Exception('Quantity cannot be zero.');
    final cost = _num(r, ['unit_cost', 'purchase_price', 'cost']);
    final lineTotal = r['line_total']?.trim().isNotEmpty == true
        ? _num(r, ['line_total'])
        : qty * cost - _num(r, ['discount']) + _num(r, ['tax']);
    await t.insert('purchase_items', {
      'purchase_id': purchaseId,
      'product_id': productId,
      'name': name.isEmpty ? (code.isEmpty ? 'Imported item' : code) : name,
      'qty': qty,
      'unit_cost': cost,
      'discount': _num(r, ['discount']),
      'tax': _num(r, ['tax']),
      'tax_inclusive': 0,
      'line_total': lineTotal,
      'batch_no': _null(_get(r, ['batch_no'])),
      'expiry_date': _nullableDate(_get(r, ['expiry_date'])),
      'purchase_order_item_id': null
    });
  }

  static Future<void> _importPartyPayment(
      DatabaseExecutor t, Map<String, String> r, Map<String, String> ctx,
      {required bool customer}) async {
    final no = _required(r, [customer ? 'receipt_no' : 'payment_no'],
        customer ? 'Receipt number' : 'Payment number');
    final code = _get(r, [customer ? 'customer_code' : 'supplier_code']);
    final partyId = await _resolvePartyId(t, code, customer: customer);
    if (partyId == null && code.isNotEmpty)
      throw Exception(
          '${customer ? 'Customer' : 'Supplier'} "$code" was not found.');
    final amount = _num(r, ['amount']);
    if (amount <= 0)
      throw Exception('Payment amount must be greater than zero.');
    final id = _docId(customer ? 'CREC' : 'SPAY', no);
    await t.insert(
        'payments',
        {
          'id': id,
          'created_at': _date(_get(r, ['date'])),
          'party_type': customer ? 'Customer' : 'Supplier',
          'party_id': partyId,
          'document_type': customer ? 'Account Receipt' : 'Account Payment',
          'document_id': '',
          'amount': amount,
          'method': _get(r, ['payment_method']).isEmpty
              ? 'Cash'
              : _get(r, ['payment_method']),
          'reference':
              _get(r, ['reference']).isEmpty ? no : _get(r, ['reference']),
          'notes': _null(_get(r, ['notes'])),
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importAllocation(
      DatabaseExecutor t, Map<String, String> r,
      {required bool customer}) async {
    final paymentNo = _required(r, [customer ? 'receipt_no' : 'payment_no'],
        customer ? 'Receipt number' : 'Payment number');
    final docNo = _required(r, [customer ? 'invoice_no' : 'purchase_no'],
        customer ? 'Invoice number' : 'Purchase number');
    final paymentId = _docId(customer ? 'CREC' : 'SPAY', paymentNo);
    final docId = _docId(customer ? 'SALE' : 'PUR', docNo);
    final amount = _num(r, ['allocated_amount']);
    if (amount <= 0)
      throw Exception('Allocated amount must be greater than zero.');
    final payment = await t.query('payments',
        columns: ['id'], where: 'id=?', whereArgs: [paymentId], limit: 1);
    final doc = await t.query(customer ? 'sales' : 'purchases',
        columns: ['id'], where: 'id=?', whereArgs: [docId], limit: 1);
    if (payment.isEmpty) throw Exception('Payment $paymentNo was not found.');
    if (doc.isEmpty)
      throw Exception(
          '${customer ? 'Invoice' : 'Purchase'} $docNo was not found.');
    await t.delete('payment_allocations',
        where: 'payment_id=? AND document_type=? AND document_id=?',
        whereArgs: [paymentId, customer ? 'Sale' : 'Purchase', docId]);
    await t.insert('payment_allocations', {
      'payment_id': paymentId,
      'document_type': customer ? 'Sale' : 'Purchase',
      'document_id': docId,
      'allocated_amount': amount,
      'created_at': DateTime.now().toIso8601String()
    });
  }

  static Future<void> _importExpense(DatabaseExecutor t, Map<String, String> r,
      Map<String, String> ctx) async {
    final desc = _required(r, ['description'], 'Description');
    final source = _get(r, ['expense_no', 'reference']);
    final id = _stableId(
        'MIG-EXP',
        source.isNotEmpty
            ? source
            : '${_get(r, ['date'])}|$desc|${_get(r, ['amount'])}');
    await t.insert(
        'expenses',
        {
          'id': id,
          'expense_date': _date(_get(r, ['date'])),
          'category':
              _get(r, ['category']).isEmpty ? 'Other' : _get(r, ['category']),
          'description': desc,
          'amount': _num(r, ['amount']),
          'tax_amount': _num(r, ['tax_amount']),
          'tax_code':
              _get(r, ['tax_code']).isEmpty ? 'NONE' : _get(r, ['tax_code']),
          'payment_method': _get(r, ['payment_method']).isEmpty
              ? 'Cash'
              : _get(r, ['payment_method']),
          'reference_no': _null(_get(r, ['reference', 'expense_no'])),
          'notes': _null(_get(r, ['notes'])),
          'status': 'Active',
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importReturn(
      DatabaseExecutor t, Map<String, String> r, Map<String, String> ctx,
      {required bool purchase}) async {
    final no = _required(r, ['return_no'], 'Return number');
    final partyId = await _resolvePartyId(
        t, _get(r, [purchase ? 'supplier_code' : 'customer_code']),
        customer: !purchase);
    final sourceNo = _get(r, [purchase ? 'purchase_no' : 'invoice_no']);
    final id = _docId(purchase ? 'PRET' : 'SRET', no);
    await t.insert(
        purchase ? 'purchase_returns' : 'sales_returns',
        {
          'id': id,
          'no': no,
          (purchase ? 'purchase_id' : 'sale_id'): sourceNo.isEmpty
              ? null
              : _docId(purchase ? 'PUR' : 'SALE', sourceNo),
          'party_id': partyId,
          'source_reference': sourceNo,
          'created_at': _date(_get(r, ['date'])),
          'total': _num(r, ['total']),
          'refund_amount': _num(r, ['refund_amount']),
          'refund_method': _get(r, ['refund_method']).isEmpty
              ? (purchase ? 'Supplier Credit' : 'Cash')
              : _get(r, ['refund_method']),
          'status': 'Posted',
          'notes': _null(_get(r, ['notes'])),
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _importReturnItem(
      DatabaseExecutor t, Map<String, String> r, String returnId,
      {required bool purchase}) async {
    final table = purchase ? 'purchase_returns' : 'sales_returns';
    final header = await t.query(table,
        columns: ['id'], where: 'id=?', whereArgs: [returnId], limit: 1);
    if (header.isEmpty)
      throw Exception(
          'Return header was not found for ${_get(r, ['return_no'])}.');
    final code = _get(r, ['product_code']);
    final name = _get(r, ['product_name']);
    final productId =
        await _resolveProductId(t, code, '', name, createIfMissing: false);
    final qty = _num(r, ['quantity']);
    final unit = _num(r, [purchase ? 'unit_cost' : 'unit_price']);
    final values = <String, Object?>{
      'return_id': returnId,
      (purchase ? 'purchase_item_id' : 'sale_item_id'): null,
      'product_id': productId,
      'name': name.isEmpty ? (code.isEmpty ? 'Imported item' : code) : name,
      'qty': qty,
      (purchase ? 'unit_cost' : 'unit_price'): unit,
      'discount': _num(r, ['discount']),
      'tax': _num(r, ['tax']),
      'line_total': r['line_total']?.trim().isNotEmpty == true
          ? _num(r, ['line_total'])
          : qty * unit
    };
    if (!purchase) values['cost'] = _num(r, ['cost_price']);
    await t.insert(
        purchase ? 'purchase_return_items' : 'sale_return_items', values);
  }

  static Future<void> _importStockAdjustment(DatabaseExecutor t,
      Map<String, String> r, Map<String, String> ctx) async {
    final code = _required(r, ['product_code'], 'Product code');
    final productId =
        await _resolveProductId(t, code, '', '', createIfMissing: false);
    if (productId == null) throw Exception('Product "$code" was not found.');
    final change = _num(r, ['quantity_change']);
    if (change == 0) throw Exception('Quantity change cannot be zero.');
    final branch = ctx['branch_id'];
    if (branch == null || branch.isEmpty)
      throw Exception('No active branch is configured.');
    final rows = await t.query('branch_stock',
        columns: ['qty'],
        where: 'product_id=? AND branch_id=?',
        whereArgs: [productId, branch],
        limit: 1);
    final current =
        rows.isEmpty ? 0.0 : (rows.first['qty'] as num? ?? 0).toDouble();
    final next = current + change;
    if (next < 0) throw Exception('Adjustment would make stock negative.');
    await t.insert('branch_stock',
        {'product_id': productId, 'branch_id': branch, 'qty': next},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await t.update('products',
        {'stock': next, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id=?', whereArgs: [productId]);
    await t.insert('stock_movements', {
      'created_at': _date(_get(r, ['date'])),
      'product_id': productId,
      'qty_change': change,
      'type': 'Migration Adjustment',
      'reference': _get(r, ['adjustment_no']),
      'reason': _get(r, ['reason']).isEmpty
          ? 'Imported stock adjustment'
          : _get(r, ['reason']),
      'branch_id': branch,
      'terminal_id': ctx['terminal_id'],
      'user_id': ctx['user_id']
    });
  }

  static Future<String?> _resolvePartyId(DatabaseExecutor t, String code,
      {required bool customer}) async {
    if (code.trim().isEmpty) return null;
    final stable = _stableId(customer ? 'MIG-C' : 'MIG-SUP', code);
    final table = customer ? 'customers' : 'suppliers';
    final byId = await t.query(table,
        columns: ['id'], where: 'id=?', whereArgs: [stable], limit: 1);
    if (byId.isNotEmpty) return stable;
    final byName = await t.query(table,
        columns: ['id'],
        where: 'LOWER(name)=LOWER(?)',
        whereArgs: [code.trim()],
        limit: 1);
    return byName.isEmpty ? null : byName.first['id']?.toString();
  }

  static Future<String?> _resolveProductId(
      DatabaseExecutor t, String code, String barcode, String name,
      {required bool createIfMissing}) async {
    if (code.trim().isNotEmpty) {
      final stable = _stableId('MIG-P', code);
      final byId = await t.query('products',
          columns: ['id'], where: 'id=?', whereArgs: [stable], limit: 1);
      if (byId.isNotEmpty) return stable;
      final byCode = await t.query('products',
          columns: ['id'],
          where: 'LOWER(sku)=LOWER(?)',
          whereArgs: [code.trim()],
          limit: 1);
      if (byCode.isNotEmpty) return byCode.first['id']?.toString();
    }
    if (barcode.trim().isNotEmpty) {
      final rows = await t.query('products',
          columns: ['id'],
          where: 'external_barcode=? OR internal_barcode=?',
          whereArgs: [barcode.trim(), barcode.trim()],
          limit: 1);
      if (rows.isNotEmpty) return rows.first['id']?.toString();
    }
    if (name.trim().isNotEmpty) {
      final rows = await t.query('products',
          columns: ['id'],
          where: 'LOWER(name)=LOWER(?)',
          whereArgs: [name.trim()],
          limit: 1);
      if (rows.isNotEmpty) return rows.first['id']?.toString();
    }
    if (!createIfMissing) return null;
    return _stableId('MIG-P',
        code.isNotEmpty ? code : (barcode.isNotEmpty ? barcode : name));
  }

  static List<String> _validateRows(
      MigrationEntity entity, List<Map<String, String>> rows) {
    final errors = <String>[];
    const maxDetailedErrors = 100;
    var suppressed = 0;
    void add(int rowIndex, String message) {
      if (errors.length < maxDetailedErrors) {
        errors.add('Row ${rowIndex + 2}: $message');
      } else {
        suppressed++;
      }
    }

    final required = requiredHeaders[entity] ?? const <String>[];
    final dateFields = switch (entity) {
      MigrationEntity.sales => const ['invoice_date', 'due_date'],
      MigrationEntity.purchases => const ['purchase_date', 'due_date'],
      MigrationEntity.customerReceipts ||
      MigrationEntity.supplierPayments ||
      MigrationEntity.expenses ||
      MigrationEntity.salesReturns ||
      MigrationEntity.purchaseReturns ||
      MigrationEntity.stockAdjustments =>
        const ['date'],
      MigrationEntity.purchaseItems => const ['expiry_date'],
      _ => const <String>[],
    };
    final numericFields = switch (entity) {
      MigrationEntity.products => const [
          'purchase_price',
          'selling_price',
          'current_stock',
          'minimum_stock',
          'target_stock',
          'purchase_moq',
          'order_multiple',
          'case_pack'
        ],
      MigrationEntity.customers => const [
          'credit_limit',
          'terms_days',
          'current_balance',
          'credit_balance'
        ],
      MigrationEntity.suppliers => const [
          'lead_days',
          'terms_days',
          'current_balance',
          'credit_balance',
          'minimum_order_value'
        ],
      MigrationEntity.sales => const [
          'subtotal',
          'discount',
          'tax',
          'delivery_charge',
          'other_charge',
          'total',
          'paid',
          'balance'
        ],
      MigrationEntity.saleItems => const [
          'quantity',
          'unit_price',
          'discount',
          'tax',
          'cost_price',
          'line_total'
        ],
      MigrationEntity.purchases => const [
          'subtotal',
          'discount',
          'tax',
          'freight',
          'other_charges',
          'total',
          'paid',
          'balance'
        ],
      MigrationEntity.purchaseItems => const [
          'quantity',
          'unit_cost',
          'discount',
          'tax',
          'line_total'
        ],
      MigrationEntity.customerReceipts ||
      MigrationEntity.supplierPayments =>
        const ['amount'],
      MigrationEntity.customerReceiptAllocations ||
      MigrationEntity.supplierPaymentAllocations =>
        const ['allocated_amount'],
      MigrationEntity.expenses => const ['amount', 'tax_amount'],
      MigrationEntity.salesReturns || MigrationEntity.purchaseReturns => const [
          'total',
          'refund_amount'
        ],
      MigrationEntity.saleReturnItems => const [
          'quantity',
          'unit_price',
          'discount',
          'tax',
          'cost_price',
          'line_total'
        ],
      MigrationEntity.purchaseReturnItems => const [
          'quantity',
          'unit_cost',
          'discount',
          'tax',
          'line_total'
        ],
      MigrationEntity.stockAdjustments => const ['quantity_change'],
    };
    final uniqueField = switch (entity) {
      MigrationEntity.sales => 'invoice_no',
      MigrationEntity.purchases => 'purchase_no',
      MigrationEntity.customerReceipts => 'receipt_no',
      MigrationEntity.supplierPayments => 'payment_no',
      MigrationEntity.salesReturns ||
      MigrationEntity.purchaseReturns =>
        'return_no',
      _ => null,
    };
    final seen = <String>{};
    final seenProductCodes = <String>{};
    final seenProductSkus = <String>{};

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      for (final field in required) {
        if ((row[field] ?? '').trim().isEmpty) add(i, '$field is required.');
      }
      for (final field in dateFields) {
        final raw = (row[field] ?? '').trim();
        if (raw.isNotEmpty && _tryParseMigrationDate(raw) == null) {
          add(i, 'Invalid $field "$raw". Use YYYY-MM-DD or DD/MM/YYYY.');
        }
      }
      for (final field in numericFields) {
        final raw = (row[field] ?? '').trim();
        if (raw.isEmpty) continue;
        if (double.tryParse(raw.replaceAll(',', '')) == null)
          add(i, '$field must be a valid number (found "$raw").');
      }
      if (uniqueField != null) {
        final key = (row[uniqueField] ?? '').trim().toLowerCase();
        if (key.isNotEmpty && !seen.add(key))
          add(i, 'Duplicate $uniqueField "${row[uniqueField]}" in this file.');
      }
      if (entity == MigrationEntity.products) {
        final productCode = (row['product_code'] ?? '').trim();
        final suppliedSku = (row['sku'] ?? '').trim();
        final effectiveSku = suppliedSku.isNotEmpty ? suppliedSku : productCode;
        final codeKey = productCode.toLowerCase();
        final skuKey = effectiveSku.toLowerCase();
        if (codeKey.isNotEmpty && !seenProductCodes.add(codeKey)) {
          add(i, 'Duplicate product_code "$productCode" in this file.');
        }
        if (skuKey.isNotEmpty && !seenProductSkus.add(skuKey)) {
          add(i,
              'Duplicate SKU "$effectiveSku" in this file. Each product row must use a unique SKU.');
        }
      }

      double? number(String field) {
        final raw = (row[field] ?? '').trim();
        return raw.isEmpty ? null : double.tryParse(raw.replaceAll(',', ''));
      }

      if (entity == MigrationEntity.customerReceipts ||
          entity == MigrationEntity.supplierPayments ||
          entity == MigrationEntity.expenses) {
        final amount = number('amount');
        if (amount != null && amount <= 0)
          add(i, 'amount must be greater than zero.');
      }
      if (entity == MigrationEntity.customerReceiptAllocations ||
          entity == MigrationEntity.supplierPaymentAllocations) {
        final amount = number('allocated_amount');
        if (amount != null && amount <= 0)
          add(i, 'allocated_amount must be greater than zero.');
      }
      if (entity == MigrationEntity.saleItems ||
          entity == MigrationEntity.purchaseItems ||
          entity == MigrationEntity.saleReturnItems ||
          entity == MigrationEntity.purchaseReturnItems) {
        final qty = number('quantity');
        if (qty != null && qty <= 0)
          add(i, 'quantity must be greater than zero.');
      }
      if (entity == MigrationEntity.stockAdjustments) {
        final qty = number('quantity_change');
        if (qty != null && qty == 0) add(i, 'quantity_change cannot be zero.');
      }
      if (entity == MigrationEntity.sales ||
          entity == MigrationEntity.purchases ||
          entity == MigrationEntity.salesReturns ||
          entity == MigrationEntity.purchaseReturns) {
        final total = number('total');
        if (total != null && total < 0) add(i, 'total cannot be negative.');
      }
    }
    if (suppressed > 0)
      errors.add(
          '...and $suppressed more row validation error(s). Fix the first errors and validate again.');
    return errors;
  }

  static DateTime? _tryParseMigrationDate(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return null;
    final direct = DateTime.tryParse(clean);
    if (direct != null) return direct;

    final serial = double.tryParse(clean);
    if (serial != null && serial >= 1 && serial < 100000) {
      return DateTime(1899, 12, 30).add(Duration(
          milliseconds: (serial * Duration.millisecondsPerDay).round()));
    }

    final match = RegExp(
            r'^(\d{1,4})[\/\.\-](\d{1,2})[\/\.\-](\d{1,4})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$')
        .firstMatch(clean);
    if (match == null) return null;
    var a = int.tryParse(match.group(1)!);
    final b = int.tryParse(match.group(2)!);
    var c = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4) ?? '0') ?? 0;
    final minute = int.tryParse(match.group(5) ?? '0') ?? 0;
    final second = int.tryParse(match.group(6) ?? '0') ?? 0;
    if (a == null ||
        b == null ||
        c == null ||
        hour > 23 ||
        minute > 59 ||
        second > 59) return null;
    int year, month, day;
    if (a > 31) {
      year = a;
      month = b;
      day = c;
    } else {
      year = c;
      if (b > 12 && a <= 12) {
        month = a;
        day = b;
      } else {
        day = a;
        month = b;
      } // Ambiguous numeric dates default to day-first.
    }
    if (year < 100) year += 2000;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final value = DateTime(year, month, day, hour, minute, second);
    if (value.year != year ||
        value.month != month ||
        value.day != day ||
        value.hour != hour ||
        value.minute != minute ||
        value.second != second) return null;
    return value;
  }

  static int _order(MigrationEntity e) => switch (e) {
        MigrationEntity.products => 10,
        MigrationEntity.customers => 20,
        MigrationEntity.suppliers => 30,
        MigrationEntity.sales => 40,
        MigrationEntity.saleItems => 41,
        MigrationEntity.purchases => 50,
        MigrationEntity.purchaseItems => 51,
        MigrationEntity.customerReceipts => 60,
        MigrationEntity.supplierPayments => 61,
        MigrationEntity.customerReceiptAllocations => 70,
        MigrationEntity.supplierPaymentAllocations => 71,
        MigrationEntity.expenses => 80,
        MigrationEntity.salesReturns => 90,
        MigrationEntity.saleReturnItems => 91,
        MigrationEntity.purchaseReturns => 92,
        MigrationEntity.purchaseReturnItems => 93,
        MigrationEntity.stockAdjustments => 100,
      };

  static String _templateText(MigrationEntity entity) {
    // Never ship fictional business transactions inside an importable CSV.
    // A user who imports an untouched template must not create fake invoices,
    // receipts, products, suppliers, or stock movements.
    final columns = headers[entity]!;
    return '${columns.map(_csvCell).join(',')}\n';
  }

  static const String _templateReadme =
      '''RELIQ MIGRATION TEMPLATE PACK\n\n1. You may import each CSV separately from Migration Center.\n2. Or fill multiple CSV files, place them in one ZIP, and use Full Business Migration.\n3. Keep document numbers unique. Related item/allocation files link by document number.\n4. Products use selling_price for the retail/selling price and purchase_price for cost.\n5. current_stock, customer current_balance, and supplier current_balance are treated as the CURRENT closing values. Historical invoices are imported for history and reporting and do not re-apply those balances/stock.\n6. Full migration creates an automatic database backup before committing records.\n7. Unknown extra columns are ignored; common alternative column names are mapped per migration type.\n8. Dates accept YYYY-MM-DD, DD/MM/YYYY, DD-MM-YYYY, timestamps and Excel serial dates.\n9. Full Migration validates linked invoice/purchase/payment/return references before importing.\n10. Templates contain headings only. Add real business rows; untouched templates are skipped.\n11. Imports are atomic: if a row fails, all changes in that import are rolled back.\n''';

  static String _decodeCsvBytes(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2)
        units.add(bytes[i] | (bytes[i + 1] << 8));
      return String.fromCharCodes(units);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2)
        units.add((bytes[i] << 8) | bytes[i + 1]);
      return String.fromCharCodes(units);
    }
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) start = 3;
    final body = bytes.sublist(start);
    try {
      return utf8.decode(body);
    } catch (_) {
      return latin1.decode(body, allowInvalid: true);
    }
  }

  static String _detectDelimiter(String text) {
    final firstLine = text
        .split(RegExp(r'[\r\n]'))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    final counts = <String, int>{',': 0, ';': 0, '\t': 0};
    var quoted = false;
    for (var i = 0; i < firstLine.length; i++) {
      final ch = firstLine[i];
      if (ch == '"') {
        if (quoted && i + 1 < firstLine.length && firstLine[i + 1] == '"') {
          i++;
          continue;
        }
        quoted = !quoted;
      } else if (!quoted && counts.containsKey(ch)) {
        counts[ch] = counts[ch]! + 1;
      }
    }
    var delimiter = ',';
    for (final entry in counts.entries)
      if (entry.value > counts[delimiter]!) delimiter = entry.key;
    return delimiter;
  }

  static List<List<String>> _readCsv(String text) {
    final delimiter = _detectDelimiter(text);
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (ch == delimiter && !quoted) {
        row.add(field.toString());
        field = StringBuffer();
      } else if ((ch == '\n' || ch == '\r') && !quoted) {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field = StringBuffer();
        if (row.any((e) => e.trim().isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.write(ch);
      }
    }
    row.add(field.toString());
    if (row.any((e) => e.trim().isNotEmpty)) rows.add(row);
    return rows;
  }

  static String _get(Map<String, String> row, List<String> keys) {
    for (final k in keys) {
      final v = row[k];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static String _required(
      Map<String, String> row, List<String> keys, String label) {
    final v = _get(row, keys);
    if (v.isEmpty) throw Exception('$label is required.');
    return v;
  }

  static double _num(Map<String, String> row, List<String> keys,
      {double fallback = 0}) {
    final raw = _get(row, keys).replaceAll(',', '');
    if (raw.isEmpty) return fallback;
    final v = double.tryParse(raw);
    if (v == null) throw Exception('${keys.first} must be a valid number.');
    return v;
  }

  static int _boolInt(String value, {bool fallback = false}) {
    if (value.trim().isEmpty) return fallback ? 1 : 0;
    return const ['1', 'true', 'yes', 'y', 'active', 'on']
            .contains(value.trim().toLowerCase())
        ? 1
        : 0;
  }

  static String? _null(String value) =>
      value.trim().isEmpty ? null : value.trim();
  static String _normaliseHeader(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  static String _stableId(String prefix, String source) {
    final digest = sha1
        .convert(utf8.encode(source.trim().toLowerCase()))
        .toString()
        .substring(0, 18)
        .toUpperCase();
    return '$prefix-$digest';
  }

  static String _docId(String prefix, String no) =>
      _stableId('MIG-$prefix', no);
  static String _date(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return DateTime.now().toIso8601String();
    final parsed = _tryParseMigrationDate(clean);
    if (parsed != null) return parsed.toIso8601String();
    throw Exception('Invalid date "$raw". Use YYYY-MM-DD or DD/MM/YYYY.');
  }

  static String? _nullableDate(String raw) =>
      raw.trim().isEmpty ? null : _date(raw);
  static String _csvCell(String v) {
    if (!v.contains(',') && !v.contains('"') && !v.contains('\n')) return v;
    return '"${v.replaceAll('"', '""')}"';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
