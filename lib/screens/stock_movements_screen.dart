import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_loading.dart';

class StockMovementsScreen extends StatefulWidget {
  const StockMovementsScreen({super.key});

  @override
  State<StockMovementsScreen> createState() => _StockMovementsScreenState();
}

class _StockMovementsScreenState extends State<StockMovementsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int refreshKey = 0;
  String activityQuery = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _newTransfer() async {
    final branches = (await AppDatabase.instance.branches())
        .where((b) => (b['active'] as num? ?? 0).toInt() == 1)
        .toList();
    if (!mounted) return;
    if (branches.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Add at least two active branches in Users & Roles before creating a stock transfer.')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => _StockTransferDialog(branches: branches),
    );
    if (ok == true && mounted) setState(() => refreshKey++);
  }

  Future<void> _transitionTransfer(
      Map<String, Object?> row, String action) async {
    try {
      final id = row['id'].toString();
      if (action == 'send') await AppDatabase.instance.sendStockTransfer(id);
      if (action == 'receive')
        await AppDatabase.instance.receiveStockTransfer(id);
      if (action == 'reject')
        await AppDatabase.instance.rejectStockTransfer(id);
      if (!mounted) return;
      setState(() => refreshKey++);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Transfer ${row['no']} ${action == 'send' ? 'sent' : action == 'receive' ? 'received' : 'rejected'} successfully.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Stock Transfers',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text(
                      'Move stock safely between branches. Every transfer is recorded in the inventory audit trail.',
                      style: TextStyle(color: V3Style.muted)),
                ])),
            FilledButton.icon(
                onPressed: _newTransfer,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('New Transfer')),
          ]),
          const SizedBox(height: 14),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const [
              Tab(text: 'Branch Transfers'),
              Tab(text: 'Inventory Activity Audit')
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
              child: TabBarView(
                  controller: _tabs, children: [_transfers(), _activity()])),
        ]),
      );

  Widget _transfers() => FutureBuilder<List<Map<String, Object?>>>(
        key: ValueKey('tr-$refreshKey'),
        future: AppDatabase.instance.stockTransfers(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return Center(child: Text('${snapshot.error}'));
          if (!snapshot.hasData)
            return const ReliqLoadingState(
                message: 'Loading stock transfers…',
                detail: 'RELIQ is checking branch movements.');
          final rows = snapshot.data!;
          if (rows.isEmpty) {
            return const Card(
                child: Center(
                    child: Padding(
                        padding: EdgeInsets.all(36),
                        child: Text(
                            'No branch transfers yet.\nUse New Transfer to move stock between locations.',
                            textAlign: TextAlign.center))));
          }
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Container(
                  height: (Theme.of(context).listTileTheme.minTileHeight ?? 40)
                      .clamp(40, 60)
                      .toDouble(),
                  color: V3Style.tableHeader(context),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: const Row(children: [
                    SizedBox(
                        width: 180,
                        child: Text('TRANSFER',
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    SizedBox(
                        width: 150,
                        child: Text('DATE',
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    Expanded(
                        child: Text('FROM → TO',
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    SizedBox(
                        width: 90,
                        child: Text('LINES',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    SizedBox(
                        width: 110,
                        child: Text('QTY',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    SizedBox(
                        width: 100,
                        child: Text('STATUS',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                    SizedBox(
                        width: 150,
                        child: Text('ACTIONS',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w800))),
                  ])),
              Expanded(
                  child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        final dt =
                            DateTime.tryParse('${r['created_at'] ?? ''}');
                        return Container(
                            constraints: BoxConstraints(
                                minHeight: (Theme.of(context)
                                            .listTileTheme
                                            .minTileHeight ??
                                        54)
                                    .clamp(54, 72)
                                    .toDouble()),
                            color: i.isOdd
                                ? V3Style.rowStripe(context)
                                : Colors.transparent,
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14),
                                child: Row(children: [
                                  SizedBox(
                                      width: 180,
                                      child: Text('${r['no']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700))),
                                  SizedBox(
                                      width: 150,
                                      child: Text(dt == null
                                          ? '—'
                                          : DateFormat('dd MMM yyyy, HH:mm')
                                              .format(dt.toLocal()))),
                                  Expanded(
                                      child: Text(
                                          '${r['from_branch'] ?? '—'}  →  ${r['to_branch'] ?? '—'}',
                                          overflow: TextOverflow.ellipsis)),
                                  SizedBox(
                                      width: 90,
                                      child: Text('${r['line_count'] ?? 0}',
                                          textAlign: TextAlign.right)),
                                  SizedBox(
                                      width: 110,
                                      child: Text(
                                          ((r['total_qty'] as num?) ?? 0)
                                              .toStringAsFixed(2),
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700))),
                                  SizedBox(
                                      width: 100,
                                      child: Text(
                                          '${r['status'] ?? 'Requested'}',
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700))),
                                  SizedBox(
                                      width: 150,
                                      child: Align(
                                          alignment: Alignment.centerRight,
                                          child: Builder(builder: (context) {
                                            final status =
                                                (r['status'] ?? 'Requested')
                                                    .toString();
                                            final actions =
                                                <PopupMenuEntry<String>>[
                                              if (status == 'Requested')
                                                const PopupMenuItem(
                                                    value: 'send',
                                                    child: Text('Mark Sent')),
                                              if (status == 'Sent')
                                                const PopupMenuItem(
                                                    value: 'receive',
                                                    child: Text(
                                                        'Receive at branch')),
                                              if (status == 'Requested' ||
                                                  status == 'Sent')
                                                const PopupMenuItem(
                                                    value: 'reject',
                                                    child: Text(
                                                        'Reject / Return')),
                                            ];
                                            if (actions.isEmpty)
                                              return const Icon(
                                                  Icons.check_circle_outline,
                                                  size: 18);
                                            return PopupMenuButton<String>(
                                                tooltip: 'Transfer actions',
                                                onSelected: (v) =>
                                                    _transitionTransfer(r, v),
                                                itemBuilder: (_) => actions);
                                          }))),
                                ])));
                      })),
            ]),
          );
        },
      );

  Widget _activity() => Column(children: [
        TextField(
            onChanged: (v) =>
                setState(() => activityQuery = v.toLowerCase().trim()),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText:
                    'Filter product, SKU, type, transfer number or reason')),
        const SizedBox(height: 12),
        Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
          key: ValueKey('act-$refreshKey'),
          future: AppDatabase.instance.stockMovements(),
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(child: Text('${snapshot.error}'));
            if (!snapshot.hasData)
              return const ReliqLoadingState(
                  message: 'Loading stock activity…',
                  detail: 'RELIQ is reading movement history.');
            final all = snapshot.data!;
            final rows = activityQuery.isEmpty
                ? all
                : all
                    .where((r) => ['name', 'sku', 'type', 'reference', 'reason']
                        .any((k) => '${r[k] ?? ''}'
                            .toLowerCase()
                            .contains(activityQuery)))
                    .toList();
            if (rows.isEmpty)
              return const Center(child: Text('No inventory activity found.'));
            return Card(
                child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final change = (r['qty_change'] as num? ?? 0).toDouble();
                      final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                            radius: 17,
                            child: Icon(
                                change >= 0
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                size: 16)),
                        title: Text('${r['name'] ?? 'Unknown product'}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${r['type'] ?? ''} • ${r['reference'] ?? ''}${('${r['reason'] ?? ''}').isNotEmpty ? ' • ${r['reason']}' : ''}${dt == null ? '' : ' • ${DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal())}'}'),
                        trailing: Text(
                            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}',
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: change >= 0
                                    ? const Color(0xFF1C8A5A)
                                    : Theme.of(context).colorScheme.error)),
                      );
                    }));
          },
        )),
      ]);
}

class _StockTransferDialog extends StatefulWidget {
  final List<Map<String, Object?>> branches;
  const _StockTransferDialog({required this.branches});
  @override
  State<_StockTransferDialog> createState() => _StockTransferDialogState();
}

class _StockTransferDialogState extends State<_StockTransferDialog> {
  late String fromBranch;
  late String toBranch;
  String search = '';
  String notes = '';
  final lines = <Map<String, Object?>>[];

  @override
  void initState() {
    super.initState();
    fromBranch = widget.branches.first['id'].toString();
    toBranch = widget.branches[1]['id'].toString();
  }

  void _add(Map<String, Object?> p) {
    final id = p['id'].toString();
    final existing = lines.indexWhere((x) => x['product_id'] == id);
    if (existing >= 0) {
      final available = (p['branch_stock'] as num? ?? 0).toDouble();
      final next = (lines[existing]['qty'] as num).toDouble() + 1;
      if (next <= available) setState(() => lines[existing]['qty'] = next);
      return;
    }
    setState(() => lines.add({
          'product_id': id,
          'name': p['name'],
          'sku': p['sku'],
          'available': (p['branch_stock'] as num? ?? 0).toDouble(),
          'qty': 1.0
        }));
  }

  Future<void> _save() async {
    try {
      final no = await AppDatabase.instance.createStockTransfer(
          fromBranchId: fromBranch,
          toBranchId: toBranch,
          items: lines,
          notes: notes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Transfer $no requested. Use the transfer list to mark it Sent and then Received.')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(28),
        child: SizedBox(
          width: 980,
          height: 720,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('New Branch Stock Transfer',
                          style: TextStyle(
                              fontSize: 21, fontWeight: FontWeight.w800)),
                      SizedBox(height: 3),
                      Text(
                          'Request stock movement. Stock leaves the source only when marked Sent and reaches the destination only when marked Received.',
                          style: TextStyle(color: V3Style.muted))
                    ])),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                    child: DropdownButtonFormField<String>(
                        value: fromBranch,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'From branch'),
                        items: [
                          for (final b in widget.branches)
                            DropdownMenuItem(
                                value: b['id'].toString(),
                                child: Text('${b['name']}'))
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            fromBranch = v;
                            lines.clear();
                          });
                        })),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.arrow_forward)),
                Expanded(
                    child: DropdownButtonFormField<String>(
                        value: toBranch,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'To branch'),
                        items: [
                          for (final b in widget.branches)
                            DropdownMenuItem(
                                value: b['id'].toString(),
                                child: Text('${b['name']}'))
                        ],
                        onChanged: (v) =>
                            setState(() => toBranch = v ?? toBranch))),
              ]),
              const SizedBox(height: 12),
              TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText:
                          'Search source branch products by name, SKU or barcode'),
                  onChanged: (v) => setState(() => search = v)),
              if (search.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                    height: 150,
                    child: FutureBuilder<List<Map<String, Object?>>>(
                        future: AppDatabase.instance
                            .branchInventory(fromBranch, search: search),
                        builder: (context, snap) {
                          final rows = snap.data ?? [];
                          if (rows.isEmpty)
                            return const Center(
                                child: Text(
                                    'No matching products at this branch.'));
                          return ListView.separated(
                              itemCount: rows.take(8).length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final p = rows[i];
                                final qty =
                                    (p['branch_stock'] as num? ?? 0).toDouble();
                                return ListTile(
                                    dense: true,
                                    title: Text('${p['name']}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                    subtitle: Text(
                                        '${p['sku'] ?? '—'} • Available ${qty.toStringAsFixed(2)} ${p['unit'] ?? ''}'),
                                    trailing: IconButton(
                                        onPressed:
                                            qty <= 0 ? null : () => _add(p),
                                        icon: const Icon(
                                            Icons.add_circle_outline)));
                              });
                        })),
              ],
              const SizedBox(height: 10),
              Expanded(
                  child: Card(
                      child: lines.isEmpty
                          ? const Center(
                              child: Text('No products selected for transfer.'))
                          : ListView.separated(
                              itemCount: lines.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final x = lines[i];
                                return ListTile(
                                  title: Text('${x['name']}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  subtitle: Text(
                                      '${x['sku'] ?? '—'} • Available ${(x['available'] as num).toStringAsFixed(2)}'),
                                  trailing: SizedBox(
                                      width: 220,
                                      child: Row(children: [
                                        Expanded(
                                            child: TextFormField(
                                                initialValue: (x['qty'] as num)
                                                    .toString(),
                                                textAlign: TextAlign.right,
                                                keyboardType:
                                                    const TextInputType
                                                        .numberWithOptions(
                                                        decimal: true),
                                                decoration:
                                                    const InputDecoration(
                                                        labelText:
                                                            'Transfer qty'),
                                                onChanged: (v) {
                                                  final q =
                                                      double.tryParse(v) ?? 0;
                                                  x['qty'] = q;
                                                })),
                                        const SizedBox(width: 6),
                                        IconButton(
                                            onPressed: () => setState(
                                                () => lines.removeAt(i)),
                                            icon: const Icon(
                                                Icons.delete_outline)),
                                      ])),
                                );
                              }))),
              const SizedBox(height: 10),
              TextFormField(
                  decoration: const InputDecoration(
                      labelText: 'Transfer note (optional)'),
                  onChanged: (v) => notes = v),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed:
                        lines.isEmpty || fromBranch == toBranch ? null : _save,
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Request Transfer'))
              ]),
            ]),
          ),
        ),
      );
}
