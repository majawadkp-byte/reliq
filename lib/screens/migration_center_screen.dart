import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/migration_center_service.dart';
import '../ui/v3_style.dart';

class MigrationCenterScreen extends StatefulWidget {
  const MigrationCenterScreen({super.key});

  @override
  State<MigrationCenterScreen> createState() => _MigrationCenterScreenState();
}

class _MigrationCenterScreenState extends State<MigrationCenterScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  bool busy = false;
  String status = '';
  Map<String, num> reconciliation = const {};

  static const quick = <MigrationEntity>[
    MigrationEntity.products,
    MigrationEntity.customers,
    MigrationEntity.suppliers,
    MigrationEntity.customerReceipts,
    MigrationEntity.supplierPayments,
    MigrationEntity.expenses,
    MigrationEntity.stockAdjustments,
  ];

  static const history = <MigrationEntity>[
    MigrationEntity.sales,
    MigrationEntity.saleItems,
    MigrationEntity.purchases,
    MigrationEntity.purchaseItems,
    MigrationEntity.customerReceiptAllocations,
    MigrationEntity.supplierPaymentAllocations,
    MigrationEntity.salesReturns,
    MigrationEntity.saleReturnItems,
    MigrationEntity.purchaseReturns,
    MigrationEntity.purchaseReturnItems,
  ];

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 4, vsync: this);
    _refreshReconciliation();
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> _refreshReconciliation() async {
    final value = await MigrationCenterService.reconciliation();
    if (mounted) setState(() => reconciliation = value);
  }

  Future<void> _downloadTemplate(MigrationEntity entity) async {
    try {
      final path = await MigrationCenterService.saveTemplate(entity);
      if (path != null && mounted) _toast('Template saved to $path');
    } catch (e) {
      if (mounted) _error(e);
    }
  }

  Future<void> _downloadPack() async {
    try {
      final path = await MigrationCenterService.saveTemplatePack();
      if (path != null && mounted)
        _toast('Migration template pack saved to $path');
    } catch (e) {
      if (mounted) _error(e);
    }
  }

  Future<void> _importOne(MigrationEntity entity) async {
    try {
      // Let the native picker open before changing button/busy state. This avoids
      // the misleading "Reading and validating" banner when no file has yet been
      // selected and is more reliable on macOS desktop builds.
      final file = await MigrationCenterService.pickCsv(
        entity,
        onFileChosen: () {
          if (mounted) {
            setState(() {
              busy = true;
              status = 'Reading and validating ${entity.title} CSV...';
            });
          }
        },
      );
      if (mounted)
        setState(() {
          busy = false;
          status = '';
        });
      if (file == null || !mounted) return;
      if (file.entity != entity) {
        _toast(
            'Detected ${file.entity.title} from ${file.sourceName}; RELIQ will validate it as ${file.entity.title}.');
      }
      final proceed = await _previewFiles([file], full: false);
      if (proceed != true || !mounted) {
        if (mounted)
          setState(() {
            busy = false;
            status = '';
          });
        return;
      }
      setState(() {
        busy = true;
        status = 'Importing ${file.entity.title}...';
      });
      final result = await MigrationCenterService.importOne(file,
          onProgress: (done, total, stage) {
        if (mounted) setState(() => status = '$stage… $done / $total rows');
      });
      if (!mounted) return;
      setState(() {
        busy = false;
        status = '${result.imported} rows imported • ${result.skipped} skipped';
      });
      await _refreshReconciliation();
      await _showResult(result, title: '${file.entity.title} import complete');
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          status = '';
        });
        _error(e);
      }
    }
  }

  Future<void> _fullMigration() async {
    try {
      final files = await MigrationCenterService.pickMigrationZip(
        onFileChosen: () {
          if (mounted) {
            setState(() {
              busy = true;
              status = 'Reading and validating migration ZIP...';
            });
          }
        },
      );
      if (mounted)
        setState(() {
          busy = false;
          status = '';
        });
      if (files == null || !mounted) return;
      final proceed = await _previewFiles(files, full: true);
      if (proceed != true || !mounted) {
        if (mounted)
          setState(() {
            busy = false;
            status = '';
          });
        return;
      }
      setState(() {
        busy = true;
        status = 'Creating safety backup and migrating business data...';
      });
      final result = await MigrationCenterService.importFull(files,
          onProgress: (done, total, stage) {
        if (mounted) setState(() => status = '$stage… $done / $total rows');
      });
      if (!mounted) return;
      setState(() {
        busy = false;
        status = '${result.imported} rows imported • ${result.skipped} skipped';
      });
      await _refreshReconciliation();
      await _showResult(result, title: 'Full business migration complete');
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          status = '';
        });
        _error(e);
      }
    }
  }

  Future<bool?> _previewFiles(List<MigrationFile> files,
      {required bool full}) async {
    final totalRows = files.fold<int>(0, (s, f) => s + f.rows.length);
    final invalid = files.where((f) => !f.valid).toList();
    final packageErrors =
        full ? MigrationCenterService.packageErrors(files) : const <String>[];
    final referenceErrors = await MigrationCenterService.referenceErrors(files);
    if (!mounted) return false;
    final hasErrors = invalid.isNotEmpty ||
        packageErrors.isNotEmpty ||
        referenceErrors.isNotEmpty;
    return showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(full ? 'Review full migration' : 'Review import'),
              content: SizedBox(
                  width: 720,
                  child: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        _notice(
                          hasErrors
                              ? Icons.warning_amber_outlined
                              : Icons.verified_outlined,
                          hasErrors
                              ? 'Validation needs attention'
                              : 'Validation passed',
                          hasErrors
                              ? 'Fix the validation errors below before importing.'
                              : '$totalRows data rows passed column, row and date validation.',
                          hasErrors ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(height: 12),
                        ...files.map((f) => Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(
                                  f.valid
                                      ? Icons.check_circle_outline
                                      : Icons.error_outline,
                                  color: f.valid ? Colors.green : Colors.red),
                              title: Text(f.entity.title),
                              subtitle: Text(
                                  '${f.sourceName} • ${f.rows.length} rows${f.errors.isEmpty ? '' : '\n${f.errors.take(8).join('\n')}${f.errors.length > 8 ? '\n…and ${f.errors.length - 8} more error(s)' : ''}'}'),
                            ))),
                        if (packageErrors.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Text('Cross-file validation',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 5),
                          SelectableText(packageErrors.take(30).join('\n'),
                              style: const TextStyle(
                                  fontSize: 11, color: V3Style.muted)),
                        ],
                        if (referenceErrors.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Text('Linked document validation',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 5),
                          SelectableText(referenceErrors.take(40).join('\n'),
                              style: const TextStyle(
                                  fontSize: 11, color: V3Style.muted)),
                        ],
                        if (full) ...[
                          const SizedBox(height: 10),
                          const Text('Migration rules',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 5),
                          const Text(
                              '• RELIQ creates a database backup before a full migration.\n• Historical sales/purchases are imported for reports and ledgers without re-applying their old stock movements.\n• products.csv current_stock is treated as the current closing stock.\n• customer/supplier current_balance values are treated as current closing balances.\n• Re-running a document header replaces the same imported document; linked item rows are rebuilt.',
                              style: TextStyle(
                                  fontSize: 12, color: V3Style.muted)),
                        ],
                      ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed:
                        hasErrors ? null : () => Navigator.pop(context, true),
                    child: Text(full ? 'Start migration' : 'Import'))
              ],
            ));
  }

  Future<void> _showResult(MigrationRunResult result,
          {required String title}) =>
      showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                    width: 680,
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          _notice(
                              Icons.task_alt,
                              '${result.imported} rows imported',
                              '${result.skipped} rows skipped',
                              Colors.green),
                          if (result.backupPath != null) ...[
                            const SizedBox(height: 10),
                            SelectableText(
                                'Safety backup: ${result.backupPath}',
                                style: const TextStyle(fontSize: 11))
                          ],
                          if (result.warnings.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Text('Warnings (${result.warnings.length})',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 6),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 230),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                  color: Colors.orange.withValues(alpha: .07),
                                  borderRadius: BorderRadius.circular(10)),
                              child: SingleChildScrollView(
                                  child: SelectableText(
                                      result.warnings.take(100).join('\n'),
                                      style: const TextStyle(fontSize: 11))),
                            ),
                          ],
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ],
              ));

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: V3Style.blue.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.move_up_outlined, color: V3Style.blue)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Migration Center',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900)),
                  const Text(
                      'Move product masters, parties, history, payments and balances into RELIQ with validation and reconciliation.',
                      style: TextStyle(color: V3Style.muted, fontSize: 12)),
                ])),
            OutlinedButton.icon(
                onPressed: busy ? null : _downloadPack,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Template Pack')),
          ]),
          if (busy || status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                    color: V3Style.blue.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(9)),
                child: Row(children: [
                  if (busy) ...[
                    const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 9)
                  ],
                  Expanded(
                      child: Text(status,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)))
                ])),
          ],
          const SizedBox(height: 12),
          TabBar(controller: tabs, isScrollable: true, tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Quick Imports'),
            Tab(text: 'Historical Imports'),
            Tab(text: 'Full Migration')
          ]),
        ]),
      ),
      Expanded(
          child: TabBarView(controller: tabs, children: [
        _overview(),
        _imports(quick),
        _imports(history),
        _full()
      ])),
    ]);
  }

  Widget _overview() => ListView(padding: const EdgeInsets.all(24), children: [
        _notice(
            Icons.info_outline,
            'One center, two ways to migrate',
            'Import only the portions you need, or use Full Business Migration for a coordinated multi-file migration.',
            V3Style.blue),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _metric('Products', reconciliation['products'] ?? 0,
              Icons.inventory_2_outlined),
          _metric('Customers', reconciliation['customers'] ?? 0,
              Icons.people_outline),
          _metric('Suppliers', reconciliation['suppliers'] ?? 0,
              Icons.local_shipping_outlined),
          _metric('Sales', reconciliation['sales'] ?? 0,
              Icons.receipt_long_outlined),
          _metric('Purchases', reconciliation['purchases'] ?? 0,
              Icons.download_outlined),
          _metric('Stock Qty', reconciliation['stock_qty'] ?? 0,
              Icons.inventory_outlined),
        ]),
        const SizedBox(height: 18),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Recommended migration order',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      const Text(
                          'Products → Customers → Suppliers → Sales/Purchases → Item lines → Receipts/Payments → Allocations → Returns → Expenses → Stock reconciliation',
                          style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 10),
                      const Text(
                          'For a clean start without history, import Products, Customers and Suppliers with current stock/current balances. For a complete takeover, use the Full Migration tab.',
                          style: TextStyle(fontSize: 12, color: V3Style.muted)),
                    ]))),
        const SizedBox(height: 18),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.balance_outlined, color: V3Style.blue),
                        const SizedBox(width: 8),
                        const Text('Current reconciliation',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w900)),
                        const Spacer(),
                        IconButton(
                            onPressed: _refreshReconciliation,
                            icon: const Icon(Icons.refresh))
                      ]),
                      const SizedBox(height: 8),
                      _moneyLine('Historical sales value',
                          reconciliation['sales_total'] ?? 0),
                      _moneyLine('Historical purchase value',
                          reconciliation['purchases_total'] ?? 0),
                      _moneyLine('Customer receivables',
                          reconciliation['customer_receivables'] ?? 0),
                      _moneyLine('Supplier payables',
                          reconciliation['supplier_payables'] ?? 0),
                      _moneyLine(
                          'Expenses', reconciliation['expenses_total'] ?? 0),
                    ]))),
      ]);

  Widget _imports(List<MigrationEntity> entities) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        Text(
            identical(entities, quick)
                ? 'Import individual business masters and current balances'
                : 'Import historical transactions and allocations',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        Text(
            identical(entities, quick)
                ? 'Useful for new installations or correcting one section without re-running the whole migration.'
                : 'Import document headers before their item/allocation files. These records preserve history without double-counting current stock or current party balances.',
            style: const TextStyle(fontSize: 12, color: V3Style.muted)),
        const SizedBox(height: 14),
        ...entities.map(_importCard),
      ]);

  Widget _importCard(MigrationEntity entity) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: V3Style.blue.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(_icon(entity), color: V3Style.blue, size: 21)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(entity.title,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(entity.fileName,
                      style:
                          const TextStyle(fontSize: 11, color: V3Style.muted))
                ])),
            OutlinedButton.icon(
                onPressed: busy ? null : () => _downloadTemplate(entity),
                icon: const Icon(Icons.download_outlined, size: 17),
                label: const Text('Template')),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
                onPressed: busy ? null : () => _importOne(entity),
                icon: const Icon(Icons.upload_file_outlined, size: 17),
                label: const Text('Import CSV')),
          ])));

  Widget _full() => ListView(padding: const EdgeInsets.all(24), children: [
        _notice(
            Icons.shield_outlined,
            'Full Business Migration',
            'Upload one ZIP containing any combination of RELIQ migration CSV files. RELIQ validates columns, row values, dates and cross-file references first, then creates a safety backup before importing.',
            Colors.green),
        const SizedBox(height: 16),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('1. Download the template pack',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 5),
                      const Text(
                          'Fill the CSV files that your old system can provide. You do not have to use every file.',
                          style: TextStyle(color: V3Style.muted, fontSize: 12)),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                          onPressed: busy ? null : _downloadPack,
                          icon: const Icon(Icons.folder_zip_outlined),
                          label:
                              const Text('Download Migration Template Pack')),
                      const Divider(height: 30),
                      const Text(
                          '2. Export from the old software and map fields',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 5),
                      const Text(
                          'RELIQ recognizes common alternatives such as sell_price, retail_price, purchase_rate, item_code, invoice_number, party_code and qty. Unknown extra columns are ignored.',
                          style: TextStyle(color: V3Style.muted, fontSize: 12)),
                      const Divider(height: 30),
                      const Text('3. Upload the completed ZIP',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 5),
                      const Text(
                          'The preview checks every recognised file, row count, required value, date and linked document reference before anything is written to the database.',
                          style: TextStyle(color: V3Style.muted, fontSize: 12)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: busy ? null : _fullMigration,
                          icon: const Icon(Icons.move_up_outlined),
                          label: const Text('Choose Migration ZIP & Validate')),
                    ]))),
        const SizedBox(height: 14),
        const Card(
            child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                    'Important: historical invoices are imported for reporting, ledgers and audit history. Current stock is taken from products.csv current_stock, and current customer/supplier balances are taken from their current_balance fields. This prevents old history from being counted twice during migration.',
                    style: TextStyle(fontSize: 12, color: V3Style.muted)))),
      ]);

  Widget _notice(IconData icon, String title, String body, Color color) =>
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: color.withValues(alpha: .07),
              border: Border.all(color: color.withValues(alpha: .20)),
              borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(body,
                      style:
                          const TextStyle(fontSize: 12, color: V3Style.muted))
                ]))
          ]));

  Widget _metric(String label, num value, IconData icon) => SizedBox(
      width: 190,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(15),
              child: Row(children: [
                Icon(icon, color: V3Style.blue, size: 22),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(_number(value),
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 18)),
                      Text(label,
                          style: const TextStyle(
                              fontSize: 11, color: V3Style.muted))
                    ]))
              ]))));
  Widget _moneyLine(String label, num value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Text(value.toStringAsFixed(3),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))
      ]));
  String _number(num n) => NumberFormat('#,##0.###').format(n);

  IconData _icon(MigrationEntity e) => switch (e) {
        MigrationEntity.products => Icons.inventory_2_outlined,
        MigrationEntity.customers => Icons.people_outline,
        MigrationEntity.suppliers => Icons.local_shipping_outlined,
        MigrationEntity.sales ||
        MigrationEntity.saleItems =>
          Icons.receipt_long_outlined,
        MigrationEntity.purchases ||
        MigrationEntity.purchaseItems =>
          Icons.download_outlined,
        MigrationEntity.customerReceipts ||
        MigrationEntity.customerReceiptAllocations =>
          Icons.south_west_outlined,
        MigrationEntity.supplierPayments ||
        MigrationEntity.supplierPaymentAllocations =>
          Icons.north_east_outlined,
        MigrationEntity.expenses => Icons.payments_outlined,
        MigrationEntity.salesReturns ||
        MigrationEntity.saleReturnItems ||
        MigrationEntity.purchaseReturns ||
        MigrationEntity.purchaseReturnItems =>
          Icons.keyboard_return_outlined,
        MigrationEntity.stockAdjustments => Icons.tune_outlined,
      };

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  void _error(Object e) {
    final raw = e.toString().replaceFirst('Exception: ', '');
    var summary = raw;
    final sqlAt = summary.indexOf('Causing statement:');
    if (sqlAt >= 0) summary = summary.substring(0, sqlAt).trim();
    final detailAt = summary.indexOf('{details:');
    if (detailAt >= 0) summary = summary.substring(0, detailAt).trim();
    if (summary.contains('UNIQUE constraint failed: products.sku')) {
      summary =
          'A product SKU already exists in this RELIQ database. No partial rows were committed. '
          'RELIQ now matches an existing product by SKU during migration instead of trying to create a duplicate.';
    }

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Migration could not continue'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(summary),
              const SizedBox(height: 10),
              const Text(
                'The import is transactional, so RELIQ rolls back this import if a row fails.',
                style: TextStyle(fontSize: 12, color: V3Style.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: raw));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Technical error copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_outlined, size: 17),
            label: const Text('Copy details'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
