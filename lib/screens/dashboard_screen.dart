import 'package:flutter/material.dart';

import '../config/brand.dart';
import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_surface.dart';

class DashboardScreen extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  final ValueChanged<String>? onInventory;
  const DashboardScreen({super.key, this.onNavigate, this.onInventory});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<Map<String, dynamic>> _briefFuture;

  @override
  void initState() {
    super.initState();
    _briefFuture = _load();
  }

  Future<Map<String, dynamic>> _load({bool forceAnalytics = false}) async {
    final results = await Future.wait<Object>([
      AppDatabase.instance.dashboard(),
      AppDatabase.instance.reportSummary(),
      AppDatabase.instance.morningBriefDetail(forceAnalytics: forceAnalytics),
      AppDatabase.instance.recentSales(limit: 6, currentBranchOnly: true),
      AppDatabase.instance.recentPurchases(limit: 6, currentBranchOnly: true),
      AppDatabase.instance.morningTopProducts(),
    ]);
    return {
      'dashboard': results[0] as Map<String, num>,
      'summary': results[1] as Map<String, num>,
      'detail': results[2] as Map<String, num>,
      'sales': results[3] as List<Map<String, Object?>>,
      'purchases': results[4] as List<Map<String, Object?>>,
      'topProducts':results[5] as List<Map<String,Object?>>,
    };
  }

  void _refreshBrief() => setState(() => _briefFuture = _load(forceAnalytics: true));

  String money(num value) => value.toStringAsFixed(3);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _briefFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Card(
              child: Padding(
                padding: V3Style.pagePadding,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 34),
                  const SizedBox(height: 10),
                  const Text('Morning Brief could not load', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text('${snapshot.error}', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 14),
                  FilledButton.icon(onPressed: _refreshBrief, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                ]),
              ),
            ),
          );
        }
        if (!snapshot.hasData) return const _AnalyticsLoading(title: 'Preparing your Morning Brief');
        final d = snapshot.data!['dashboard'] as Map<String, num>;
        final s = snapshot.data!['summary'] as Map<String, num>;
        final x = snapshot.data!['detail'] as Map<String, num>;
        final sales = snapshot.data!['sales'] as List<Map<String, Object?>>;
        final purchases = snapshot.data!['purchases'] as List<Map<String, Object?>>;
        final topProducts=snapshot.data!['topProducts'] as List<Map<String,Object?>>;
        final compact = MediaQuery.sizeOf(context).width < 880;

        return ListView(
          padding: EdgeInsets.fromLTRB(compact ? 16 : 28, 22, compact ? 16 : 28, 40),
          children: [
            _pageHead(),
            const SizedBox(height: 14),
            // Daily operating numbers belong at the top of the Morning Brief.
            // Product rankings are useful context, but should never push today's
            // sales/cash position below the fold.
            Wrap(spacing: 12, runSpacing: 12, children: [
              _kpi('Today Sales', x['todayNetSales'] ?? 0, 'Net sales after returns', Icons.payments_outlined, 9, V3Style.success),
              _kpi('Today Collected', x['todayCollected'] ?? 0, 'Sales + account receipts', Icons.account_balance_wallet_outlined, 11, V3Style.blue),
              _kpi('Today Purchases', d['todayPurchases'] ?? 0, 'Incoming stock', Icons.download_outlined, 6, V3Style.warning),
              _kpi('Today Expenses', x['todayExpenses'] ?? 0, 'Operating expenses', Icons.attach_money_outlined, 13, V3Style.danger),
              _kpi('Receivables', d['receivable'] ?? 0, 'Customers owe us', Icons.receipt_long_outlined, 11, V3Style.purple),
              _kpi('Payables', d['payable'] ?? 0, 'We owe suppliers', Icons.credit_card_outlined, 11, V3Style.warning),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _smallKpi('Low Stock', x['lowStockProducts'] ?? 0, Icons.warning_amber_outlined, 8, color: V3Style.warning),
              _smallKpi('Out of Stock', x['outOfStock'] ?? 0, Icons.remove_shopping_cart_outlined, 8, color: V3Style.danger),
              _smallKpi('Expiring ≤30d', x['expiring30'] ?? 0, Icons.event_busy_outlined, 8, color: V3Style.purple),
              _smallKpi('Stock Value', s['stockValue'] ?? 0, Icons.warehouse_outlined, 8, moneyValue: true, color: V3Style.teal),
              _smallKpi('30d Margin', s['grossMargin30'] ?? 0, Icons.trending_up_outlined, 15, moneyValue: true, color: V3Style.success),
            ]),
            if (topProducts.isNotEmpty) ...[
              const SizedBox(height: 18),
              _panel('Top products · last 7 days · before returns',[for(final p in topProducts)_moneyRow('${p["name"]} · ${(p["qty"] as num? ?? 0).toStringAsFixed(2)} sold',p["revenue"] as num? ?? 0),TextButton(onPressed:()=>widget.onNavigate?.call(9),child:const Text('View sales'))]),
            ],
            const SizedBox(height: 18),
            _responsivePair(compact, _ownerBrief(d, x), _monthSnapshot(s)),
            const SizedBox(height: 18),
            _responsivePair(compact, _activity('Recent Sales', sales, true), _activity('Recent Purchases', purchases, false)),
            const SizedBox(height: 18),
            _quickActions(),
          ],
        );
      },
    );
  }

  Widget _pageHead() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ReliqGlass(
      padding: const EdgeInsets.all(18),
      radius: 20,
      blur: 18,
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Image.asset(Brand.iconAsset, width: 66, height: 66, fit: BoxFit.cover),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('Morning Brief', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.7, color: dark ? Colors.white : V3Style.brandDark))),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: V3Style.lime.withValues(alpha: dark ? .18 : .30), borderRadius: BorderRadius.circular(999)),
                child: Text(Brand.name, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: dark ? V3Style.lime : V3Style.brandDark)),
              ),
            ]),
            const SizedBox(height: 5),
            Text('Sales, cash, stock and account priorities — one clean view for the day.', style: TextStyle(color: dark ? V3Style.sidebarText : Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Text(Brand.tagline, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: dark ? V3Style.lime : V3Style.brandDark)),
          ]),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(onPressed: _refreshBrief, icon: const Icon(Icons.refresh, size: 17), label: const Text('Refresh')),
      ]),
    );
  }

  Widget _kpi(String label, num value, String sub, IconData icon, int page, Color accent) => SizedBox(
        width: 206,
        height: 116,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (page == 8 && label != 'Stock Value') {
              widget.onInventory?.call(label == 'Expiring ≤30d' ? 'Expiring Soon' : label);
            } else { widget.onNavigate?.call(page); }
          },
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 11),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700, letterSpacing: .55),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(icon, size: 18, color: accent),
                    ]),
                    const Spacer(),
                    Text(money(value), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
              Container(
                height: 3,
                width: double.infinity,
                decoration: BoxDecoration(color: accent),
              ),
            ]),
          ),
        ),
      );

  Widget _smallKpi(String label, num value, IconData icon, int page, {bool moneyValue = false, Color color = V3Style.blue}) => SizedBox(
        width: 190,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (page == 8 && label != 'Stock Value') {
              widget.onInventory?.call(label == 'Expiring ≤30d' ? 'Expiring Soon' : label);
            } else { widget.onNavigate?.call(page); }
          },
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 3),
                  Text(moneyValue ? money(value) : value.toStringAsFixed(0), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ])),
                const Icon(Icons.chevron_right, size: 17),
              ]),
            ),
          ),
        ),
      );

  Widget _ownerBrief(Map<String, num> d, Map<String, num> x) {
    final items = <(IconData, String, int)>[];
    if ((x['lowStockProducts'] ?? 0) > 0) items.add((Icons.inventory_2_outlined, '${x['lowStockProducts']!.toInt()} products are at or below minimum stock.', 8));
    if ((x['outOfStock'] ?? 0) > 0) items.add((Icons.remove_shopping_cart_outlined, '${x['outOfStock']!.toInt()} active products are out of stock.', 8));
    if ((d['overdueReceivable'] ?? 0) > 0) items.add((Icons.schedule_outlined, 'Overdue customer receivables: ${money(d['overdueReceivable']!)}', 11));
    if ((d['overduePayable'] ?? 0) > 0) items.add((Icons.account_balance_wallet_outlined, 'Overdue supplier payables: ${money(d['overduePayable']!)}', 11));
    if ((x['expiring30'] ?? 0) > 0) items.add((Icons.event_busy_outlined, '${x['expiring30']!.toInt()} products have an expiry date within 30 days.', 8));
    if ((x['reorderProducts'] ?? 0) > 0) items.add((Icons.shopping_bag_outlined, '${x['reorderProducts']!.toInt()} products have a Smart Buying reorder suggestion.', 7));
    if ((x['stockDiscrepancies'] ?? 0) > 0) items.add((Icons.fact_check_outlined, '${x['stockDiscrepancies']!.toInt()} stock discrepancies need counting/correction before purchasing.', 20));
    if ((x['dormantProducts'] ?? 0) > 0) items.add((Icons.bedtime_outlined, '${x['dormantProducts']!.toInt()} active products are dormant and blocked from automatic purchasing.', 2));
    if ((x['quotationFollowups'] ?? 0) > 0) items.add((Icons.request_quote_outlined, '${x['quotationFollowups']!.toInt()} sent quotations need follow-up.', 10));
    if (items.isEmpty) items.add((Icons.check_circle_outline, 'No urgent stock, expiry or overdue-account issues detected.', 0));

    final yesterday=x['yesterdaySales']??0;
    final today=x['todayNetSales']??0;
    final change=yesterday==0?'No prior-day baseline':'${((today-yesterday)/yesterday.abs()*100).toStringAsFixed(1)}% vs yesterday';
    return _panel("Owner's Morning Brief", [
      Wrap(spacing:14,runSpacing:8,children:[
        Text('Today net sales: KWD ${money(today)}'),Text('Yesterday: KWD ${money(yesterday)}'),Text(change),
        Text('Gross profit today: KWD ${money(x['todayGrossMargin']??0)}'),
        Text('Expected drawer cash: KWD ${money(x['expectedCash']??0)}'),
      ]),
      const SizedBox(height:12),
      FilledButton.icon(onPressed:()=>widget.onNavigate?.call(21),icon:const Icon(Icons.bolt),label:const Text('Review pending business actions')),
      const SizedBox(height:8),
      if((x['expiredProducts']??0)>0) ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.event_busy),title:Text('${x['expiredProducts']!.toInt()} products have expired stock'),trailing:const Icon(Icons.chevron_right),onTap:()=>widget.onInventory?.call('Expired')),
      if((x['deadStock']??0)>0) ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.trending_down),title:Text('${x['deadStock']!.toInt()} products show no recent movement'),trailing:const Icon(Icons.chevron_right),onTap:()=>widget.onInventory?.call('Dead Stock')),

      for (final item in items)
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            if (item.$3 == 8) {
              widget.onInventory?.call(item.$1 == Icons.inventory_2_outlined ? 'Low Stock' : item.$1 == Icons.remove_shopping_cart_outlined ? 'Out of Stock' : 'Expiring Soon');
            } else { widget.onNavigate?.call(item.$3); }
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(10),
              color: Theme.of(context).colorScheme.surface.withValues(alpha: .76),
            ),
            child: Row(children: [Icon(item.$1, size: 18), const SizedBox(width: 10), Expanded(child: Text(item.$2, style: const TextStyle(fontSize: 13))), const Icon(Icons.chevron_right, size: 17)]),
          ),
        ),
    ]);
  }

  Widget _monthSnapshot(Map<String, num> s) => _panel('30-Day Business Snapshot', [
        _moneyRow('Sales', s['sales30'] ?? 0),
        _moneyRow('Gross margin', s['grossMargin30'] ?? 0),
        _moneyRow('Purchases', s['purchases30'] ?? 0),
        _moneyRow('Sales still due', s['salesDue30'] ?? 0),
        _moneyRow('Purchases still due', s['purchaseDue30'] ?? 0),
        _moneyRow('Current stock value', s['stockValue'] ?? 0),
      ]);

  Widget _panel(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _moneyRow(String label, num value) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [Expanded(child: Text(label, style: const TextStyle(fontSize: 13))), Text(money(value), style: const TextStyle(fontWeight: FontWeight.w700))]),
      );

  Widget _activity(String title, List<Map<String, Object?>> rows, bool sale) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No transactions yet.'))),
            for (final row in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
                child: Row(children: [
                  Icon(sale ? Icons.arrow_upward : Icons.arrow_downward, size: 17, color: sale ? V3Style.success : V3Style.warning),
                  const SizedBox(width: 9),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${row['no'] ?? '—'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    Text('${row[sale ? 'customer_name' : 'supplier_name'] ?? (sale ? 'Walk-in customer' : 'Supplier')}', style: const TextStyle(fontSize: 11, color: Color(0xFF7C8C9D))),
                  ])),
                  Text(money((row['total'] as num?) ?? 0), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ]),
              ),
          ]),
        ),
      );

  Widget _responsivePair(bool compact, Widget a, Widget b) => compact
      ? Column(children: [a, const SizedBox(height: 14), b])
      : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 14), Expanded(child: b)]);

  Widget _quickActions() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Quick Actions', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 13),
            Wrap(spacing: 9, runSpacing: 9, children: [
              _action('New Sale', Icons.shopping_cart_outlined, 1),
              _action('Find Product', Icons.inventory_2_outlined, 2),
              _action('Adjust Stock', Icons.tune_outlined, 3),
              _action('Receive Purchase', Icons.download_outlined, 5),
              _action('Smart Buying', Icons.monetization_on_outlined, 7),
              _action('Receive / Pay', Icons.credit_card_outlined, 11),
              _action('Reports', Icons.query_stats_outlined, 15),
              _action('Action Center', Icons.bolt_outlined, 21),
            ]),
          ]),
        ),
      );

  Widget _action(String label, IconData icon, int page) => OutlinedButton.icon(onPressed: () => widget.onNavigate?.call(page), icon: Icon(icon, size: 17), label: Text(label));
}


class _AnalyticsLoading extends StatelessWidget {
  final String title;
  const _AnalyticsLoading({required this.title});
  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 460),
    child: Card(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox.square(dimension: 30, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 7),
        const Text('RELIQ is calculating the latest sales, stock and purchasing intelligence. Future visits use the saved snapshot immediately; Refresh recalculates on demand.', textAlign: TextAlign.center, style: TextStyle(color: V3Style.muted, height: 1.4)),
      ]),
    )),
  ));
}
