import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, TextSpan;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/license_manager.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_loading.dart';

Future<Uint8List> _buildReportExportBytes(Map<String, Object?> payload) async {
  final kind = payload['kind'] as String;
  final headers = (payload['headers'] as List).cast<String>();
  final rows =
      (payload['rows'] as List).map((r) => (r as List).cast<String>()).toList();
  if (kind == 'csv') {
    String cell(String value) => '"${value.replaceAll('"', '""')}"';
    final b = StringBuffer()..writeln(headers.map(cell).join(','));
    for (final row in rows) {
      b.writeln(row.map(cell).join(','));
    }
    return Uint8List.fromList(utf8.encode(b.toString()));
  }
  if (kind == 'xlsx') {
    final book = Excel.createExcel();
    final sheet = book['Report'];
    sheet.appendRow([for (final h in headers) TextCellValue(h)]);
    for (final row in rows) {
      sheet.appendRow([for (final v in row) TextCellValue(v)]);
    }
    final bytes = book.save();
    if (bytes == null) throw Exception('Could not create the Excel workbook.');
    return Uint8List.fromList(bytes);
  }
  final document = pw.Document();
  document.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(24),
    build: (_) => [
      pw.Text(payload['title'] as String,
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 3),
      pw.Text(payload['period'] as String,
          style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 12),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: .35),
        children: [
          pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (final h in headers)
                  pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(h,
                          style: pw.TextStyle(
                              fontSize: 7, fontWeight: pw.FontWeight.bold)))
              ]),
          for (final row in rows)
            pw.TableRow(children: [
              for (final v in row)
                pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(v, style: const pw.TextStyle(fontSize: 6.5)))
            ]),
        ],
      ),
    ],
  ));
  return Uint8List.fromList(await document.save());
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late DateTime from;
  late DateTime to;
  String reportType = 'Overview';
  String range = 'Last 30 days';
  String search = '';
  String status = 'All';
  int refreshKey = 0;
  String? selectedBranch;
  bool compareBranches = false;
  bool canViewProfit = false;
  late final branchFuture = AppDatabase.instance.branches();
  final Map<String, Future<Map<String, num>>> _summaryCache = {};
  final Map<String, Future<List<Map<String, Object?>>>> _rowsCache = {};
  final Map<String, Future<List<Map<String, Object?>>>> _seriesCache = {};
  final Map<String, Future<List<Map<String, Object?>>>> _branchComparisonCache =
      {};

  static const reportTypes = [
    'Overview',
    'Sales',
    'Purchases',
    'Expenses',
    'Profit & Loss',
    'Returns',
    'Inventory',
    'Receivables',
    'Payables',
    'Tax'
  ];

  @override
  void initState() {
    super.initState();
    _setRange('Last 30 days', notify: false);
    _loadAccess();
  }

  Future<void> _loadAccess() async {
    final allowed =
        await AppDatabase.instance.currentUserHasPermission('view_profit');
    if (mounted) setState(() => canViewProfit = allowed);
  }

  void _invalidateReportCache() {
    refreshKey++;
    _summaryCache.clear();
    _rowsCache.clear();
    _seriesCache.clear();
    _branchComparisonCache.clear();
  }

  void _setRange(String value, {bool notify = true}) {
    final now = DateTime.now();
    DateTime f;
    DateTime t = DateTime(now.year, now.month, now.day);
    switch (value) {
      case 'Today':
        f = t;
        break;
      case 'This month':
        f = DateTime(now.year, now.month, 1);
        break;
      case 'This year':
        f = DateTime(now.year, 1, 1);
        break;
      case 'Last 30 days':
      default:
        f = t.subtract(const Duration(days: 29));
    }
    if (notify) {
      setState(() {
        range = value;
        from = f;
        to = t;
        _invalidateReportCache();
      });
    } else {
      range = value;
      from = f;
      to = t;
    }
  }

  Future<void> _pickFrom() async {
    final value = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDate: from);
    if (value != null)
      setState(() {
        from = value;
        if (to.isBefore(from)) to = from;
        range = 'Custom';
        _invalidateReportCache();
      });
  }

  Future<void> _pickTo() async {
    final value = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDate: to);
    if (value != null)
      setState(() {
        to = value;
        if (from.isAfter(to)) from = to;
        range = 'Custom';
        _invalidateReportCache();
      });
  }

  String get _periodKey =>
      '${DateFormat('yyyy-MM-dd').format(from)}:${DateFormat('yyyy-MM-dd').format(to)}:${selectedBranch ?? 'current'}:$refreshKey';

  Future<Map<String, num>> _summaryFuture(
      {DateTime? periodFrom, DateTime? periodTo}) {
    final f = periodFrom ?? from;
    final t = periodTo ?? to;
    final key =
        '${DateFormat('yyyy-MM-dd').format(f)}:${DateFormat('yyyy-MM-dd').format(t)}:${selectedBranch ?? 'current'}:$refreshKey';
    return _summaryCache.putIfAbsent(
        key,
        () => AppDatabase.instance.reportSummaryFast(f, t,
            branchIdOverride: selectedBranch, forceRefresh: refreshKey > 0));
  }

  Future<List<Map<String, Object?>>> _dailySeriesFuture() =>
      _seriesCache.putIfAbsent(
        'daily:$_periodKey',
        () => AppDatabase.instance.reportDailySeriesFast(from, to,
            branchIdOverride: selectedBranch, forceRefresh: refreshKey > 0),
      );

  Future<List<Map<String, Object?>>> _branchComparison() async {
    final branches = await branchFuture;
    final results = await Future.wait(branches.map((b) async {
      final summary = await AppDatabase.instance
          .reportSummaryBetween(from, to, branchIdOverride: '${b['id']}');
      return <String, Object?>{'label': b['name'], 'value': summary['sales']};
    }));
    return results;
  }

  Future<List<Map<String, Object?>>> _branchComparisonFuture() =>
      _branchComparisonCache.putIfAbsent(
        'branches:$_periodKey',
        _branchComparison,
      );

  List<Map<String, Object?>> _comparisonRows(List<Map<String, Object?>> rows) {
    final grouped = <String, double>{};
    for (final r in rows) {
      final label = switch (reportType) {
        'Inventory' => '${r['category'] ?? 'Uncategorised'}',
        'Receivables' => '${r['customer_name'] ?? 'Walk-in'}',
        'Payables' => '${r['supplier_name'] ?? 'Supplier'}',
        'Returns' => '${r['return_type']}',
        _ => '${r['metric'] ?? 'Value'}'
      };
      final key = switch (reportType) {
        'Inventory' => 'inventory_value',
        'Receivables' || 'Payables' => 'balance',
        'Returns' => 'total',
        _ => 'value'
      };
      grouped[label] = (grouped[label] ?? 0) + (r[key] as num? ?? 0).toDouble();
    }
    return grouped.entries
        .map((e) => <String, Object?>{'label': e.key, 'value': e.value})
        .toList();
  }

  Future<List<Map<String, Object?>>> _loadRowsUncached() {
    switch (reportType) {
      case 'Purchases':
        return AppDatabase.instance
            .purchasesBetween(from, to, branchIdOverride: selectedBranch);
      case 'Expenses':
        return AppDatabase.instance
            .expensesBetween(from, to, branchIdOverride: selectedBranch);
      case 'Returns':
        return AppDatabase.instance
            .returnsBetween(from, to, branchIdOverride: selectedBranch);
      case 'Inventory':
        return AppDatabase.instance
            .inventoryReport(branchIdOverride: selectedBranch);
      case 'Receivables':
        return AppDatabase.instance
            .receivablesBetween(from, to, branchIdOverride: selectedBranch);
      case 'Payables':
        return AppDatabase.instance
            .payablesBetween(from, to, branchIdOverride: selectedBranch);
      case 'Profit & Loss':
        return AppDatabase.instance
            .profitLossBetween(from, to, branchIdOverride: selectedBranch);
      case 'Tax':
        return AppDatabase.instance
            .taxSummaryBetween(from, to, branchIdOverride: selectedBranch)
            .then((m) => [
                  {'metric': 'Taxable Sales', 'value': m['taxableSales']},
                  {'metric': 'Output Tax', 'value': m['outputTax']},
                  {
                    'metric': 'Taxable Purchases',
                    'value': m['taxablePurchases']
                  },
                  {
                    'metric': 'Purchase Input Tax',
                    'value': m['purchaseInputTax']
                  },
                  {'metric': 'Taxable Expenses', 'value': m['taxableExpenses']},
                  {
                    'metric': 'Expense Input Tax',
                    'value': m['expenseInputTax']
                  },
                  {'metric': 'Total Input Tax', 'value': m['inputTax']},
                  {'metric': 'Net Tax Position', 'value': m['netTax']},
                ]);
      case 'Sales':
      case 'Overview':
      default:
        return AppDatabase.instance
            .salesBetween(from, to, branchIdOverride: selectedBranch);
    }
  }

  Future<List<Map<String, Object?>>> _loadRows() => _rowsCache.putIfAbsent(
        'rows:$reportType:$_periodKey',
        _loadRowsUncached,
      );

  List<Map<String, Object?>> _filtered(List<Map<String, Object?>> rows) {
    final q = search.trim().toLowerCase();
    return rows.where((row) {
      final haystack =
          row.values.map((e) => (e ?? '').toString().toLowerCase()).join(' ');
      if (q.isNotEmpty && !haystack.contains(q)) return false;
      if (status == 'All') return true;
      if (reportType == 'Inventory')
        return (row['stock_status'] ?? '').toString() == status;
      if (reportType == 'Receivables' || reportType == 'Payables') {
        final overdue = ((row['overdue'] as num?) ?? 0).toInt() == 1;
        if (status == 'Overdue') return overdue;
        if (status == 'Current') return !overdue;
      }
      return (row['status'] ?? '').toString() == status;
    }).toList();
  }

  List<String> get _statusOptions {
    if (reportType == 'Inventory')
      return const ['All', 'Healthy', 'Low Stock', 'Out of Stock'];
    if (reportType == 'Receivables' || reportType == 'Payables')
      return const ['All', 'Current', 'Overdue'];
    if (reportType == 'Sales')
      return const [
        'All',
        'Completed',
        'Credit',
        'Partially Returned',
        'Returned'
      ];
    if (reportType == 'Purchases')
      return const ['All', 'Received', 'Partially Paid'];
    return const ['All'];
  }

  Future<void> _exportPrepared(String kind) async {
    try {
      showReliqWorkingSnack(context,
          'Preparing ${kind.toUpperCase()} report… RELIQ is still working.');
      final rows = _filtered(await _loadRows());
      final ext = kind == 'xlsx'
          ? 'xlsx'
          : kind == 'pdf'
              ? 'pdf'
              : 'csv';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export $reportType report to ${ext.toUpperCase()}',
        fileName:
            'V4_${reportType.replaceAll(' ', '_')}_${DateFormat('yyyyMMdd').format(from)}_${DateFormat('yyyyMMdd').format(to)}.$ext',
        type: FileType.custom,
        allowedExtensions: [ext],
      );
      if (path == null) {
        if (mounted) hideReliqWorkingSnack(context);
        return;
      }
      final columns = _columns();
      final payload = <String, Object?>{
        'kind': kind,
        'headers': [for (final c in columns) c.$1],
        'rows': [
          for (final row in rows)
            [for (final c in columns) _formatCell(c.$2(row))]
        ],
        'title': '$reportType Report',
        'period':
            '${DateFormat('dd MMM yyyy').format(from)} – ${DateFormat('dd MMM yyyy').format(to)}',
      };
      // PDF/XLSX generation can be CPU-heavy for long reports. Keep it off the
      // Flutter UI isolate so the window continues painting and responding.
      final bytes = await compute(_buildReportExportBytes, payload);
      final target = path.toLowerCase().endsWith('.$ext') ? path : '$path.$ext';
      await File(target).writeAsBytes(bytes, flush: true);
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${ext.toUpperCase()} report exported: $target')));
      }
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Export failed: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> _exportCsv() => _exportPrepared('csv');
  Future<void> _exportExcel() => _exportPrepared('xlsx');
  Future<void> _exportPdf() => _exportPrepared('pdf');

  Future<void> _runExport(String kind) async {
    try {
      await LicenseManager.instance
          .requireUsable(entitlement: LicenseEntitlements.advancedReports);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return;
    }
    if (!await AppDatabase.instance.currentUserHasPermission('report_export')) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('You do not have permission to export reports.')));
      return;
    }
    switch (kind) {
      case 'xlsx':
        await _exportExcel();
        break;
      case 'pdf':
        await _exportPdf();
        break;
      case 'csv':
      default:
        await _exportCsv();
    }
  }

  List<(String, Object? Function(Map<String, Object?>))> _columns() {
    switch (reportType) {
      case 'Purchases':
        return [
          ('Purchase', (r) => r['no']),
          ('Date', (r) => r['created_at']),
          ('Supplier', (r) => r['supplier_name']),
          ('Document', (r) => r['document_no']),
          ('Subtotal', (r) => r['subtotal']),
          ('Discount', (r) => r['discount']),
          ('Total', (r) => r['total']),
          ('Paid', (r) => r['paid']),
          ('Balance', (r) => r['balance']),
          ('Status', (r) => r['status']),
        ];
      case 'Expenses':
        return [
          ('Date', (r) => r['expense_date']),
          ('Category', (r) => r['category']),
          ('Description', (r) => r['description']),
          ('Amount', (r) => r['amount']),
          ('Tax', (r) => r['tax_amount']),
          ('Method', (r) => r['payment_method']),
        ];
      case 'Returns':
        return [
          ('Return', (r) => r['no']),
          ('Type', (r) => r['return_type']),
          ('Source', (r) => r['source_no']),
          ('Date', (r) => r['created_at']),
          ('Customer / Supplier', (r) => r['counterparty']),
          ('Total', (r) => r['total']),
          ('Refund / Credit', (r) => r['refund_amount']),
        ];
      case 'Inventory':
        return [
          ('SKU', (r) => r['sku']),
          ('Product', (r) => r['name']),
          ('Category', (r) => r['category']),
          ('Unit', (r) => r['unit']),
          ('Stock', (r) => r['stock']),
          ('Min', (r) => r['min_stock']),
          ('Cost', (r) => r['cost']),
          ('Value', (r) => r['inventory_value']),
          ('Status', (r) => r['stock_status']),
        ];
      case 'Receivables':
        return [
          ('Invoice', (r) => r['no']),
          ('Customer', (r) => r['customer_name']),
          ('Date', (r) => r['created_at']),
          ('Due Date', (r) => r['due_date']),
          ('Total', (r) => r['total']),
          ('Paid', (r) => r['paid']),
          ('Balance', (r) => r['balance']),
        ];
      case 'Payables':
        return [
          ('Purchase', (r) => r['no']),
          ('Supplier', (r) => r['supplier_name']),
          ('Date', (r) => r['created_at']),
          ('Due Date', (r) => r['due_date']),
          ('Total', (r) => r['total']),
          ('Paid', (r) => r['paid']),
          ('Balance', (r) => r['balance']),
        ];
      case 'Profit & Loss':
        return [
          ('Section', (r) => r['section']),
          ('Account / Line', (r) => r['metric']),
          (
            'Amount',
            (r) => r['kind'] == 'percent'
                ? '${(r['value'] as num? ?? 0).toStringAsFixed(2)}%'
                : r['value']
          )
        ];
      case 'Tax':
        return [
          ('Tax Metric', (r) => r['metric']),
          ('Amount', (r) => r['value'])
        ];
      case 'Sales':
      case 'Overview':
      default:
        return [
          ('Invoice', (r) => r['no']),
          ('Date', (r) => r['created_at']),
          ('Customer', (r) => r['customer_name']),
          ('Subtotal', (r) => r['subtotal']),
          ('Discount', (r) => r['discount']),
          ('Delivery', (r) => r['delivery_charge']),
          ('Other', (r) => r['other_charge']),
          ('Total', (r) => r['total']),
          ('Paid', (r) => r['paid']),
          ('Balance', (r) => r['balance']),
          ('Status', (r) => r['status']),
        ];
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, num>>(
        key: ValueKey('summary-$refreshKey'),
        future: _summaryFuture(),
        builder: (context, summarySnapshot) {
          if (summarySnapshot.hasError)
            return Center(
                child:
                    Text('Reports could not load: ${summarySnapshot.error}'));
          if (!summarySnapshot.hasData)
            return const _ReportLoadingState(
                message: 'Preparing report…',
                detail:
                    'Large date ranges can take a moment. RELIQ is still working.');
          final d = summarySnapshot.data!;
          return Padding(
            padding: V3Style.pagePadding,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Reports',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                          'Detailed sales, purchase, expense, Profit & Loss, return, inventory and account reports.',
                          style: TextStyle(color: V3Style.mutedFor(context))),
                    ])),
                PopupMenuButton<String>(
                  tooltip: 'Download report',
                  onSelected: _runExport,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'pdf',
                        child: ListTile(
                            leading: Icon(Icons.picture_as_pdf_outlined),
                            title: Text('Export PDF'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    PopupMenuItem(
                        value: 'xlsx',
                        child: ListTile(
                            leading: Icon(Icons.table_view_outlined),
                            title: Text('Export Excel'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                    PopupMenuItem(
                        value: 'csv',
                        child: ListTile(
                            leading: Icon(Icons.description_outlined),
                            title: Text('Export CSV'),
                            dense: true,
                            contentPadding: EdgeInsets.zero)),
                  ],
                  child: IgnorePointer(
                      child: FilledButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.download_outlined, size: 17),
                          label: const Text('Download Report'))),
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FutureBuilder<List<Map<String, Object?>>>(
                            future: branchFuture,
                            builder: (ctx, snap) => Align(
                                alignment: Alignment.centerLeft,
                                child: SizedBox(
                                    width: 240,
                                    child: DropdownButtonFormField<String>(
                                        value: selectedBranch,
                                        decoration: const InputDecoration(
                                            labelText: 'Report branch'),
                                        items: [
                                          const DropdownMenuItem<String>(
                                              value: null,
                                              child: Text('Current branch')),
                                          ...(snap.data ?? []).map((b) =>
                                              DropdownMenuItem(
                                                  value: '${b['id']}',
                                                  child: Text('${b['name']}')))
                                        ],
                                        onChanged: (v) => setState(() {
                                              selectedBranch = v;
                                              _invalidateReportCache();
                                            }))))),
                        const SizedBox(height: 8),
                        if (reportType != 'Profit & Loss')
                          FutureBuilder<Map<String, num>>(
                              future: _summaryFuture(
                                  periodFrom: from.subtract(Duration(
                                      days: to.difference(from).inDays + 1)),
                                  periodTo:
                                      from.subtract(const Duration(days: 1))),
                              builder: (ctx, snap) {
                                if (!snap.hasData)
                                  return Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                          'Comparing with previous period…',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color:
                                                  V3Style.mutedFor(context))));
                                final previous = snap.data!;
                                final keys = canViewProfit
                                    ? [
                                        'sales',
                                        'grossMargin',
                                        'purchases',
                                        'expenses'
                                      ]
                                    : ['sales', 'purchases', 'expenses'];
                                return Wrap(
                                    spacing: 18,
                                    runSpacing: 6,
                                    children: [
                                      for (final key in keys)
                                        Text(
                                            '${key == 'grossMargin' ? 'Gross margin' : key[0].toUpperCase() + key.substring(1)} vs previous period: ${(previous[key] ?? 0) == 0 ? 'no prior baseline' : '${(((d[key] ?? 0) - (previous[key] ?? 0)) / (previous[key] ?? 1).abs() * 100).toStringAsFixed(1)}%'}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600))
                                    ]);
                              }),
                        const SizedBox(height: 8),
                        if (reportType != 'Profit & Loss')
                          SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: [
                                _metric('Sales', d['sales'] ?? 0,
                                    Icons.trending_up, V3Style.blue),
                                if (canViewProfit)
                                  _metric('Gross Margin', d['grossMargin'] ?? 0,
                                      Icons.insights_outlined, V3Style.success),
                                _metric(
                                    'Expenses',
                                    d['expenses'] ?? 0,
                                    Icons.receipt_long_outlined,
                                    V3Style.warning),
                                if (canViewProfit)
                                  _metric(
                                      'After Expenses',
                                      d['netAfterExpenses'] ?? 0,
                                      Icons.account_balance_outlined,
                                      V3Style.purple),
                                _metric('Purchases', d['purchases'] ?? 0,
                                    Icons.shopping_cart_outlined, V3Style.gold),
                                _metric(
                                    'Sales Returns',
                                    d['salesReturns'] ?? 0,
                                    Icons.keyboard_return_outlined,
                                    V3Style.danger),
                                _metric(
                                    'Purchase Returns',
                                    d['purchaseReturns'] ?? 0,
                                    Icons.assignment_return_outlined,
                                    V3Style.warning),
                                _metric(
                                    'Customer Due',
                                    d['salesDue'] ?? 0,
                                    Icons.account_balance_wallet_outlined,
                                    V3Style.teal),
                                _metric('Supplier Due', d['purchaseDue'] ?? 0,
                                    Icons.payments_outlined, V3Style.purple),
                              ])),
                        const SizedBox(height: 12),
                        if (reportType == 'Overview')
                          Align(
                              alignment: Alignment.centerLeft,
                              child: SegmentedButton<bool>(
                                  segments: const [
                                    ButtonSegment(
                                        value: false,
                                        label: Text('Time trend')),
                                    ButtonSegment(
                                        value: true,
                                        label: Text('Compare branches'))
                                  ],
                                  selected: {
                                    compareBranches
                                  },
                                  onSelectionChanged: (v) => setState(
                                      () => compareBranches = v.first))),
                        const SizedBox(height: 6),
                        if (reportType != 'Profit & Loss')
                          SizedBox(
                              height: 260,
                              child: reportType == 'Overview' && compareBranches
                                  ? FutureBuilder<List<Map<String, Object?>>>(
                                      future: _branchComparisonFuture(),
                                      builder: (ctx, snap) {
                                        if (snap.hasError)
                                          return _ChartMessage(
                                              message:
                                                  'Could not load branch comparison: ${snap.error}',
                                              isError: true);
                                        if (!snap.hasData)
                                          return const _ChartLoadingCard(
                                              message: 'Comparing branches…');
                                        return _ComparisonChart(
                                            rows: snap.data!,
                                            title: 'Net sales by branch · KWD');
                                      })
                                  : [
                                      'Overview',
                                      'Sales',
                                      'Purchases',
                                      'Expenses'
                                    ].contains(reportType)
                                      ? FutureBuilder<
                                              List<Map<String, Object?>>>(
                                          key: ValueKey('chart-$refreshKey'),
                                          future: _dailySeriesFuture(),
                                          builder: (ctx, snap) {
                                            if (snap.hasError)
                                              return _ChartMessage(
                                                  message:
                                                      'Could not load trend: ${snap.error}',
                                                  isError: true);
                                            if (!snap.hasData)
                                              return const _ChartLoadingCard(
                                                  message:
                                                      'Building trend chart…');
                                            return _TrendChart(
                                                rows: snap.data!,
                                                mode: (!canViewProfit &&
                                                        reportType ==
                                                            'Overview')
                                                    ? 'Sales'
                                                    : reportType);
                                          })
                                      : FutureBuilder<
                                              List<Map<String, Object?>>>(
                                          future: _loadRows(),
                                          builder: (ctx, snap) {
                                            if (snap.hasError)
                                              return _ChartMessage(
                                                  message:
                                                      'Could not load chart: ${snap.error}',
                                                  isError: true);
                                            if (!snap.hasData)
                                              return const _ChartLoadingCard(
                                                  message:
                                                      'Preparing comparison…');
                                            return _ComparisonChart(
                                                rows:
                                                    _comparisonRows(snap.data!),
                                                title:
                                                    '$reportType comparison · KWD');
                                          })),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<String>(
                            segments: [
                              for (final x in reportTypes.where(
                                  (x) => canViewProfit || x != 'Profit & Loss'))
                                ButtonSegment(value: x, label: Text(x))
                            ],
                            selected: {reportType},
                            showSelectedIcon: false,
                            onSelectionChanged: (v) => setState(() {
                              reportType = v.first;
                              status = 'All';
                              search = '';
                            }),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(children: [
                              Row(children: [
                                Wrap(spacing: 6, runSpacing: 6, children: [
                                  for (final x in const [
                                    'Today',
                                    'This month',
                                    'Last 30 days',
                                    'This year'
                                  ])
                                    ChoiceChip(
                                        label: Text(x),
                                        selected: range == x,
                                        onSelected: (_) => _setRange(x)),
                                ]),
                                const Spacer(),
                                OutlinedButton.icon(
                                    onPressed: _pickFrom,
                                    icon: const Icon(
                                        Icons.calendar_month_outlined,
                                        size: 16),
                                    label: Text(DateFormat('dd MMM yyyy')
                                        .format(from))),
                                const SizedBox(width: 7),
                                OutlinedButton.icon(
                                    onPressed: _pickTo,
                                    icon: const Icon(Icons.event_outlined,
                                        size: 16),
                                    label: Text(
                                        DateFormat('dd MMM yyyy').format(to))),
                              ]),
                              const SizedBox(height: 10),
                              Row(children: [
                                Expanded(
                                    flex: 3,
                                    child: TextField(
                                        decoration: const InputDecoration(
                                            prefixIcon: Icon(Icons.search),
                                            hintText: 'Filter this report...'),
                                        onChanged: (v) =>
                                            setState(() => search = v))),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 210,
                                  child: DropdownButtonFormField<String>(
                                    value: _statusOptions.contains(status)
                                        ? status
                                        : 'All',
                                    decoration: const InputDecoration(
                                        labelText: 'Status'),
                                    items: [
                                      for (final x in _statusOptions)
                                        DropdownMenuItem(
                                            value: x, child: Text(x))
                                    ],
                                    onChanged: (v) =>
                                        setState(() => status = v ?? 'All'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton.filledTonal(
                                    tooltip: 'Refresh',
                                    onPressed: () =>
                                        setState(_invalidateReportCache),
                                    icon: const Icon(Icons.refresh, size: 18)),
                              ]),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 540,
                          child: FutureBuilder<List<Map<String, Object?>>>(
                            key: ValueKey('rows-$reportType-$refreshKey'),
                            future: _loadRows(),
                            builder: (context, snapshot) {
                              if (snapshot.hasError)
                                return Center(child: Text('${snapshot.error}'));
                              if (!snapshot.hasData)
                                return const _ReportLoadingState(
                                    message: 'Loading report details…',
                                    detail:
                                        'You can continue using RELIQ after this report finishes loading.');
                              final rows = _filtered(snapshot.data!);
                              if (reportType == 'Overview')
                                return _overview(d, rows);
                              if (reportType == 'Profit & Loss')
                                return _profitLossStatement(rows);
                              return _reportTable(rows);
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                      ]),
                ),
              ),
            ]),
          );
        },
      );

  Widget _metric(String label, num value, IconData icon, Color color) =>
      SizedBox(
        width: 150,
        height: 92,
        child: Card(
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: color, width: 3))),
              padding: const EdgeInsets.all(11),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon, size: 16, color: color),
                      const Spacer(),
                      Text(label.toUpperCase(),
                          style: const TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              color: V3Style.muted))
                    ]),
                    const Spacer(),
                    Text(value.toStringAsFixed(3),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                  ]),
            )),
      );

  Widget _overview(Map<String, num> d, List<Map<String, Object?>> sales) =>
      Row(children: [
        Expanded(
            child: Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Sales Statistics',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          _summaryRow('Invoices',
                              (d['salesCount'] ?? 0).toStringAsFixed(0)),
                          _summaryRow('Average invoice',
                              (d['avgInvoice'] ?? 0).toStringAsFixed(3)),
                          _summaryRow('Discounts',
                              (d['salesDiscounts'] ?? 0).toStringAsFixed(3)),
                          _summaryRow('Returns',
                              (d['salesReturns'] ?? 0).toStringAsFixed(3)),
                          if (canViewProfit)
                            _summaryRow('Gross margin',
                                (d['grossMargin'] ?? 0).toStringAsFixed(3)),
                          if (canViewProfit)
                            _summaryRow(
                                'After expenses',
                                (d['netAfterExpenses'] ?? 0)
                                    .toStringAsFixed(3)),
                        ])))),
        const SizedBox(width: 12),
        Expanded(
            flex: 2,
            child: Card(
                child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Recent Sales in Selected Period',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          Expanded(
                              child: sales.isEmpty
                                  ? const Center(
                                      child: Text('No sales in this period.'))
                                  : ListView.separated(
                                      itemCount: sales.take(15).length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, i) {
                                        final x = sales[i];
                                        return ListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(
                                                '${x['no']} • ${x['customer_name'] ?? 'Walk-in'}'),
                                            subtitle: Text(
                                                '${x['status']} • ${DateFormat('dd MMM').format(DateTime.tryParse((x['created_at'] ?? '').toString()) ?? DateTime.now())}'),
                                            trailing: Text(
                                                (x['total'] as num? ?? 0)
                                                    .toStringAsFixed(3),
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w700)));
                                      },
                                    )),
                        ])))),
      ]);

  Widget _summaryRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700))
      ]));

  Widget _profitLossStatement(List<Map<String, Object?>> rows) {
    if (!canViewProfit)
      return const Center(
          child:
              Text('You do not have permission to view profit information.'));
    if (rows.isEmpty)
      return const Center(
          child: Text('No Profit & Loss data is available for this period.'));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('Profit & Loss Statement',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(
                      'Accrual-style operating view using historical sale cost. Tax is excluded from revenue and operating expenses.',
                      style: TextStyle(
                          fontSize: 11, color: V3Style.mutedFor(context))),
                ])),
            Text(
                '${DateFormat('dd MMM yyyy').format(from)} – ${DateFormat('dd MMM yyyy').format(to)}',
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
            child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  final rowSection = '${row['section'] ?? ''}';
                  final kind = '${row['kind'] ?? 'money'}';
                  final value = (row['value'] as num? ?? 0).toDouble();
                  final showSection =
                      i == 0 || '${rows[i - 1]['section'] ?? ''}' != rowSection;
                  final strong = kind == 'subtotal' ||
                      kind == 'total' ||
                      kind == 'grand_total';
                  final grand = kind == 'grand_total';
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showSection)
                          Padding(
                              padding: EdgeInsets.fromLTRB(
                                  18, i == 0 ? 14 : 18, 18, 7),
                              child: Text(rowSection.toUpperCase(),
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      color: V3Style.muted,
                                      letterSpacing: .6))),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 9),
                          decoration: BoxDecoration(
                              color: grand
                                  ? V3Style.lime.withValues(alpha: .12)
                                  : (strong
                                      ? Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest
                                          .withValues(alpha: .45)
                                      : Colors.transparent),
                              border: kind == 'total' || grand
                                  ? Border(
                                      top: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))
                                  : null),
                          child: Row(children: [
                            Expanded(
                                child: Text('${row['metric']}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: strong
                                            ? FontWeight.w900
                                            : FontWeight.w500))),
                            Text(
                                kind == 'percent'
                                    ? '${value.toStringAsFixed(2)}%'
                                    : value.toStringAsFixed(3),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: strong || kind == 'percent'
                                        ? FontWeight.w900
                                        : FontWeight.w600,
                                    color: grand
                                        ? (value >= 0
                                            ? V3Style.success
                                            : V3Style.danger)
                                        : null)),
                          ]),
                        ),
                      ]);
                })),
      ]),
    );
  }

  Widget _reportTable(List<Map<String, Object?>> rows) {
    if (rows.isEmpty)
      return const Center(
          child: Text('No data matches the selected period and filters.'));
    final columns = _columns();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 200.0 + columns.length * 135,
          child: Column(children: [
            Container(
              height: (Theme.of(context).listTileTheme.minTileHeight ?? 40)
                  .clamp(40, 58)
                  .toDouble(),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: V3Style.tableHeader(context),
              child: Row(children: [
                for (final c in columns)
                  SizedBox(
                      width: 135,
                      child: Text(c.$1.toUpperCase(),
                          style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .4)))
              ]),
            ),
            Expanded(
                child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => Container(
                constraints: const BoxConstraints(minHeight: 46),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                color:
                    i.isOdd ? V3Style.rowStripe(context) : Colors.transparent,
                child: Row(children: [
                  for (final c in columns)
                    SizedBox(
                        width: 135,
                        child: Text(_formatCell(c.$2(rows[i])),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10.5)))
                ]),
              ),
            )),
          ]),
        ),
      ),
    );
  }

  String _formatCell(Object? value) {
    if (value == null) return '—';
    if (value is num) return value.toStringAsFixed(3);
    final s = value.toString();
    final date = DateTime.tryParse(s);
    if (date != null && s.contains('T'))
      return DateFormat('dd MMM yyyy HH:mm').format(date);
    return s.isEmpty ? '—' : s;
  }
}

class _ReportLoadingState extends StatelessWidget {
  final String message;
  final String detail;
  const _ReportLoadingState({required this.message, required this.detail});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 14),
                Text(message,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text(detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11, color: V3Style.mutedFor(context))),
              ]),
            ),
          ),
        ),
      );
}

class _ChartLoadingCard extends StatelessWidget {
  final String message;
  const _ChartLoadingCard({required this.message});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Report chart',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.4)),
              const SizedBox(width: 10),
              Text(message,
                  style: TextStyle(
                      fontSize: 11, color: V3Style.mutedFor(context))),
            ]),
            const Spacer(),
            const LinearProgressIndicator(minHeight: 2),
          ]),
        ),
      );
}

class _ChartMessage extends StatelessWidget {
  final String message;
  final bool isError;
  const _ChartMessage({required this.message, this.isError = false});

  @override
  Widget build(BuildContext context) => Card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    color: isError ? V3Style.danger : V3Style.muted)),
          ),
        ),
      );
}

class _TrendChart extends StatelessWidget {
  final List<Map<String, Object?>> rows;
  final String mode;
  const _TrendChart({required this.rows, required this.mode});

  List<(String, Color, String)> seriesFor(BuildContext context) {
    final purchaseColor = Theme.of(context).brightness == Brightness.dark
        ? V3Style.lime
        : const Color(0xFF667A00);
    switch (mode) {
      case 'Purchases':
        return [('purchases', purchaseColor, 'Purchases')];
      case 'Expenses':
        return [('expenses', V3Style.warning, 'Expenses')];
      case 'Sales':
        return [
          ('sales', V3Style.blueDark, 'Sales'),
          ('gross_margin', V3Style.success, 'Gross Margin')
        ];
      default:
        return [
          ('sales', V3Style.blueDark, 'Sales'),
          ('purchases', purchaseColor, 'Purchases'),
          ('expenses', V3Style.warning, 'Expenses'),
          ('gross_margin', V3Style.success, 'Margin')
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = seriesFor(context);
    final title = mode == 'Overview' ? 'Business Trend' : '$mode Trend';
    return Card(
        child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 12, runSpacing: 6, children: [
                Text('$title · KWD',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                for (final s in visible) _legend(s.$2, s.$3)
              ]),
              const SizedBox(height: 8),
              Expanded(
                  child: rows.isEmpty
                      ? const Center(
                          child: Text('No chart data for this period.'))
                      : CustomPaint(
                          painter: _TrendPainter(
                              rows, Theme.of(context).dividerColor, visible),
                          child: const SizedBox.expand())),
            ])));
  }

  static Widget _legend(Color c, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 9, color: V3Style.muted))
      ]);
}

class _TrendPainter extends CustomPainter {
  final List<Map<String, Object?>> rows;
  final Color grid;
  final List<(String, Color, String)> series;
  _TrendPainter(this.rows, this.grid, this.series);
  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty || size.width < 80 || size.height < 50) return;
    const left = 55.0, top = 8.0, bottom = 25.0;
    final w = size.width - left - 8, h = size.height - top - bottom;
    final values = [
      0.0,
      ...rows
          .expand((r) => series.map((s) => (r[s.$1] as num? ?? 0).toDouble()))
    ];
    var lo = values.reduce((a, b) => a < b ? a : b),
        hi = values.reduce((a, b) => a > b ? a : b);
    if (hi - lo < .001) hi = lo + 1;
    double y(double value) => top + h - (value - lo) / (hi - lo) * h;
    double x(int i) =>
        left + (rows.length == 1 ? w / 2 : i * w / (rows.length - 1));
    void label(String text, Offset at) {
      final painter = TextPainter(
          text:
              TextSpan(text: text, style: TextStyle(fontSize: 10, color: grid)),
          textDirection: ui.TextDirection.ltr)
        ..layout();
      painter.paint(canvas, at);
    }

    for (var i = 0; i <= 3; i++) {
      final value = lo + (hi - lo) * i / 3;
      canvas.drawLine(Offset(left, y(value)), Offset(size.width - 8, y(value)),
          Paint()..color = grid.withValues(alpha: .4));
      label(value.toStringAsFixed(1), Offset(0, y(value) - 6));
    }
    canvas.drawLine(
        Offset(left, y(0)),
        Offset(size.width - 8, y(0)),
        Paint()
          ..color = grid
          ..strokeWidth = 1.2);
    for (final s in series) {
      final path = Path();
      for (var i = 0; i < rows.length; i++) {
        final point = Offset(x(i), y((rows[i][s.$1] as num? ?? 0).toDouble()));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        if (rows.length <= 31)
          canvas.drawCircle(point, 2.4, Paint()..color = s.$2);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.$2
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke);
    }
    final ticks = <int>{0, rows.length ~/ 2, rows.length - 1};
    for (final i in ticks) {
      final day = DateTime.tryParse('${rows[i]['day']}');
      final text =
          day == null ? '${rows[i]['day']}' : DateFormat('dd MMM').format(day);
      label(
          text,
          Offset((x(i) - 18).clamp(left, size.width - 45).toDouble(),
              size.height - 18));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.grid != grid ||
      oldDelegate.series != series;
}

class _ComparisonChart extends StatelessWidget {
  final List<Map<String, Object?>> rows;
  final String title;
  const _ComparisonChart({required this.rows, required this.title});
  @override
  Widget build(BuildContext context) {
    final ranked = List<Map<String, Object?>>.from(rows)
      ..sort((a, b) => (b['value'] as num? ?? 0)
          .abs()
          .compareTo((a['value'] as num? ?? 0).abs()));
    final visible = ranked.take(5).toList();
    final maximum = visible.fold<double>(1, (m, r) {
      final v = (r['value'] as num? ?? 0).abs().toDouble();
      return v > m ? v : m;
    });
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$title${ranked.length > 5 ? ' · top 5' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              if (visible.isEmpty) const Text('No data for this period.'),
              ...visible.map((r) {
                final value = (r['value'] as num? ?? 0).toDouble();
                return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      SizedBox(
                          width: 150,
                          child: Text('${r['label']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11))),
                      Expanded(
                          child: LinearProgressIndicator(
                              value: (value.abs() / maximum)
                                  .clamp(0, 1)
                                  .toDouble(),
                              minHeight: 8,
                              color:
                                  value < 0 ? V3Style.danger : V3Style.blue)),
                      const SizedBox(width: 12),
                      SizedBox(
                          width: 100,
                          child: Text(value.toStringAsFixed(3),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w700)))
                    ]));
              })
            ])));
  }
}
