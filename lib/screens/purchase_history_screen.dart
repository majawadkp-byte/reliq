import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/print_service.dart';
import '../ui/pagination_bar.dart';
import '../ui/reliq_loading.dart';
import '../ui/v3_style.dart';

class PurchaseHistoryScreen extends StatefulWidget {
  const PurchaseHistoryScreen({super.key});
  @override
  State<PurchaseHistoryScreen> createState() => _PurchaseHistoryScreenState();
}

class _PurchaseHistoryScreenState extends State<PurchaseHistoryScreen> {
  final search = TextEditingController();
  String query = '';
  String status = 'All';
  String sort = 'Newest';
  int page = 0;
  int pageSize = 10;
  DateTime? from;
  DateTime? to;
  String datePreset = 'Today';
  bool canEdit = false;
  late Future<Map<String, Object>> _historyFuture;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _applyDatePreset('Today', notify: false);
    _historyFuture = _load();
    AppDatabase.instance.canEditTransactions().then((v) {
      if (mounted) setState(() => canEdit = v);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<Map<String, Object>> _load() =>
      AppDatabase.instance.purchaseHistoryPage(
        limit: pageSize,
        offset: page * pageSize,
        search: query,
        status: status,
        sort: sort,
        from: from,
        to: to,
      );

  void _reload([VoidCallback? mutation]) {
    if (!mounted) return;
    setState(() {
      mutation?.call();
      _historyFuture = _load();
    });
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      _reload(() {
        query = value.trim();
        page = 0;
      });
    });
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  void _applyDatePreset(String preset, {bool notify = true}) {
    final today = _dateOnly(DateTime.now());
    void apply() {
      datePreset = preset;
      if (preset == 'Today') {
        from = today;
        to = today;
      } else if (preset == 'Yesterday') {
        final yesterday = today.subtract(const Duration(days: 1));
        from = yesterday;
        to = yesterday;
      } else if (preset == 'This month') {
        from = DateTime(today.year, today.month, 1);
        to = today;
      } else if (preset == 'Custom') {
        from ??= today;
        to ??= today;
      }
      page = 0;
    }

    if (notify) {
      _reload(apply);
    } else {
      apply();
    }
  }

  Future<void> _pickDate(bool start) async {
    final initial = start ? (from ?? DateTime.now()) : (to ?? DateTime.now());
    final value = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2000),
        lastDate: DateTime.now().add(const Duration(days: 366)));
    if (value == null) return;
    _reload(() {
      datePreset = 'Custom';
      if (start) {
        from = value;
        if (to != null && to!.isBefore(value)) to = value;
      } else {
        to = value;
        if (from != null && from!.isAfter(value)) from = value;
      }
      page = 0;
    });
  }

  Future<void> _correct(Map<String, Object?> row) async {
    try {
      final data = await AppDatabase.instance
          .purchaseCorrectionData(row['id'].toString());
      if (!mounted) return;
      final header = (data['header'] as Map).cast<String, Object?>();
      final lines = (data['lines'] as List)
          .map((x) => Map<String, Object?>.from(x as Map))
          .toList();
      double freight = (header['freight'] as num? ?? 0).toDouble();
      double other = (header['other_charges'] as num? ?? 0).toDouble();
      String notes = (header['notes'] ?? '').toString();
      final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                title: Text('Correct Purchase ${header['no']}'),
                content: SizedBox(
                    width: 820,
                    height: 520,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              'Owner/Manager correction. Quantities stay locked so stock movements remain intact; costs, discount, tax and charges are audited.',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: V3Style.mutedFor(context))),
                          const SizedBox(height: 10),
                          Expanded(
                              child: ListView.separated(
                                  itemCount: lines.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, i) {
                                    final line = lines[i];
                                    final qty =
                                        (line['qty'] as num? ?? 0).toDouble();
                                    return Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6),
                                        child: Row(children: [
                                          Expanded(
                                              flex: 3,
                                              child: Text(
                                                  '${line['name']}\nQty ${qty.toStringAsFixed(2)}',
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700))),
                                          const SizedBox(width: 8),
                                          Expanded(
                                              child: TextFormField(
                                                  initialValue:
                                                      (line['unit_cost']
                                                                  as num? ??
                                                              0)
                                                          .toString(),
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Unit cost'),
                                                  onChanged: (v) =>
                                                      line['unit_cost'] =
                                                          double.tryParse(v) ??
                                                              0)),
                                          const SizedBox(width: 8),
                                          Expanded(
                                              child: TextFormField(
                                                  initialValue:
                                                      (line['discount']
                                                                  as num? ??
                                                              0)
                                                          .toString(),
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Discount'),
                                                  onChanged: (v) =>
                                                      line['discount'] =
                                                          double.tryParse(v) ??
                                                              0)),
                                          const SizedBox(width: 8),
                                          Expanded(
                                              child: TextFormField(
                                                  initialValue:
                                                      (line['tax'] as num? ?? 0)
                                                          .toString(),
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Tax amount'),
                                                  onChanged: (v) =>
                                                      line['tax'] =
                                                          double.tryParse(v) ??
                                                              0))
                                        ]));
                                  })),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                                child: TextFormField(
                                    initialValue: freight.toString(),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Freight / delivery'),
                                    onChanged: (v) =>
                                        freight = double.tryParse(v) ?? 0)),
                            const SizedBox(width: 8),
                            Expanded(
                                child: TextFormField(
                                    initialValue: other.toString(),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Other charges'),
                                    onChanged: (v) =>
                                        other = double.tryParse(v) ?? 0))
                          ]),
                          const SizedBox(height: 8),
                          TextFormField(
                              initialValue: notes,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Correction note / purchase notes'),
                              onChanged: (v) => notes = v),
                        ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel')),
                  FilledButton.icon(
                      onPressed: () => Navigator.pop(c, true),
                      icon: const Icon(Icons.save_outlined, size: 17),
                      label: const Text('Save Correction'))
                ],
              ));
      if (ok == true) {
        await AppDatabase.instance.revisePurchaseFinancials(
            purchaseId: row['id'].toString(),
            lines: lines,
            freight: freight,
            otherCharges: other,
            notes: notes);
        if (mounted) _reload();
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _void(Map<String, Object?> row) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Void Purchase ${row['no']}?'),
        content: SizedBox(
            width: 500,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'This is an audited reversal, not a delete. RELIQ will reverse stock, open balance and linked payment impact. This cannot be used when posted returns already exist.'),
                  const SizedBox(height: 12),
                  TextField(
                      controller: reason,
                      autofocus: true,
                      decoration: const InputDecoration(
                          labelText: 'Reason for void *')),
                ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error),
              child: const Text('Void & Reverse')),
        ],
      ),
    );
    if (ok != true) {
      Future<void>.delayed(const Duration(milliseconds: 450), reason.dispose);
      return;
    }
    if (reason.text.trim().isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('A void reason is required.')));
      Future<void>.delayed(const Duration(milliseconds: 450), reason.dispose);
      return;
    }
    try {
      await AppDatabase.instance
          .voidPurchase(row['id'].toString(), reason: reason.text.trim());
      if (mounted) {
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Purchase ${row['no']} was voided and reversed.')));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      Future<void>.delayed(const Duration(milliseconds: 450), reason.dispose);
    }
  }

  Future<void> _print(Map<String, Object?> row) async {
    showReliqWorkingSnack(
        context, 'Preparing purchase ${row['no']}… RELIQ is still working.');
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final data = await AppDatabase.instance
          .purchaseCorrectionData(row['id'].toString());
      await PrintService.printPurchaseFromData(data);
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Purchase document opened in system preview.')));
      }
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Print failed: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: V3Style.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Purchase History',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            'Search, filter and page through supplier receipts without loading the entire history.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 14),
        _filters(),
        const SizedBox(height: 12),
        Expanded(
            child: FutureBuilder<Map<String, Object>>(
          future: _historyFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(
                  child: Text(
                      'Purchase history could not load: ${snapshot.error}'));
            if (snapshot.connectionState == ConnectionState.waiting ||
                !snapshot.hasData)
              return const ReliqLoadingState(
                  message: 'Loading purchase history…',
                  detail: 'RELIQ is still working.');
            final rows =
                (snapshot.data!['rows'] as List).cast<Map<String, Object?>>();
            final total = snapshot.data!['total'] as int;
            if (rows.isEmpty && total == 0)
              return const Card(
                  child:
                      Center(child: Text('No purchases match these filters.')));
            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                Expanded(
                    child: LayoutBuilder(
                        builder: (context, c) => SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                  width: c.maxWidth < 1110 ? 1110 : c.maxWidth,
                                  child: Column(children: [
                                    _header(),
                                    Expanded(
                                        child: ListView.builder(
                                            itemCount: rows.length,
                                            itemBuilder: (context, i) =>
                                                _row(rows[i], i))),
                                  ])),
                            ))),
                V4PaginationBar(
                  total: total,
                  page: page,
                  pageSize: pageSize,
                  onPageChanged: (v) => _reload(() => page = v),
                  onPageSizeChanged: (v) => _reload(() {
                    pageSize = v;
                    page = 0;
                  }),
                ),
              ]),
            );
          },
        )),
      ]),
    );
  }

  Widget _filters() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
              spacing: 9,
              runSpacing: 9,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                    width: 310,
                    child: TextField(
                      controller: search,
                      onChanged: _searchChanged,
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText:
                              'Purchase no., supplier, phone, document no.'),
                    )),
                SizedBox(
                    width: 145,
                    child: DropdownButtonFormField<String>(
                      value: status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const ['All', 'Paid', 'Due']
                          .map(
                              (x) => DropdownMenuItem(value: x, child: Text(x)))
                          .toList(),
                      onChanged: (v) => _reload(() {
                        status = v ?? 'All';
                        page = 0;
                      }),
                    )),
                SizedBox(
                    width: 155,
                    child: DropdownButtonFormField<String>(
                      value: sort,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Sort'),
                      items: const [
                        'Newest',
                        'Oldest',
                        'Total high',
                        'Total low',
                        'Due high'
                      ]
                          .map(
                              (x) => DropdownMenuItem(value: x, child: Text(x)))
                          .toList(),
                      onChanged: (v) => _reload(() {
                        sort = v ?? 'Newest';
                        page = 0;
                      }),
                    )),
                _datePresetButton('Today'),
                _datePresetButton('Yesterday'),
                _datePresetButton('This month'),
                _datePresetButton('Custom'),
                if (datePreset == 'Custom') ...[
                  OutlinedButton.icon(
                      onPressed: () => _pickDate(true),
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(from == null
                          ? 'From'
                          : DateFormat('dd MMM yyyy').format(from!))),
                  OutlinedButton.icon(
                      onPressed: () => _pickDate(false),
                      icon: const Icon(Icons.event_outlined, size: 16),
                      label: Text(to == null
                          ? 'To'
                          : DateFormat('dd MMM yyyy').format(to!))),
                ],
              ]),
        ),
      );

  Widget _datePresetButton(String preset) {
    final selected = datePreset == preset;
    return OutlinedButton(
      onPressed: () => _applyDatePreset(preset),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primary.withValues(
                alpha:
                    Theme.of(context).brightness == Brightness.dark ? .16 : .10)
            : null,
        foregroundColor:
            selected ? Theme.of(context).colorScheme.primary : null,
        side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor),
      ),
      child: Text(preset,
          style: TextStyle(
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
    );
  }

  Widget _header() => Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        color: V3Style.tableHeader(context),
        child: const Row(children: [
          Expanded(flex: 3, child: Text('PURCHASE / SUPPLIER', style: _head)),
          SizedBox(width: 150, child: Text('DATE', style: _head)),
          SizedBox(width: 150, child: Text('DOCUMENT / STATUS', style: _head)),
          SizedBox(width: 130, child: Text('BRANCH / USER', style: _head)),
          SizedBox(
              width: 90,
              child: Text('TOTAL', textAlign: TextAlign.right, style: _head)),
          SizedBox(
              width: 90,
              child: Text('DUE', textAlign: TextAlign.right, style: _head)),
          SizedBox(
              width: 54,
              child: Text('PRINT', textAlign: TextAlign.center, style: _head)),
          SizedBox(
              width: 54,
              child: Text('EDIT', textAlign: TextAlign.center, style: _head)),
        ]),
      );

  Widget _row(Map<String, Object?> r, int i) {
    final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
    final balance = (r['balance'] as num? ?? 0).toDouble();
    return V4AlternateRow(
        index: i,
        child: Row(children: [
          Expanded(
              flex: 3,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${r['no'] ?? '—'}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('${r['supplier_name'] ?? 'Supplier'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: V3Style.mutedFor(context))),
                  ])),
          SizedBox(
              width: 150,
              child: Text(
                  dt == null
                      ? '—'
                      : DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal()),
                  style: const TextStyle(fontSize: 12))),
          SizedBox(
              width: 150,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${r['document_no'] ?? '—'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                    Text(
                        balance > 0
                            ? 'Balance due'
                            : '${r['status'] ?? 'Received'}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: balance > 0
                                ? const Color(0xFFB45309)
                                : const Color(0xFF16794C))),
                  ])),
          SizedBox(
              width: 130,
              child: Text(
                  '${r['branch_name'] ?? '—'}\n${r['user_name'] ?? '—'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10))),
          SizedBox(
              width: 90,
              child: Text((r['total'] as num? ?? 0).toStringAsFixed(3),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          SizedBox(
              width: 90,
              child: Text(balance.toStringAsFixed(3),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: balance > 0
                          ? Theme.of(context).colorScheme.error
                          : null))),
          SizedBox(
              width: 54,
              child: IconButton(
                  tooltip: 'Print / reprint',
                  onPressed: () => _print(r),
                  icon: const Icon(Icons.print_outlined, size: 18))),
          SizedBox(
              width: 54,
              child: canEdit
                  ? PopupMenuButton<String>(
                      tooltip: 'Admin actions',
                      icon: const Icon(Icons.more_vert, size: 19),
                      onSelected: (v) {
                        if (v == 'edit') _correct(r);
                        if (v == 'void') _void(r);
                      },
                      itemBuilder: (context) => const [
                            PopupMenuItem(
                                value: 'edit',
                                child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.edit_note_outlined),
                                    title: Text('Financial correction'))),
                            PopupMenuItem(
                                value: 'void',
                                child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.cancel_outlined),
                                    title: Text('Void & reverse')))
                          ])
                  : const SizedBox.shrink()),
        ]));
  }
}

const _head =
    TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: V3Style.muted);
