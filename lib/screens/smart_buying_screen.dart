import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/searchable_map_select.dart';

class SmartBuyingScreen extends StatefulWidget {
  const SmartBuyingScreen({super.key});

  @override
  State<SmartBuyingScreen> createState() => _SmartBuyingScreenState();
}

class _SmartBuyingScreenState extends State<SmartBuyingScreen> {
  Future<void> _createPurchaseOrder(Map<String, Object?> row) async {
    final suppliers =
        await AppDatabase.instance.suppliers(activeOnly: true, limit: 10000);
    if (!mounted) return;
    final preferred = '${row['supplier'] ?? ''}'.trim().toLowerCase();
    Map<String, Object?>? selected;
    if (preferred.isNotEmpty) {
      for (final s in suppliers) {
        if ('${s['name'] ?? ''}'.trim().toLowerCase() == preferred) {
          selected = s;
          break;
        }
      }
    }
    if (selected == null && suppliers.isNotEmpty) {
      String? selectedId;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, update) => AlertDialog(
                  title: Text('Choose supplier for ${row['name']}'),
                  content: SizedBox(
                      width: 560,
                      child: SearchableMapSelect(
                        options: suppliers,
                        value: selectedId,
                        labelText: 'Supplier',
                        hintText: 'Type name, phone or email...',
                        display: (s) => '${s['name']}',
                        subtitle: (s) => [
                          if ('${s['phone'] ?? ''}'.trim().isNotEmpty)
                            '${s['phone']}',
                          if ('${s['email'] ?? ''}'.trim().isNotEmpty)
                            '${s['email']}',
                        ].join(' • '),
                        onChanged: (v) => update(() => selectedId = v),
                      )),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: selectedId == null
                            ? null
                            : () => Navigator.pop(dialogContext, true),
                        child: const Text('Select')),
                  ],
                )),
      );
      if (ok == true && selectedId != null) {
        selected = suppliers.firstWhere((s) => '${s['id']}' == selectedId);
      }
    }
    if (selected == null) return;
    final suggested = _n(row, 'suggested_order');
    final planned = _n(row, 'planned_qty');
    final qty = planned > 0 ? planned : suggested;
    if (qty <= 0) return;
    try {
      final no = await AppDatabase.instance.createPurchaseOrder(
        supplierId: selected['id'].toString(),
        items: [
          {
            'id': row['id'],
            'name': row['name'],
            'qty': qty,
            'unit_cost': _n(row, 'cost'),
          }
        ],
        placeOrder: true,
        notes: 'Created from Smart Buying • ${row['recommendation'] ?? ''}',
      );
      if (!mounted) return;
      setState(() {
        _future = AppDatabase.instance
            .inventoryIntelligence(lookbackDays: lookback, forceRefresh: true);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Purchase order $no created. Incoming stock is now included in Smart Buying.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  int lookback = 30;
  final budgetCtrl = TextEditingController();
  String priority = 'Balanced';
  late Future<List<Map<String, Object?>>> _future;

  @override
  void initState() {
    super.initState();
    _future =
        AppDatabase.instance.inventoryIntelligence(lookbackDays: lookback);
  }

  @override
  void dispose() {
    budgetCtrl.dispose();
    super.dispose();
  }

  double _n(Map<String, Object?> row, String key) =>
      (row[key] as num? ?? 0).toDouble();

  bool _flag(Map<String, Object?> row, String key) =>
      (row[key] as num? ?? 0) != 0;

  String _group(Map<String, Object?> row) {
    final suggested = _n(row, 'suggested_order');
    if (_flag(row, 'out_of_stock')) {
      if (suggested > 0.001) return 'Buy Now';
      return 'Review';
    }
    if (_flag(row, 'projected_expiry_risk') ||
        _flag(row, 'overstock') ||
        _flag(row, 'dead_stock') ||
        _flag(row, 'not_sold_recently')) {
      return 'Do Not Buy';
    }
    if (suggested > 0.001 || _flag(row, 'low_stock')) return 'Buy Now';
    if ('${row['confidence']}' == 'Insufficient') return 'Review';
    return 'Monitor';
  }

  double _priorityScore(Map<String, Object?> row) {
    final coverage = _n(row, 'coverage_days');
    var score = 0.0;
    if (_flag(row, 'out_of_stock')) score += 1000;
    if (_flag(row, 'low_stock')) score += 500;
    if (_flag(row, 'fast_moving')) {
      score += priority == 'Fast Movers First' ? 450 : 180;
    }
    if (_flag(row, 'projected_expiry_risk')) {
      score -= priority == 'Avoid Expiry Risk' ? 700 : 250;
    }
    if (coverage >= 0) score += (120 - coverage).clamp(0, 120).toDouble();
    score += _n(row, 'velocity') * 12;
    return score;
  }

  List<Map<String, Object?>> _prepared(List<Map<String, Object?>> rows) {
    final result = rows.map((r) => Map<String, Object?>.from(r)).toList();
    for (final row in result) {
      row['buying_group'] = _group(row);
      row['priority_score'] = _priorityScore(row);
      row['planned_qty'] = 0.0;
      row['planned_spend'] = 0.0;
      row['budget_decision'] = '';
    }

    result.sort((a, b) {
      final groupOrder = {
        'Buy Now': 0,
        'Review': 1,
        'Monitor': 2,
        'Do Not Buy': 3
      };
      final ga = groupOrder['${a['buying_group']}'] ?? 9;
      final gb = groupOrder['${b['buying_group']}'] ?? 9;
      if (ga != gb) return ga.compareTo(gb);
      return _n(b, 'priority_score').compareTo(_n(a, 'priority_score'));
    });

    final raw = budgetCtrl.text.trim();
    final hasBudget = raw.isNotEmpty && (double.tryParse(raw) ?? 0) > 0;
    if (!hasBudget) return result;

    var remaining =
        (double.tryParse(raw) ?? 0).clamp(0, double.infinity).toDouble();
    final candidates = result
        .where((r) => '${r['buying_group']}' == 'Buy Now')
        .toList()
      ..sort(
          (a, b) => _n(b, 'priority_score').compareTo(_n(a, 'priority_score')));

    for (final row in candidates) {
      final cost = _n(row, 'cost');
      final wanted = _n(row, 'suggested_order');
      if (cost <= 0 || wanted <= 0) {
        row['budget_decision'] = 'Review cost';
        continue;
      }

      final fullCost = wanted * cost;
      double qty = 0;
      String decision = 'Wait';
      if (remaining >= fullCost) {
        qty = wanted;
        decision = 'Buy';
      } else if (remaining >= cost) {
        qty = (remaining / cost).floorToDouble().clamp(0, wanted).toDouble();
        if (qty > 0) decision = 'Partial';
      }
      final spend = qty * cost;
      remaining = (remaining - spend).clamp(0, double.infinity).toDouble();
      row['planned_qty'] = qty;
      row['planned_spend'] = spend;
      row['budget_decision'] = decision;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Could not calculate buying plan: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const _SmartBuyingLoading();
        }

        final prepared = _prepared(snapshot.data!);
        final buyRows =
            prepared.where((r) => '${r['buying_group']}' == 'Buy Now').toList();
        final reviewRows =
            prepared.where((r) => '${r['buying_group']}' == 'Review').toList();
        final monitorRows =
            prepared.where((r) => '${r['buying_group']}' == 'Monitor').toList();
        final avoidRows = prepared
            .where((r) => '${r['buying_group']}' == 'Do Not Buy')
            .toList();
        final rawBudget = budgetCtrl.text.trim();
        final budget = double.tryParse(rawBudget) ?? 0;
        final hasBudget = rawBudget.isNotEmpty && budget > 0;
        final recommendedSpend = buyRows.fold<double>(
          0,
          (sum, r) => sum + (_n(r, 'suggested_order') * _n(r, 'cost')),
        );
        final allocated = prepared.fold<double>(
          0,
          (sum, r) => sum + _n(r, 'planned_spend'),
        );
        final remaining = hasBudget
            ? (budget - allocated).clamp(0, double.infinity).toDouble()
            : 0.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smart Buying',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'RELIQ first decides what needs buying, reviewing, monitoring, or avoiding. A budget is optional and only controls how much of the recommendation you can fund.',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: lookback,
                    items: const [14, 30, 60, 90]
                        .map((x) => DropdownMenuItem(
                              value: x,
                              child: Text('$x-day demand'),
                            ))
                        .toList(),
                    onChanged: (value) => setState(() {
                      lookback = value ?? 30;
                      _future = AppDatabase.instance
                          .inventoryIntelligence(lookbackDays: lookback);
                    }),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Recalculate latest analytics',
                    onPressed: () => setState(() => _future =
                        AppDatabase.instance.inventoryIntelligence(
                            lookbackDays: lookback, forceRefresh: true)),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _explanationBanner(context),
              const SizedBox(height: 12),
              _budgetPanel(
                context,
                recommendedSpend: recommendedSpend,
                allocated: allocated,
                remaining: remaining,
                hasBudget: hasBudget,
                buy: buyRows.length,
                review: reviewRows.length,
                monitor: monitorRows.length,
                avoid: avoidRows.length,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    _section(
                      context,
                      title: 'Buy Now',
                      subtitle: buyRows.isEmpty
                          ? 'Nothing currently needs a confident reorder.'
                          : 'These products are below RELIQ’s recommended stock level.',
                      color: V3Style.success,
                      icon: Icons.shopping_cart_checkout_outlined,
                      rows: buyRows,
                      hasBudget: hasBudget,
                    ),
                    const SizedBox(height: 12),
                    _section(
                      context,
                      title: 'Review',
                      subtitle: reviewRows.isEmpty
                          ? 'No products need a manual stock decision.'
                          : 'These products need a human decision because history or target settings are limited.',
                      color: V3Style.warning,
                      icon: Icons.rule_outlined,
                      rows: reviewRows,
                      hasBudget: hasBudget,
                    ),
                    const SizedBox(height: 12),
                    _section(
                      context,
                      title: 'Do Not Buy',
                      subtitle: avoidRows.isEmpty
                          ? 'No overstock, dead stock, or expiry-risk items are blocking purchases.'
                          : 'Buying more of these products would increase overstock or expiry risk.',
                      color: V3Style.danger,
                      icon: Icons.block_outlined,
                      rows: avoidRows,
                      hasBudget: hasBudget,
                    ),
                    const SizedBox(height: 12),
                    _section(
                      context,
                      title: 'Monitor',
                      subtitle: monitorRows.isEmpty
                          ? 'No neutral items in this demand window.'
                          : 'Stock is currently acceptable; keep watching demand before ordering.',
                      color: V3Style.info,
                      icon: Icons.visibility_outlined,
                      rows: monitorRows,
                      hasBudget: hasBudget,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _explanationBanner(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: V3Style.blue.withValues(alpha: .06),
        border: Border.all(color: V3Style.blue.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, color: V3Style.blue),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No purchase budget is assumed. First review RELIQ’s stock decisions. If you enter a budget, RELIQ allocates it to the highest-priority Buy Now items and marks each one Buy, Partial, or Wait.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _budgetPanel(
    BuildContext context, {
    required double recommendedSpend,
    required double allocated,
    required double remaining,
    required bool hasBudget,
    required int buy,
    required int review,
    required int monitor,
    required int avoid,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 230,
              child: TextField(
                controller: budgetCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Optional purchase budget',
                  hintText: 'Leave blank to review',
                  prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: priority,
                decoration:
                    const InputDecoration(labelText: 'Priority strategy'),
                items: const [
                  'Balanced',
                  'Fast Movers First',
                  'Avoid Expiry Risk',
                ]
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (value) =>
                    setState(() => priority = value ?? 'Balanced'),
              ),
            ),
            _mini('Recommended need', recommendedSpend.toStringAsFixed(3),
                V3Style.blue),
            _mini(
              hasBudget ? 'Budget' : 'Budget',
              hasBudget
                  ? (double.tryParse(budgetCtrl.text.trim()) ?? 0)
                      .toStringAsFixed(3)
                  : 'Not set',
              V3Style.purple,
            ),
            _mini('Allocated', hasBudget ? allocated.toStringAsFixed(3) : '—',
                V3Style.success),
            _mini('Remaining', hasBudget ? remaining.toStringAsFixed(3) : '—',
                V3Style.warning),
            _mini('Buy / Review / Avoid', '$buy / $review / $avoid',
                V3Style.teal),
            _mini('Monitor', '$monitor', V3Style.info),
          ],
        ),
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required String subtitle,
    required Color color,
    required IconData icon,
    required List<Map<String, Object?>> rows,
    required bool hasBudget,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$title (${rows.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 4),
                child: Text('Nothing to show in this section.'),
              ),
            for (final row in rows) ...[
              const SizedBox(height: 10),
              _productCard(context, row, color, hasBudget),
            ],
          ],
        ),
      ),
    );
  }

  Widget _productCard(
    BuildContext context,
    Map<String, Object?> row,
    Color accent,
    bool hasBudget,
  ) {
    final coverage = _n(row, 'coverage_days');
    final suggested = _n(row, 'suggested_order');
    final decision = '${row['budget_decision'] ?? ''}';
    final confidence = '${row['confidence'] ?? 'Insufficient'}';
    final unit = '${row['unit'] ?? ''}'.trim();
    final lastSale = row['days_since_sale'];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: V3Style.rowStripe(context),
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${row['name']}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              _chip('${row['health']}', accent),
              _chip('${row['demand_signal']}', V3Style.info),
              _chip(
                  '${row['demand_state'] ?? 'Demand review'}',
                  _flag(row, 'auto_purchase_eligible')
                      ? V3Style.success
                      : V3Style.warning),
              _chip('$confidence confidence', _confidenceColor(confidence)),
              if (hasBudget && decision.isNotEmpty)
                _chip('Budget: $decision', _decisionColor(decision)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${row['explanation'] ?? row['recommendation'] ?? 'Keep monitoring'}',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _metric(
                  'On hand', '${_n(row, 'stock').toStringAsFixed(2)} $unit'),
              _metric('Incoming / on order',
                  '${_n(row, 'incoming_qty').toStringAsFixed(2)} $unit'),
              _metric('Inventory position',
                  '${_n(row, 'inventory_position').toStringAsFixed(2)} $unit'),
              _metric(
                'Stock will last',
                coverage < 0
                    ? 'No reliable sales rate'
                    : '${coverage.toStringAsFixed(0)} days',
              ),
              _metric(
                'Last sold',
                lastSale == null ? 'Never / no record' : '$lastSale days ago',
              ),
              _metric(
                'Recommended stock',
                '${_n(row, 'dynamic_target').toStringAsFixed(2)} $unit',
              ),
              _metric(
                'Suggested purchase',
                suggested > 0
                    ? '${suggested.toStringAsFixed(2)} $unit'
                    : 'None',
              ),
              if (_flag(row, 'purchase_blocked'))
                _metric('Purchase decision',
                    'Blocked: ${row['purchase_block_reason'] ?? 'Review'}'),
              if (_n(row, 'projected_expiry_value') > 0)
                _metric(
                  'Expiry value at risk',
                  _n(row, 'projected_expiry_value').toStringAsFixed(3),
                ),
              if (hasBudget && _n(row, 'planned_qty') > 0)
                _metric(
                  'Budgeted purchase',
                  '${_n(row, 'planned_qty').toStringAsFixed(2)} $unit • ${_n(row, 'planned_spend').toStringAsFixed(3)}',
                ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tips_and_updates_outlined, size: 18, color: accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${row['recommendation'] ?? 'Keep monitoring'} • Target basis: ${row['target_source'] ?? 'Demand history'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (suggested > 0.001) ...[
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  onPressed: () => _createPurchaseOrder(row),
                  icon: const Icon(Icons.assignment_add, size: 17),
                  label: const Text('Create PO'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _mini(String label, String value, Color color) {
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(10),
        color: color.withValues(alpha: .06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        border: Border.all(color: color.withValues(alpha: .30)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }

  Color _confidenceColor(String value) {
    switch (value) {
      case 'High':
        return V3Style.success;
      case 'Medium':
        return V3Style.info;
      case 'Low':
        return V3Style.warning;
      default:
        return V3Style.muted;
    }
  }

  Color _decisionColor(String value) {
    switch (value) {
      case 'Buy':
        return V3Style.success;
      case 'Partial':
        return V3Style.warning;
      case 'Wait':
        return V3Style.danger;
      default:
        return V3Style.info;
    }
  }
}

class _SmartBuyingLoading extends StatelessWidget {
  const _SmartBuyingLoading();
  @override
  Widget build(BuildContext context) => const Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox.square(
              dimension: 30, child: CircularProgressIndicator(strokeWidth: 3)),
          SizedBox(height: 14),
          Text('Preparing Smart Buying',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
          SizedBox(height: 6),
          Text(
              'RELIQ is building the latest replenishment snapshot. Saved analytics will make subsequent visits much faster.',
              textAlign: TextAlign.center,
              style: TextStyle(color: V3Style.muted)),
        ]),
      ));
}
