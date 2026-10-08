import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/document_share_service.dart';
import '../services/print_service.dart';
import '../ui/reliq_loading.dart';
import '../ui/reliq_surface.dart';
import '../ui/v3_style.dart';

class PartyLedgerAction {
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool primary;
  final bool danger;

  const PartyLedgerAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });
}

class PartyLedgerDetailScreen extends StatefulWidget {
  final String partyType;
  final String partyId;
  final String initialName;
  final List<PartyLedgerAction> Function(Map<String, Object?> party)
      actionsBuilder;
  final FocusNode? searchFocusNode;
  final VoidCallback? onBack;

  const PartyLedgerDetailScreen({
    super.key,
    required this.partyType,
    required this.partyId,
    required this.actionsBuilder,
    this.initialName = '',
    this.searchFocusNode,
    this.onBack,
  });

  @override
  State<PartyLedgerDetailScreen> createState() =>
      _PartyLedgerDetailScreenState();
}

class _PartyLedgerDetailScreenState extends State<PartyLedgerDetailScreen> {
  late Future<_PartyLedgerData> _future;
  DateTime? _fromDate;
  DateTime? _toDate;
  double? _minAmount;
  double? _maxAmount;
  String _textFilter = '';
  final TextEditingController _ledgerSearchController = TextEditingController();
  late final FocusNode _ledgerSearchFocus;
  late final bool _ownsLedgerSearchFocus;
  int _page = 0;
  int _rowsPerPage = 10;

  bool get _customer => widget.partyType == 'Customer';

  @override
  void initState() {
    super.initState();
    _ownsLedgerSearchFocus = widget.searchFocusNode == null;
    _ledgerSearchFocus =
        widget.searchFocusNode ?? FocusNode(debugLabel: 'party-ledger-search');
    _future = _load();
  }

  @override
  void dispose() {
    _ledgerSearchController.dispose();
    if (_ownsLedgerSearchFocus) _ledgerSearchFocus.dispose();
    super.dispose();
  }

  Future<_PartyLedgerData> _load() async {
    final partyRows = _customer
        ? await AppDatabase.instance.customers(search: widget.partyId, limit: 5)
        : await AppDatabase.instance
            .suppliers(search: widget.partyId, limit: 5);
    final exact = partyRows
        .where((x) => (x['id'] ?? '').toString() == widget.partyId)
        .toList();
    final party = exact.isNotEmpty
        ? exact.first
        : (partyRows.isNotEmpty
            ? partyRows.first
            : <String, Object?>{
                'id': widget.partyId,
                'name': widget.initialName
              });
    final ledger = _customer
        ? await AppDatabase.instance.customerStatement(widget.partyId)
        : await AppDatabase.instance.supplierStatement(widget.partyId);
    final openItems = _customer
        ? await AppDatabase.instance.openCustomerInvoices(widget.partyId)
        : await AppDatabase.instance.openSupplierBills(widget.partyId);

    double running = 0;
    final rows = <Map<String, Object?>>[];
    for (final source in ledger) {
      final debit = (source['debit'] as num? ?? 0).toDouble();
      final credit = (source['credit'] as num? ?? 0).toDouble();
      running += debit - credit;
      rows.add({...source, 'running_balance': running});
    }
    final openTotal = openItems.fold<double>(
        0, (sum, row) => sum + (row['balance'] as num? ?? 0).toDouble());
    return _PartyLedgerData(
        party: party, rows: rows, openItems: openItems, openTotal: openTotal);
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _future = _load());
  }

  Future<void> _runAction(PartyLedgerAction action) async {
    try {
      await action.onPressed();
    } finally {
      if (mounted) _reload();
    }
  }

  bool get _hasFilters =>
      _fromDate != null ||
      _toDate != null ||
      _minAmount != null ||
      _maxAmount != null ||
      _textFilter.trim().isNotEmpty;

  DateTime? _rowDate(Map<String, Object?> row) {
    final raw = (row['date'] ?? '').toString();
    return DateTime.tryParse(raw)?.toLocal();
  }

  double _rowAmount(Map<String, Object?> row) {
    final debit = ((row['debit'] as num?) ?? 0).toDouble().abs();
    final credit = ((row['credit'] as num?) ?? 0).toDouble().abs();
    return math.max(debit, credit);
  }

  List<Map<String, Object?>> _filteredRows(List<Map<String, Object?>> rows) {
    final query = _textFilter.trim().toLowerCase();
    return rows.where((row) {
      final dt = _rowDate(row);
      if (_fromDate != null) {
        if (dt == null ||
            dt.isBefore(
                DateTime(_fromDate!.year, _fromDate!.month, _fromDate!.day))) {
          return false;
        }
      }
      if (_toDate != null) {
        final endExclusive =
            DateTime(_toDate!.year, _toDate!.month, _toDate!.day)
                .add(const Duration(days: 1));
        if (dt == null || !dt.isBefore(endExclusive)) return false;
      }
      final amount = _rowAmount(row);
      if (_minAmount != null && amount < _minAmount!) return false;
      if (_maxAmount != null && amount > _maxAmount!) return false;
      if (query.isNotEmpty) {
        final haystack =
            '${row['type'] ?? ''} ${row['reference'] ?? ''}'.toLowerCase();
        if (!haystack.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  String _filterDescription() {
    final parts = <String>[];
    final df = DateFormat('dd MMM yyyy');
    if (_fromDate != null || _toDate != null) {
      final from = _fromDate == null ? 'Beginning' : df.format(_fromDate!);
      final to = _toDate == null ? 'Today' : df.format(_toDate!);
      parts.add('$from – $to');
    }
    if (_minAmount != null || _maxAmount != null) {
      final min = _minAmount?.toStringAsFixed(3) ?? '0.000';
      final max = _maxAmount?.toStringAsFixed(3) ?? 'Any';
      parts.add('Amount $min – $max');
    }
    if (_textFilter.trim().isNotEmpty)
      parts.add('Contains “${_textFilter.trim()}”');
    return parts.isEmpty ? 'All ledger entries' : parts.join(' • ');
  }

  void _clearFilters() {
    setState(() {
      _fromDate = null;
      _toDate = null;
      _minAmount = null;
      _maxAmount = null;
      _textFilter = '';
      _ledgerSearchController.clear();
      _page = 0;
    });
  }

  Future<void> _showFilterDialog() async {
    DateTime? from = _fromDate;
    DateTime? to = _toDate;
    final minController =
        TextEditingController(text: _minAmount?.toStringAsFixed(3) ?? '');
    final maxController =
        TextEditingController(text: _maxAmount?.toStringAsFixed(3) ?? '');
    final textController = TextEditingController(text: _textFilter);

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> pickDate(bool isFrom) async {
            final initial = (isFrom ? from : to) ?? DateTime.now();
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: initial,
              firstDate: DateTime(2000),
              lastDate: DateTime.now().add(const Duration(days: 3650)),
            );
            if (picked == null) return;
            setDialogState(() {
              if (isFrom) {
                from = picked;
                if (to != null && to!.isBefore(picked)) to = picked;
              } else {
                to = picked;
                if (from != null && from!.isAfter(picked)) from = picked;
              }
            });
          }

          String dateLabel(DateTime? value) => value == null
              ? 'Any date'
              : DateFormat('dd MMM yyyy').format(value);

          return AlertDialog(
            title: Text('Filter ${widget.partyType.toLowerCase()} ledger'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Date range',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(true),
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text('From: ${dateLabel(from)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pickDate(false),
                        icon: const Icon(Icons.event_outlined),
                        label: Text('To: ${dateLabel(to)}'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  const Text('Transaction amount',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: minController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Minimum amount'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: maxController,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Maximum amount'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  TextField(
                    controller: textController,
                    decoration: const InputDecoration(
                      labelText: 'Reference or transaction type',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  from = null;
                  to = null;
                  minController.clear();
                  maxController.clear();
                  textController.clear();
                  setDialogState(() {});
                },
                child: const Text('Reset'),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Apply Filter')),
            ],
          );
        },
      ),
    );

    if (result == true && mounted) {
      setState(() {
        _fromDate = from;
        _toDate = to;
        _minAmount = double.tryParse(minController.text.trim());
        _maxAmount = double.tryParse(maxController.text.trim());
        if (_minAmount != null && _minAmount! < 0) _minAmount = 0;
        if (_maxAmount != null && _maxAmount! < 0) _maxAmount = 0;
        _textFilter = textController.text.trim();
        _ledgerSearchController.text = _textFilter;
        _page = 0;
      });
    }
    minController.dispose();
    maxController.dispose();
    textController.dispose();
  }

  Future<void> _previewStatement(
    Map<String, Object?> party,
    List<Map<String, Object?>> rows, {
    required bool filtered,
  }) async {
    try {
      final subtitle = filtered ? _filterDescription() : 'Full account history';
      if (_customer) {
        await PrintService.printCustomerStatement(
          customer: party,
          rows: rows,
          statementSubtitle: subtitle,
        );
      } else {
        await PrintService.printSupplierStatement(
          supplier: party,
          rows: rows,
          statementSubtitle: subtitle,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${widget.partyType} statement: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  Future<void> _downloadStatement(
    Map<String, Object?> party,
    List<Map<String, Object?>> rows, {
    required bool filtered,
  }) async {
    try {
      final subtitle = filtered ? _filterDescription() : 'Full account history';
      final file = _customer
          ? await PrintService.prepareCustomerStatementPdf(
              customer: party,
              rows: rows,
              statementSubtitle: subtitle,
            )
          : await PrintService.prepareSupplierStatementPdf(
              supplier: party,
              rows: rows,
              statementSubtitle: subtitle,
            );
      final name = (party['name'] ?? widget.initialName).toString();
      final prefix = filtered ? 'Filtered' : 'Full';
      final saved = await DocumentShareService.savePdfAs(
        file,
        suggestedFileName:
            '${widget.partyType}_${prefix}_Statement_${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}.pdf',
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Statement saved to $saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Download statement: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  Future<void> _showStatementActions(
    Map<String, Object?> party,
    List<Map<String, Object?>> fullRows,
    List<Map<String, Object?>> filteredRows,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Statement'),
        children: [
          if (_hasFilters) ...[
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, 'preview_filtered'),
              child: const ListTile(
                  leading: Icon(Icons.visibility_outlined),
                  title: Text('Preview filtered statement'),
                  subtitle: Text('Uses the current ledger filters')),
            ),
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(dialogContext, 'download_filtered'),
              child: const ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Download filtered statement'),
                  subtitle: Text('Save only the currently filtered entries')),
            ),
            const Divider(),
          ],
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'preview_full'),
            child: const ListTile(
                leading: Icon(Icons.description_outlined),
                title: Text('Preview full statement'),
                subtitle: Text('All ledger entries')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'download_full'),
            child: const ListTile(
                leading: Icon(Icons.download_for_offline_outlined),
                title: Text('Download full statement'),
                subtitle: Text('Save the complete account history')),
          ),
        ],
      ),
    );
    if (choice == null) return;
    switch (choice) {
      case 'preview_filtered':
        await _previewStatement(party, filteredRows, filtered: true);
        break;
      case 'download_filtered':
        await _downloadStatement(party, filteredRows, filtered: true);
        break;
      case 'preview_full':
        await _previewStatement(party, fullRows, filtered: false);
        break;
      case 'download_full':
        await _downloadStatement(party, fullRows, filtered: false);
        break;
    }
  }

  String _date(Object? raw) {
    final value = raw?.toString() ?? '';
    final dt = DateTime.tryParse(value)?.toLocal();
    if (dt == null) return value;
    return DateFormat('dd MMM yyyy, HH:mm').format(dt);
  }

  Widget _summaryTile(
      BuildContext context, String label, String value, IconData icon,
      {Color? valueColor}) {
    return SizedBox(
      width: 190,
      child: ReliqGlass(
        blur: 12,
        radius: 15,
        reflectionStrength: .34,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: V3Style.labelAccent(context).withValues(alpha: .10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 20, color: V3Style.labelAccent(context)),
          ),
          const SizedBox(width: 11),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 3),
                Text(value,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: valueColor)),
              ])),
        ]),
      ),
    );
  }

  Widget _ledgerHeader(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    TextStyle style =
        TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: V3Style.tableHeader(context),
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(children: [
        SizedBox(width: 150, child: Text('DATE', style: style)),
        SizedBox(width: 130, child: Text('TYPE', style: style)),
        Expanded(flex: 3, child: Text('REFERENCE', style: style)),
        SizedBox(
            width: 120,
            child: Text(_customer ? 'CHARGE' : 'PAYABLE +',
                textAlign: TextAlign.right, style: style)),
        SizedBox(
            width: 120,
            child: Text(_customer ? 'PAYMENT / CREDIT' : 'PAYMENT / CREDIT',
                textAlign: TextAlign.right, style: style)),
        SizedBox(
            width: 125,
            child: Text('RUNNING', textAlign: TextAlign.right, style: style)),
      ]),
    );
  }

  Widget _ledgerRow(BuildContext context, Map<String, Object?> row, int index) {
    final debit = (row['debit'] as num? ?? 0).toDouble();
    final credit = (row['credit'] as num? ?? 0).toDouble();
    final running = (row['running_balance'] as num? ?? 0).toDouble();
    final type = (row['type'] ?? '').toString();
    final ref = (row['reference'] ?? '').toString();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      color: index.isOdd
          ? V3Style.rowStripe(context).withValues(alpha: dark ? .42 : .48)
          : Colors.transparent,
      child: Row(children: [
        SizedBox(
            width: 150,
            child: Text(_date(row['date']),
                style: TextStyle(fontSize: 12, color: muted))),
        SizedBox(
            width: 130,
            child: Text(type,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700))),
        Expanded(
            flex: 3,
            child:
                Text(ref.isEmpty ? '—' : ref, overflow: TextOverflow.ellipsis)),
        SizedBox(
            width: 120,
            child: Text(debit == 0 ? '—' : debit.toStringAsFixed(3),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight:
                        debit > 0 ? FontWeight.w700 : FontWeight.w400))),
        SizedBox(
            width: 120,
            child: Text(credit == 0 ? '—' : credit.toStringAsFixed(3),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: credit > 0 ? FontWeight.w700 : FontWeight.w400,
                    color: credit > 0 ? V3Style.success : null))),
        SizedBox(
            width: 125,
            child: Text(running.toStringAsFixed(3),
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: running > 0
                        ? Theme.of(context).colorScheme.error
                        : (running < 0 ? V3Style.success : null)))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ReliqWorkspaceBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: widget.onBack == null
              ? null
              : IconButton(
                  tooltip: 'Back to ${widget.partyType.toLowerCase()} list',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back)),
          automaticallyImplyLeading: widget.onBack == null,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text('${widget.partyType} Ledger'),
        ),
        body: FutureBuilder<_PartyLedgerData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: Text(
                      'Could not load ${widget.partyType.toLowerCase()} ledger: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return ReliqLoadingState(
                  message: 'Loading ${widget.partyType.toLowerCase()} ledger…',
                  detail:
                      'RELIQ is reading invoices, payments, returns and adjustments.');
            }
            final data = snapshot.data!;
            final party = data.party;
            final actions = widget.actionsBuilder(party);
            final balance = (party['balance'] as num? ?? 0).toDouble();
            final overdue = (party['overdue_balance'] as num? ?? 0).toDouble();
            final credit = (party['credit_balance'] as num? ?? 0).toDouble();
            final phone = (party['phone'] ?? '').toString();
            final whatsapp = (party['whatsapp'] ?? '').toString();
            final email = (party['email'] ?? '').toString();
            final address = (party['address'] ?? '').toString();
            final active = ((party['active'] as num?) ?? 1).toInt() == 1;
            final filteredRows = _filteredRows(data.rows);
            final totalPages =
                math.max(1, (filteredRows.length / _rowsPerPage).ceil());
            final currentPage = math.min(_page, totalPages - 1);
            final startIndex =
                filteredRows.isEmpty ? 0 : currentPage * _rowsPerPage;
            final endIndex =
                math.min(startIndex + _rowsPerPage, filteredRows.length);
            final pageRows = filteredRows.isEmpty
                ? <Map<String, Object?>>[]
                : filteredRows.sublist(startIndex, endIndex);

            return Padding(
              padding: V3Style.pagePadding,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ReliqGlass(
                      blur: 16,
                      strong: true,
                      radius: 18,
                      reflectionStrength: .42,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 54,
                                    height: 54,
                                    decoration: BoxDecoration(
                                      color: V3Style.labelAccent(context)
                                          .withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                    child: Icon(
                                        _customer
                                            ? Icons.person_outline
                                            : Icons.local_shipping_outlined,
                                        size: 28,
                                        color: V3Style.labelAccent(context)),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Row(children: [
                                          Flexible(
                                              child: Text(
                                                  (party['name'] ??
                                                          widget.initialName)
                                                      .toString(),
                                                  style: const TextStyle(
                                                      fontSize: 25,
                                                      fontWeight:
                                                          FontWeight.w900),
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                          const SizedBox(width: 10),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: (active
                                                      ? V3Style.success
                                                      : V3Style.muted)
                                                  .withValues(alpha: .10),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                  color: (active
                                                          ? V3Style.success
                                                          : V3Style.muted)
                                                      .withValues(alpha: .28)),
                                            ),
                                            child: Text(
                                                active ? 'Active' : 'Inactive',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w800,
                                                    color: active
                                                        ? V3Style.success
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant)),
                                          ),
                                        ]),
                                        const SizedBox(height: 5),
                                        Wrap(
                                            spacing: 14,
                                            runSpacing: 5,
                                            children: [
                                              if (phone.isNotEmpty)
                                                _InlineInfo(
                                                    Icons.phone_outlined,
                                                    phone),
                                              if (whatsapp.isNotEmpty &&
                                                  whatsapp != phone)
                                                _InlineInfo(Icons.chat_outlined,
                                                    whatsapp),
                                              if (email.isNotEmpty)
                                                _InlineInfo(
                                                    Icons.mail_outline, email),
                                              if (address.isNotEmpty)
                                                _InlineInfo(
                                                    Icons.location_on_outlined,
                                                    address),
                                            ]),
                                      ])),
                                ]),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: actions.map((action) {
                                if (action.primary) {
                                  return FilledButton.icon(
                                    onPressed: () => _runAction(action),
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 42),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                    ),
                                    icon: Icon(action.icon, size: 18),
                                    label: Text(action.label),
                                  );
                                }
                                final compactStyle = OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 38),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 11, vertical: 8),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  textStyle: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700),
                                  foregroundColor: action.danger
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                );
                                return OutlinedButton.icon(
                                  onPressed: () => _runAction(action),
                                  style: compactStyle,
                                  icon: Icon(action.icon, size: 17),
                                  label: Text(action.label),
                                );
                              }).toList(),
                            ),
                          ]),
                    ),
                    const SizedBox(height: 14),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      _summaryTile(
                          context,
                          _customer ? 'Outstanding' : 'Payable',
                          balance.toStringAsFixed(3),
                          _customer
                              ? Icons.receipt_long_outlined
                              : Icons.account_balance_wallet_outlined,
                          valueColor: balance > 0
                              ? Theme.of(context).colorScheme.error
                              : null),
                      _summaryTile(context, 'Overdue',
                          overdue.toStringAsFixed(3), Icons.schedule_outlined,
                          valueColor: overdue > 0 ? V3Style.danger : null),
                      _summaryTile(
                          context,
                          _customer ? 'Account credit' : 'Supplier advance',
                          credit.toStringAsFixed(3),
                          Icons.savings_outlined,
                          valueColor: credit > 0 ? V3Style.success : null),
                      _summaryTile(
                          context,
                          'Open documents',
                          '${data.openItems.length} • ${data.openTotal.toStringAsFixed(3)}',
                          Icons.folder_open_outlined),
                      if (_customer)
                        _summaryTile(
                            context,
                            'Credit terms',
                            '${party['terms_days'] ?? 0} days',
                            Icons.event_available_outlined)
                      else
                        _summaryTile(
                            context,
                            'Terms / lead',
                            '${party['terms_days'] ?? 0}d / ${party['lead_days'] ?? 0}d',
                            Icons.local_shipping_outlined),
                    ]),
                    const SizedBox(height: 14),
                    Expanded(
                      child: ReliqGlass(
                        blur: 10,
                        radius: 18,
                        reflectionStrength: .20,
                        padding: EdgeInsets.zero,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 12, 10),
                                child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text('Ledger History',
                                                  style: TextStyle(
                                                      fontSize: 17,
                                                      fontWeight:
                                                          FontWeight.w900)),
                                              const SizedBox(height: 2),
                                              Text(
                                                _hasFilters
                                                    ? '${filteredRows.length} matching of ${data.rows.length} entries'
                                                    : '${data.rows.length} entries',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant),
                                              ),
                                            ]),
                                      ),
                                      Flexible(
                                        child: Wrap(
                                          alignment: WrapAlignment.end,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            SizedBox(
                                              width: 280,
                                              height: 38,
                                              child: TextField(
                                                controller:
                                                    _ledgerSearchController,
                                                focusNode: _ledgerSearchFocus,
                                                textInputAction:
                                                    TextInputAction.search,
                                                onChanged: (value) {
                                                  setState(() {
                                                    _textFilter = value.trim();
                                                    _page = 0;
                                                  });
                                                },
                                                decoration: InputDecoration(
                                                  isDense: true,
                                                  prefixIcon: const Icon(
                                                      Icons.search,
                                                      size: 18),
                                                  hintText:
                                                      'Search reference or type',
                                                  suffixIcon: _textFilter
                                                          .isEmpty
                                                      ? null
                                                      : IconButton(
                                                          tooltip:
                                                              'Clear ledger search',
                                                          onPressed: () {
                                                            _ledgerSearchController
                                                                .clear();
                                                            setState(() {
                                                              _textFilter = '';
                                                              _page = 0;
                                                            });
                                                            _ledgerSearchFocus
                                                                .requestFocus();
                                                          },
                                                          icon: const Icon(
                                                              Icons.close,
                                                              size: 17),
                                                        ),
                                                ),
                                              ),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: _showFilterDialog,
                                              style: OutlinedButton.styleFrom(
                                                minimumSize: const Size(0, 38),
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 11),
                                              ),
                                              icon: Icon(
                                                  _hasFilters
                                                      ? Icons.filter_alt
                                                      : Icons
                                                          .filter_alt_outlined,
                                                  size: 17),
                                              label: Text(_hasFilters
                                                  ? 'Filtered'
                                                  : 'Filter'),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: () =>
                                                  _showStatementActions(party,
                                                      data.rows, filteredRows),
                                              style: OutlinedButton.styleFrom(
                                                minimumSize: const Size(0, 38),
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 11),
                                              ),
                                              icon: const Icon(
                                                  Icons.picture_as_pdf_outlined,
                                                  size: 17),
                                              label: const Text('Statement'),
                                            ),
                                            IconButton(
                                              tooltip: 'Refresh ledger',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: _reload,
                                              icon: const Icon(Icons.refresh),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ]),
                              ),
                              if (_hasFilters)
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 9),
                                  child: Row(children: [
                                    Expanded(
                                      child: Text(
                                        _filterDescription(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: V3Style.labelAccent(context),
                                            fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: _clearFilters,
                                      icon: const Icon(Icons.close, size: 16),
                                      label: const Text('Clear'),
                                    ),
                                  ]),
                                ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context).dividerColor),
                              _ledgerHeader(context),
                              Expanded(
                                child: filteredRows.isEmpty
                                    ? Center(
                                        child: Text(
                                          data.rows.isEmpty
                                              ? 'No ledger activity recorded yet.'
                                              : 'No ledger entries match the current filter.',
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant),
                                        ),
                                      )
                                    : ListView.separated(
                                        itemCount: pageRows.length,
                                        separatorBuilder: (_, __) => Divider(
                                            height: 1,
                                            color: Theme.of(context)
                                                .dividerColor
                                                .withValues(alpha: .65)),
                                        itemBuilder: (context, index) =>
                                            _ledgerRow(context, pageRows[index],
                                                startIndex + index),
                                      ),
                              ),
                              Divider(
                                  height: 1,
                                  color: Theme.of(context).dividerColor),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                child: Row(children: [
                                  Text(
                                    filteredRows.isEmpty
                                        ? '0 entries'
                                        : 'Showing ${startIndex + 1}–$endIndex of ${filteredRows.length}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                  const Spacer(),
                                  const Text('Rows:',
                                      style: TextStyle(fontSize: 12)),
                                  const SizedBox(width: 6),
                                  DropdownButton<int>(
                                    value: _rowsPerPage,
                                    isDense: true,
                                    items: const [10, 25, 50]
                                        .map((value) => DropdownMenuItem(
                                            value: value,
                                            child: Text('$value')))
                                        .toList(),
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(() {
                                        _rowsPerPage = value;
                                        _page = 0;
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                      'Page ${filteredRows.isEmpty ? 0 : currentPage + 1} of ${filteredRows.isEmpty ? 0 : totalPages}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700)),
                                  IconButton(
                                    tooltip: 'Previous page',
                                    onPressed: currentPage <= 0
                                        ? null
                                        : () => setState(
                                            () => _page = currentPage - 1),
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  IconButton(
                                    tooltip: 'Next page',
                                    onPressed: filteredRows.isEmpty ||
                                            currentPage >= totalPages - 1
                                        ? null
                                        : () => setState(
                                            () => _page = currentPage + 1),
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                ]),
                              ),
                            ]),
                      ),
                    ),
                  ]),
            );
          },
        ),
      ),
    );
  }
}

class _InlineInfo extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InlineInfo(this.icon, this.text);

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon,
            size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]);
}

class _PartyLedgerData {
  final Map<String, Object?> party;
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> openItems;
  final double openTotal;

  const _PartyLedgerData(
      {required this.party,
      required this.rows,
      required this.openItems,
      required this.openTotal});
}
