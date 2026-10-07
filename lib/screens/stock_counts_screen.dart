import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_loading.dart';

class StockCountsScreen extends StatefulWidget {
  const StockCountsScreen({super.key});

  @override
  State<StockCountsScreen> createState() => _StockCountsScreenState();
}

class _StockCountsScreenState extends State<StockCountsScreen> {
  int refreshKey = 0;

  Future<void> _newCount() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => const _NewStockCountDialog(),
    );
    if (ok == true && mounted) setState(() => refreshKey++);
  }

  Future<void> _open(Map<String, Object?> count) async {
    final lines = await AppDatabase.instance.stockCountItems(count['id'].toString());
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => _StockCountEntryDialog(count: count, lines: lines),
    );
    if (ok == true && mounted) setState(() => refreshKey++);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Physical Stock Counts', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              SizedBox(height: 3),
              Text('Count multiple products, review variance, then post one audited inventory correction.', style: TextStyle(color: V3Style.muted)),
            ])),
            FilledButton.icon(onPressed: _newCount, icon: const Icon(Icons.fact_check_outlined), label: const Text('New Count')),
          ]),
          const SizedBox(height: 14),
          Expanded(child: FutureBuilder<List<Map<String, Object?>>>(
            key: ValueKey(refreshKey),
            future: AppDatabase.instance.stockCounts(),
            builder: (context, snapshot) {
              if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
              if (!snapshot.hasData) return const ReliqLoadingState(message: 'Loading stock counts…', detail: 'RELIQ is reading count sessions and variances.');
              final rows = snapshot.data!;
              if (rows.isEmpty) return const Center(child: Text('No physical stock counts yet.'));
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final r = rows[i];
                  final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
                  return Card(child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.fact_check_outlined, size: 18)),
                    title: Text('${r['no']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text('${dt == null ? '—' : DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal())} • ${r['line_count'] ?? 0} products • Variance ${(r['absolute_variance'] as num? ?? 0).toStringAsFixed(2)}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${r['status']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: () => _open(r), child: Text(r['status'] == 'Draft' ? 'Count / Review' : 'View')),
                    ]),
                  ));
                },
              );
            },
          )),
        ]),
      );
}

class _NewStockCountDialog extends StatefulWidget {
  const _NewStockCountDialog();
  @override
  State<_NewStockCountDialog> createState() => _NewStockCountDialogState();
}

class _NewStockCountDialogState extends State<_NewStockCountDialog> {
  String search = '';
  String notes = '';
  final selected = <Map<String, Object?>>[];

  void _toggle(Map<String, Object?> p) {
    final id = p['id'].toString();
    final index = selected.indexWhere((x) => x['id'] == id);
    setState(() {
      if (index >= 0) {
        selected.removeAt(index);
      } else {
        selected.add({'id': id, 'name': p['name'], 'sku': p['sku'], 'stock': p['stock']});
      }
    });
  }

  Future<void> _save() async {
    try {
      final no = await AppDatabase.instance.createStockCount(items: selected, notes: notes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Stock count $no created.')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: SizedBox(
          width: 760,
          height: 650,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Create Physical Stock Count', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search products'), onChanged: (v) => setState(() => search = v)),
              const SizedBox(height: 10),
              Expanded(child: FutureBuilder<List<Map<String, Object?>>>(
                future: AppDatabase.instance.products(search: search, activeOnly: true),
                builder: (context, snap) {
                  final rows = snap.data ?? [];
                  return ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final p = rows[i];
                      final checked = selected.any((x) => x['id'] == p['id']);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (_) => _toggle(p),
                        title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${p['sku'] ?? '—'} • Current ${(p['stock'] as num? ?? 0).toStringAsFixed(2)} ${p['unit'] ?? ''}'),
                      );
                    },
                  );
                },
              )),
              TextFormField(decoration: const InputDecoration(labelText: 'Count notes'), onChanged: (v) => notes = v),
              const SizedBox(height: 12),
              Row(children: [
                Text('${selected.length} products selected', style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton.icon(onPressed: selected.isEmpty ? null : _save, icon: const Icon(Icons.arrow_forward), label: const Text('Create Count')),
              ]),
            ]),
          ),
        ),
      );
}

class _StockCountEntryDialog extends StatefulWidget {
  final Map<String, Object?> count;
  final List<Map<String, Object?>> lines;
  const _StockCountEntryDialog({required this.count, required this.lines});
  @override
  State<_StockCountEntryDialog> createState() => _StockCountEntryDialogState();
}

class _StockCountEntryDialogState extends State<_StockCountEntryDialog> {
  late List<Map<String, Object?>> lines;
  bool saving = false;

  bool get editable => widget.count['status'] == 'Draft';

  @override
  void initState() {
    super.initState();
    lines = widget.lines.map((x) => Map<String, Object?>.from(x)).toList();
  }

  Future<void> _saveLine(Map<String, Object?> line, String value) async {
    final q = double.tryParse(value);
    if (q == null || q < 0) return;
    line['counted_qty'] = q;
    line['variance'] = q - (line['expected_qty'] as num? ?? 0).toDouble();
    await AppDatabase.instance.updateStockCountQuantity((line['id'] as num).toInt(), q);
    if (mounted) setState(() {});
  }

  Future<void> _post() async {
    setState(() => saving = true);
    try {
      for (final line in lines) {
        final counted = line['counted_qty'];
        if (counted is num) {
          await AppDatabase.instance.updateStockCountQuantity((line['id'] as num).toInt(), counted.toDouble());
        }
      }
      await AppDatabase.instance.postStockCount(widget.count['id'].toString());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stock count posted and inventory updated.')));
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(28),
        child: SizedBox(
          width: 900,
          height: 680,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${widget.count['no']} • ${widget.count['status']}', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 10),
              Expanded(child: Card(child: ListView.separated(
                itemCount: lines.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final x = lines[i];
                  final expected = (x['expected_qty'] as num? ?? 0).toDouble();
                  final counted = (x['counted_qty'] as num?)?.toDouble();
                  final variance = counted == null ? null : counted - expected;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${x['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${x['sku'] ?? '—'} • Expected ${expected.toStringAsFixed(2)} ${x['unit'] ?? ''}', style: const TextStyle(fontSize: 12, color: V3Style.muted)),
                      ])),
                      SizedBox(
                        width: 140,
                        child: editable
                            ? TextFormField(
                                initialValue: counted?.toStringAsFixed(2) ?? '',
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'Counted'),
                                onFieldSubmitted: (v) => _saveLine(x, v),
                                onEditingComplete: () {},
                                onChanged: (v) {
                                  final q = double.tryParse(v);
                                  if (q != null && q >= 0) {
                                    x['counted_qty'] = q;
                                    x['variance'] = q - expected;
                                    setState(() {});
                                  }
                                },
                              )
                            : Text(counted?.toStringAsFixed(2) ?? '—', textAlign: TextAlign.right),
                      ),
                      SizedBox(width: 130, child: Text(variance == null ? '—' : '${variance >= 0 ? '+' : ''}${variance.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w800, color: variance == null || variance == 0 ? null : (variance > 0 ? const Color(0xFF1C8A5A) : Theme.of(context).colorScheme.error)))),
                      if (editable)
                        IconButton(onPressed: counted == null ? null : () => _saveLine(x, counted.toString()), icon: const Icon(Icons.save_outlined), tooltip: 'Save count'),
                    ]),
                  );
                },
              ))),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                if (editable) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(onPressed: saving ? null : _post, icon: const Icon(Icons.check_circle_outline), label: const Text('Post Count & Adjust Stock')),
                ],
              ]),
            ]),
          ),
        ),
      );
}
