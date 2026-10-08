import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/shortcut_helper_bar.dart';

class StockAdjustmentScreen extends StatefulWidget {
  final bool showShortcutHelpers;
  const StockAdjustmentScreen({super.key, this.showShortcutHelpers = true});

  @override
  State<StockAdjustmentScreen> createState() => _StockAdjustmentScreenState();
}

class _StockAdjustmentScreenState extends State<StockAdjustmentScreen> {
  int refreshKey = 0;
  String filter = '';
  DateTime? fromDate;
  DateTime? toDate;
  final searchFocus = FocusNode();

  @override
  void dispose() {
    searchFocus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f4): _pickAndAdjust,
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            setState(() => refreshKey++),
      };

  Future<void> _pickHistoryDate(bool from) async {
    final initial =
        from ? (fromDate ?? DateTime.now()) : (toDate ?? DateTime.now());
    final value = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 1)));
    if (value != null)
      setState(() {
        if (from)
          fromDate = value;
        else
          toDate = value;
      });
  }

  static const reasons = [
    'Count correction',
    'Damage / breakage',
    'Expired stock',
    'Shrinkage / loss',
    'Found stock',
    'Opening balance correction',
    'Transfer correction',
    'Other',
  ];

  Future<void> _pickAndAdjust() async {
    String q = '';
    final product = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialog) => AlertDialog(
                title: const Text('Select Product'),
                content: SizedBox(
                    width: 620,
                    height: 420,
                    child: Column(children: [
                      TextField(
                          autofocus: true,
                          onChanged: (v) => setDialog(() => q = v),
                          decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Scan barcode / search name / SKU')),
                      const SizedBox(height: 10),
                      Expanded(
                          child: FutureBuilder<List<Map<String, Object?>>>(
                        future: AppDatabase.instance
                            .products(search: q, activeOnly: false),
                        builder: (context, snap) {
                          final rows = (snap.data ?? [])
                              .where((p) =>
                                  (p['product_type'] ?? 'Stocked').toString() ==
                                  'Stocked')
                              .toList();
                          return ListView.separated(
                            itemCount: rows.length > 30 ? 30 : rows.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final p = rows[i];
                              return ListTile(
                                dense: true,
                                title: Text('${p['name']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                    '${p['sku'] ?? '—'} • ${p['external_barcode'] ?? p['internal_barcode'] ?? '—'}'),
                                trailing: Text(
                                    'Stock ${(p['stock'] as num? ?? 0).toStringAsFixed(2)}'),
                                onTap: () => Navigator.pop(dialogContext, p),
                              );
                            },
                          );
                        },
                      )),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'))
                ],
              )),
    );
    if (product != null && mounted) await _adjust(product);
  }

  Future<void> _adjust(Map<String, Object?> product) async {
    String mode = 'Increase';
    String reason = reasons.first;
    String note = '';
    String qtyText = '1';
    final current = (product['stock'] as num? ?? 0).toDouble();

    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) =>
          StatefulBuilder(builder: (context, setDialog) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: .76),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: dark
                        ? const Color(0xFF294154)
                        : const Color(0xFFDCE4EC)),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x25000000),
                      blurRadius: 28,
                      offset: Offset(0, 12))
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(18)),
                      border: Border(
                          bottom: BorderSide(
                              color: Theme.of(context).dividerColor))),
                  child: Row(children: [
                    Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                            color: V3Style.blue.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(11)),
                        child: const Icon(Icons.tune, color: V3Style.blue)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Text('Adjust Stock',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w800)),
                          Text(
                              '${product['name']} • ${product['sku'] ?? '—'} • Current ${current.toStringAsFixed(2)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ])),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(children: [
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: mode,
                      decoration:
                          const InputDecoration(labelText: 'Adjustment type'),
                      items: const [
                        DropdownMenuItem(
                            value: 'Increase', child: Text('Increase Stock')),
                        DropdownMenuItem(
                            value: 'Decrease', child: Text('Decrease Stock')),
                        DropdownMenuItem(
                            value: 'Set', child: Text('Set Actual Stock')),
                      ],
                      onChanged: (v) => setDialog(() => mode = v ?? 'Increase'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                        initialValue: qtyText,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                            labelText:
                                mode == 'Set' ? 'Actual stock' : 'Quantity'),
                        onChanged: (v) => qtyText = v),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: reason,
                      decoration: const InputDecoration(labelText: 'Reason'),
                      items: reasons
                          .map((x) => DropdownMenuItem(
                              value: x,
                              child: Text(x, overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (v) =>
                          setDialog(() => reason = v ?? reasons.first),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                        initialValue: note,
                        decoration: const InputDecoration(
                            labelText: 'Note (optional)',
                            hintText: 'Reference, explanation or count note'),
                        onChanged: (v) => note = v),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(18)),
                      border: Border(
                          top: BorderSide(
                              color: Theme.of(context).dividerColor))),
                  child:
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        icon: const Icon(Icons.save_outlined, size: 17),
                        label: const Text('Save Adjustment')),
                  ]),
                ),
              ]),
            ),
          ),
        );
      }),
    );

    if (ok != true) return;
    final entered = double.tryParse(qtyText.trim()) ?? 0;
    final change = mode == 'Set'
        ? entered - current
        : mode == 'Decrease'
            ? -entered
            : entered;
    if (entered < 0 || change == 0) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a valid stock quantity.')));
      return;
    }
    final combinedReason =
        note.trim().isEmpty ? reason : '$reason — ${note.trim()}';
    try {
      await AppDatabase.instance
          .adjustStock(product['id'] as String, change, combinedReason);
      if (mounted) setState(() => refreshKey++);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: _shortcutBindings(),
        child: Focus(
          autofocus: true,
          child: Padding(
            padding: V3Style.pagePadding,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Stock Adjustment',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text(
                          'Adjustment history first. Physical adjustments apply to Stocked products; Recipe/Combo availability is derived from components.',
                          style: TextStyle(color: V3Style.muted)),
                    ])),
                FilledButton.icon(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 14)),
                    onPressed: _pickAndAdjust,
                    icon: const Icon(Icons.tune),
                    label: const Text('Adjust Stock',
                        style: TextStyle(fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 14),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                          spacing: 9,
                          runSpacing: 9,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                                width: 390,
                                child: TextField(
                                    focusNode: searchFocus,
                                    onChanged: (v) => setState(
                                        () => filter = v.toLowerCase().trim()),
                                    decoration: const InputDecoration(
                                        prefixIcon: Icon(Icons.search),
                                        hintText:
                                            'Product, SKU, reason or reference'))),
                            SizedBox(
                                width: 155,
                                child: OutlinedButton.icon(
                                    onPressed: () => _pickHistoryDate(true),
                                    icon: const Icon(
                                        Icons.calendar_today_outlined,
                                        size: 16),
                                    label: Text(fromDate == null
                                        ? 'From date'
                                        : '${fromDate!.day}/${fromDate!.month}/${fromDate!.year}'))),
                            SizedBox(
                                width: 155,
                                child: OutlinedButton.icon(
                                    onPressed: () => _pickHistoryDate(false),
                                    icon: const Icon(Icons.event_outlined,
                                        size: 16),
                                    label: Text(toDate == null
                                        ? 'To date'
                                        : '${toDate!.day}/${toDate!.month}/${toDate!.year}'))),
                            if (fromDate != null || toDate != null)
                              TextButton.icon(
                                  onPressed: () => setState(() {
                                        fromDate = null;
                                        toDate = null;
                                      }),
                                  icon: const Icon(Icons.close, size: 16),
                                  label: const Text('Clear dates')),
                          ]))),
              const SizedBox(height: 12),
              Expanded(
                  child: FutureBuilder<List<Map<String, Object?>>>(
                key: ValueKey(refreshKey),
                future: AppDatabase.instance.stockMovements(),
                builder: (context, snap) {
                  if (snap.hasError)
                    return Center(child: Text('${snap.error}'));
                  final rows = (snap.data ?? []).where((r) {
                    final type = '${r['type'] ?? ''}'.toLowerCase();
                    if (!type.contains('adjust')) return false;
                    final created =
                        DateTime.tryParse('${r['created_at'] ?? ''}');
                    if (created != null && fromDate != null) {
                      final start = DateTime(
                          fromDate!.year, fromDate!.month, fromDate!.day);
                      if (created.isBefore(start)) return false;
                    }
                    if (created != null && toDate != null) {
                      final end =
                          DateTime(toDate!.year, toDate!.month, toDate!.day)
                              .add(const Duration(days: 1));
                      if (!created.isBefore(end)) return false;
                    }
                    if (filter.isEmpty) return true;
                    return ['name', 'sku', 'reason', 'reference', 'type'].any(
                        (k) => '${r[k] ?? ''}'.toLowerCase().contains(filter));
                  }).toList();
                  if (rows.isEmpty)
                    return const Center(
                        child: Text('No stock adjustments yet.'));
                  return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          final change =
                              (r['qty_change'] as num? ?? 0).toDouble();
                          return ListTile(
                            leading: CircleAvatar(
                                radius: 18,
                                child: Icon(
                                    change >= 0 ? Icons.add : Icons.remove,
                                    size: 18)),
                            title: Text('${r['name'] ?? 'Product'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                                '${r['sku'] ?? '—'} • ${r['reason'] ?? 'Stock adjustment'}\n${r['created_at'] ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            trailing: Text(
                                '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: change >= 0
                                        ? const Color(0xFF18794E)
                                        : Theme.of(context).colorScheme.error)),
                          );
                        },
                      ));
                },
              )),
              if (widget.showShortcutHelpers)
                const ShortcutHelperBar(items: [
                  ('Ctrl/Cmd+F', 'Universal Lookup'),
                  ('F2', 'Lookup'),
                  ('F4', 'Adjust stock'),
                  ('F5', 'Refresh'),
                ]),
            ]),
          ),
        ),
      );
}
