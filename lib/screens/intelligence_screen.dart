import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';

class IntelligenceScreen extends StatefulWidget {
  final String initialFilter;
  const IntelligenceScreen({super.key, this.initialFilter = 'All'});

  @override
  State<IntelligenceScreen> createState() => _IntelligenceScreenState();
}

class _IntelligenceScreenState extends State<IntelligenceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late Future<List<Map<String, Object?>>> _future;
  int days = 30;
  String filter = 'All';
  String sort = 'Attention';
  String query = '';
  String category = 'All';
  String supplier = 'All';
  String movementFilter='All',stockFilter='All',expiryFilter='All';
  int expiryWindow = 30;
  String? branchId;
  late final branchesFuture=AppDatabase.instance.branches();
  int pageSize = 10;
  int page = 0;

  static const filters = [
    'All',
    'Needs Attention',
    'Needs Manual Review',
    'Stock Discrepancy',
    'Dormant',
    'Purchase Blocked',
    'Fast Moving',
    'Slow Moving',
    'Medium Moving',
    'Dead Stock',
    'Low Stock',
    'Out of Stock',
    'Overstock',
    'Expiring Soon',
    'Expired',
    'Projected Expiry Risk',
    'Reorder Recommended',
    'Demand Rising',
    'Demand Falling',
    'Not Sold Recently',
    'High Value',
  ];

  @override
  void initState() {
    super.initState();
    filter = widget.initialFilter;
    _tabs = TabController(length: 2, vsync: this, initialIndex: filter == 'All' ? 0 : 1);
    _future = AppDatabase.instance.inventoryIntelligence(lookbackDays: days, branchIdOverride:branchId);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refreshAnalytics() => setState(() {
    page = 0;
    _future = AppDatabase.instance.inventoryIntelligence(lookbackDays: days, branchIdOverride: branchId, forceRefresh: true);
  });

  double _n(Map<String, Object?> row, String key) =>
      (row[key] as num? ?? 0).toDouble();

  bool _flag(Map<String, Object?> row, String key) =>
      (row[key] as num? ?? 0) != 0;

  bool _matches(Map<String,Object?> row,String view){
    final key=<String,String>{'Fast Moving':'fast_moving','Slow Moving':'slow_moving','Dead Stock':'dead_stock','Low Stock':'low_stock','Out of Stock':'out_of_stock','Overstock':'overstock','Demand Rising':'demand_rising','Demand Falling':'demand_dropping'}[view];
    if(key!=null)return _flag(row,key);
    if(view=='Medium Moving')return _n(row,'velocity')>0&&!_flag(row,'fast_moving')&&!_flag(row,'slow_moving');
    final expiry=row['days_to_expiry'] as num?;
    if(view=='Expired')return expiry!=null&&expiry<0&&_n(row,'stock')>0;
    if(view=='Expiring Soon')return expiry!=null&&expiry>=0&&expiry<=expiryWindow&&_n(row,'stock')>0;
    return true;
  }

  List<Map<String, Object?>> _filtered(List<Map<String, Object?>> input) {
    final q = query.trim().toLowerCase();
    final rows = input.where((row) {
      if (q.isNotEmpty) {
        final hay = '${row['name']} ${row['sku']} ${row['category']} ${row['supplier']}'
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      if (category != 'All' && '${row['category']}' != category) return false;
      if (supplier != 'All' && '${row['supplier']}' != supplier) return false;
      if(!_matches(row,movementFilter)||!_matches(row,stockFilter)||!_matches(row,expiryFilter))return false;
      switch (filter) {
        case 'Needs Attention':
          return _flag(row, 'needs_attention');
        case 'Needs Manual Review':
          return _flag(row, 'needs_manual_review');
        case 'Stock Discrepancy':
          return _flag(row, 'stock_discrepancy');
        case 'Dormant':
          return '${row['demand_state']}' == 'Dormant';
        case 'Purchase Blocked':
          return _flag(row, 'purchase_blocked');
        case 'Medium Moving':
          return _matches(row,'Medium Moving');
        case 'Fast Moving':
          return _flag(row, 'fast_moving');
        case 'Slow Moving':
          return _flag(row, 'slow_moving');
        case 'Dead Stock':
          return _flag(row, 'dead_stock');
        case 'Low Stock':
          return _flag(row, 'low_stock');
        case 'Out of Stock':
          return _flag(row, 'out_of_stock');
        case 'Overstock':
          return _flag(row, 'overstock');
        case 'Expiring Soon':
          final expiry = row['days_to_expiry'] as num?;
          return expiry != null && expiry >= 0 && expiry <= expiryWindow && _n(row,'stock')>0;
        case 'Expired':
          return (row['days_to_expiry'] as num? ?? 1) < 0 && _n(row,'stock')>0;
        case 'Projected Expiry Risk':
          return _flag(row, 'projected_expiry_risk');
        case 'Reorder Recommended':
          return _n(row, 'suggested_order') > 0.001;
        case 'Demand Rising':
          return _flag(row, 'demand_rising');
        case 'Demand Falling':
          return _flag(row, 'demand_dropping');
        case 'Not Sold Recently':
          return _flag(row, 'not_sold_recently');
        case 'High Value':
          return _n(row, 'stock_value') >= 100;
        default:
          return true;
      }
    }).toList();

    rows.sort((a, b) {
      switch (sort) {
        case 'Stock Quantity':
          return _n(a, 'stock').compareTo(_n(b, 'stock'));
        case 'Recommended Action':
          return '${a['recommendation']}'.compareTo('${b['recommendation']}');
        case 'Expiry Date':
          return (a['days_to_expiry'] as num? ?? double.infinity).compareTo(b['days_to_expiry'] as num? ?? double.infinity);
        case 'Name':
          return '${a['name']}'
              .toLowerCase()
              .compareTo('${b['name']}'.toLowerCase());
        case 'Demand':
          return _n(b, 'velocity').compareTo(_n(a, 'velocity'));
        case 'Coverage':
          final av = _n(a, 'coverage_days');
          final bv = _n(b, 'coverage_days');
          if (av < 0 && bv >= 0) return 1;
          if (bv < 0 && av >= 0) return -1;
          return av.compareTo(bv);
        case 'Stock Value':
          return _n(b, 'stock_value').compareTo(_n(a, 'stock_value'));
        case 'Expiry Risk':
          return _n(b, 'projected_expiry_value')
              .compareTo(_n(a, 'projected_expiry_value'));
        default:
          final aa = _flag(a, 'needs_attention') ? 1 : 0;
          final bb = _flag(b, 'needs_attention') ? 1 : 0;
          if (aa != bb) return bb.compareTo(aa);
          if (_flag(a, 'out_of_stock') != _flag(b, 'out_of_stock')) {
            return _flag(b, 'out_of_stock') ? 1 : -1;
          }
          return _n(b, 'suggested_order').compareTo(_n(a, 'suggested_order'));
      }
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Could not calculate inventory intelligence: ${snapshot.error}',
            ),
          );
        }
        if (!snapshot.hasData) {
          return const _InventoryAnalyticsLoading();
        }
        final rows = snapshot.data!;
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
                          'Inventory Intelligence',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'RELIQ explains what is happening, how confident the signal is, and what the business should consider doing next.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: days,
                    items: const [14, 30, 60, 90]
                        .map((x) => DropdownMenuItem(
                              value: x,
                              child: Text('$x-day demand'),
                            ))
                        .toList(),
                    onChanged: (value) => setState(() {
                      days = value ?? 30;
                      page = 0;
                      _future = AppDatabase.instance
                          .inventoryIntelligence(lookbackDays: days, branchIdOverride:branchId);
                    }),
                  ),
                  const SizedBox(width: 6),
                  IconButton(tooltip: 'Recalculate latest analytics', onPressed: _refreshAnalytics, icon: const Icon(Icons.refresh)),
                ],
              ),
              const SizedBox(height: 14),
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabs: const [
                  Tab(icon: Icon(Icons.insights_outlined), text: 'Insights'),
                  Tab(icon: Icon(Icons.fact_check_outlined), text: 'Stock Decisions'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _insights(rows),
                    _decisions(rows),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _insights(List<Map<String, Object?>> rows) {
    final stockValue = rows.fold<double>(0, (sum, r) => sum + _n(r, 'stock_value'));
    final reorderValue = rows.fold<double>(
      0,
      (sum, r) => sum + (_n(r, 'suggested_order') * _n(r, 'cost')),
    );
    final expiryRiskValue = rows.fold<double>(
      0,
      (sum, r) => sum + _n(r, 'projected_expiry_value'),
    );
    final attention = rows.where((r) => _flag(r, 'needs_attention')).length;
    final out = rows.where((r) => _flag(r, 'out_of_stock')).length;
    final fast = rows.where((r) => _flag(r, 'fast_moving')).length;
    final slow = rows.where((r) => _flag(r, 'slow_moving')).length;
    final dead = rows.where((r) => _flag(r, 'dead_stock')).length;
    final expiring = rows.where((r) => _flag(r, 'expiring_soon')).length;
    final rising = rows.where((r) => _flag(r, 'demand_rising')).length;
    final falling = rows.where((r) => _flag(r, 'demand_dropping')).length;
    final review = rows.where((r) => _flag(r, 'needs_manual_review')).length;
    final notSold = rows.where((r) => _flag(r, 'not_sold_recently')).length;
    final health = rows.isEmpty
        ? 100
        : ((1 - (attention / rows.length)) * 100).clamp(0, 100).round();

    final buy = rows.where((r) => _n(r, 'suggested_order') > 0.001).toList()
      ..sort((a, b) => (_n(b, 'suggested_order') * _n(b, 'cost'))
          .compareTo(_n(a, 'suggested_order') * _n(a, 'cost')));
    final overstock = rows.where((r) => _flag(r, 'overstock')).toList()
      ..sort((a, b) => _n(b, 'stock_value').compareTo(_n(a, 'stock_value')));
    final expiry = rows.where((r) => _n(r, 'projected_expiry_value') > 0.001).toList()
      ..sort((a, b) => _n(b, 'projected_expiry_value')
          .compareTo(_n(a, 'projected_expiry_value')));

    return ListView(
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final entry in <String,String>{'Low Stock':'low_stock','Out of Stock':'out_of_stock','Overstock':'overstock','Fast Moving':'fast_moving','Slow Moving':'slow_moving','Dead Stock':'dead_stock','Expiring Soon':'expiring_soon','Demand Rising':'demand_rising','Demand Falling':'demand_dropping'}.entries)
            ActionChip(avatar: Icon(Icons.filter_alt_outlined, size:16, color: V3Style.labelAccent(context)), label: Text('${entry.key} · ${rows.where((r)=>_flag(r,entry.value)).length}'), onPressed:()=>setState((){filter=entry.key;page=0;_tabs.index=1;})),
          ActionChip(label:Text('Expired · ${rows.where((r)=>(r['days_to_expiry'] as num? ?? 1)<0 && _n(r,'stock')>0).length}'),onPressed:()=>setState((){filter='Expired';page=0;_tabs.index=1;})),
        ]),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _stat('Inventory Health', '$health%', Icons.health_and_safety_outlined, V3Style.success),
            _stat('Stock Value', stockValue.toStringAsFixed(3), Icons.inventory_2_outlined, V3Style.blue),
            _stat('Needs Attention', '$attention', Icons.warning_amber_outlined, V3Style.warning),
            _stat('Out of Stock', '$out', Icons.remove_shopping_cart_outlined, V3Style.danger),
            _stat('Suggested Purchase', reorderValue.toStringAsFixed(3), Icons.shopping_bag_outlined, V3Style.purple),
            _stat('Expiry Value at Risk', expiryRiskValue.toStringAsFixed(3), Icons.event_busy_outlined, const Color(0xFFAD1457)),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, box) {
            final stacked = box.maxWidth < 900;
            final movement = _panel(
              context,
              'Inventory signals',
              [
                _bar('Fast moving', fast, rows.length, V3Style.blue),
                _bar('Slow moving', slow, rows.length, V3Style.warning),
                _bar('Dead stock', dead, rows.length, V3Style.danger),
                _bar('Expiring ≤30d', expiring, rows.length, const Color(0xFFAD1457)),
                _bar('Demand rising', rising, rows.length, V3Style.teal),
                _bar('Demand falling', falling, rows.length, const Color(0xFFEF6C00)),
              ],
            );
            final actions = _panel(
              context,
              'What the business should consider',
              [
                _actionLine(Icons.shopping_cart_checkout_outlined,
                    '${buy.length} products have a suggested replenishment quantity. Smart Buying can prioritize them and optionally allocate a budget.'),
                _actionLine(Icons.rule_outlined,
                    '$review products need a manual target or more history before RELIQ can make a confident reorder decision.'),
                _actionLine(Icons.pause_circle_outline,
                    '${overstock.length} products are overstocked. Pause purchasing and consider promotion, transfer, markdown, or supplier return.'),
                _actionLine(Icons.event_busy_outlined,
                    '${expiry.length} products have projected expiry exposure. Sell through or reduce future buying before value is lost.'),
                _actionLine(Icons.schedule_outlined,
                    '$notSold products have not sold recently. Review price, placement, promotion, or whether they should remain active.'),
              ],
            );
            if (stacked) {
              return Column(children: [movement, const SizedBox(height: 12), actions]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: movement),
                const SizedBox(width: 12),
                Expanded(child: actions),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        _ranked(
          context,
          'Top Purchase Priorities',
          buy.take(6).toList(),
          (r) => '${_n(r, 'suggested_order').toStringAsFixed(2)} ${r['unit'] ?? ''} suggested • ${r['confidence']} confidence • ${r['target_source']}',
        ),
        const SizedBox(height: 12),
        _ranked(
          context,
          'Largest Overstock / Sell-through Opportunities',
          overstock.take(6).toList(),
          (r) {
            final coverage = _n(r, 'coverage_days');
            return coverage < 0
                ? '${_n(r, 'stock_value').toStringAsFixed(3)} tied in stock • no reliable recent sales rate'
                : '${coverage.toStringAsFixed(0)} days of stock • ${_n(r, 'stock_value').toStringAsFixed(3)} stock value';
          },
        ),
        const SizedBox(height: 12),
        _ranked(
          context,
          'Projected Expiry Exposure',
          expiry.take(6).toList(),
          (r) => '${_n(r, 'projected_stock_at_expiry').toStringAsFixed(2)} units may remain • ${_n(r, 'projected_expiry_value').toStringAsFixed(3)} value at risk',
        ),
      ],
    );
  }

  List<String> _options(List<Map<String,Object?>> rows,String field) => ({for(final r in rows) '${r[field.toLowerCase()]??''}'}..remove('')..remove('All')).toList()..sort();

  Widget _decisions(List<Map<String, Object?>> all) {
    final rows = _filtered(all);
    final pages = rows.isEmpty ? 1 : ((rows.length + pageSize - 1) ~/ pageSize);
    if (page >= pages) page = pages - 1;
    final start = page * pageSize;
    final pageRows = rows.skip(start).take(pageSize).toList();

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: V3Style.info.withValues(alpha: .06),
            border: Border.all(color: V3Style.info.withValues(alpha: .20)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: V3Style.info),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Each product is explained in plain language. Expand a product to see the raw figures, how RELIQ interpreted them, the forecast confidence, and the recommended business action.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search product / SKU / category',
                  ),
                  onChanged: (value) => setState(() {
                    query = value;
                    page = 0;
                  }),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  value: filter,
                  decoration: const InputDecoration(labelText: 'View'),
                  items: filters
                      .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                      .toList(),
                  onChanged: (value) => setState(() {
                    filter = value ?? 'All';
                    page = 0;
                  }),
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  value: sort,
                  decoration: const InputDecoration(labelText: 'Sort by'),
                  items: const [
                    'Attention',
                    'Stock Quantity',
                    'Expiry Date',
                    'Recommended Action',
                    'Name',
                    'Demand',
                    'Coverage',
                    'Stock Value',
                    'Expiry Risk',
                  ]
                      .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                      .toList(),
                  onChanged: (value) => setState(() {
                    sort = value ?? 'Attention';
                    page = 0;
                  }),
                ),
              ),
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<int>(
                  value: pageSize,
                  decoration: const InputDecoration(labelText: 'Rows'),
                  items: const [10, 25, 50, 100]
                      .map((x) => DropdownMenuItem(value: x, child: Text('$x')))
                      .toList(),
                  onChanged: (value) => setState(() {
                    pageSize = value ?? 10;
                    page = 0;
                  }),
                ),
              ),
              FutureBuilder<List<Map<String,Object?>>>(future:branchesFuture,builder:(ctx,snap)=>SizedBox(width:180,child:DropdownButtonFormField<String>(value:branchId,isExpanded:true,decoration:const InputDecoration(labelText:'Branch'),items:[const DropdownMenuItem<String>(value:null,child:Text('Current branch')),...(snap.data??[]).map((b)=>DropdownMenuItem(value:'${b['id']}',child:Text('${b['name']}')))],onChanged:(v)=>setState((){branchId=v;category=supplier='All';page=0;_future=AppDatabase.instance.inventoryIntelligence(lookbackDays:days,branchIdOverride:branchId);})))),
              for(final type in ['Movement','Stock status','Expiry status']) SizedBox(width:180,child:DropdownButtonFormField<String>(isExpanded:true,value:type=='Movement'?movementFilter:type=='Stock status'?stockFilter:expiryFilter,decoration:InputDecoration(labelText:type),items:(type=='Movement'?['All','Fast Moving','Medium Moving','Slow Moving','Dead Stock','Demand Rising','Demand Falling']:type=='Stock status'?['All','Low Stock','Out of Stock','Overstock']:['All','Expiring Soon','Expired']).map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:(v)=>setState((){if(type=='Movement'){movementFilter=v!;}else if(type=='Stock status'){stockFilter=v!;}else{expiryFilter=v!;}page=0;}))),
              for (final field in ['Category', 'Supplier'])
                SizedBox(width: 180, child: DropdownButtonFormField<String>(
                  value: field == 'Category' ? category : supplier, isExpanded: true,
                  decoration: InputDecoration(labelText: field),
                  items: ['All', ..._options(all,field)].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                  onChanged: (v) => setState(() { if (field == 'Category') { category = v ?? 'All'; } else { supplier = v ?? 'All'; } page = 0; }),
                )),
              if (filter == 'Expiring Soon' || expiryFilter == 'Expiring Soon') SizedBox(width: 150, child: DropdownButtonFormField<int>(value: expiryWindow, decoration: const InputDecoration(labelText: 'Expiry within'), items: [7,14,30,60,90].map((d) => DropdownMenuItem(value:d,child:Text('$d days'))).toList(), onChanged:(v)=>setState((){expiryWindow=v??30;page=0;}))),
              Text('${rows.length} products', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: pageRows.isEmpty
              ? const Center(child: Text('No products match this view.'))
              : ListView.separated(
                  itemCount: pageRows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _decisionCard(pageRows[index]),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('Page ${page + 1} of $pages'),
            const SizedBox(width: 8),
            IconButton(
              onPressed: page > 0 ? () => setState(() => page--) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              onPressed: page + 1 < pages ? () => setState(() => page++) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }

  Widget _decisionCard(Map<String, Object?> row) {
    final coverage = _n(row, 'coverage_days');
    final trend = (row['demand_trend_pct'] as num?)?.toDouble();
    final confidence = '${row['confidence'] ?? 'Insufficient'}';
    final unit = '${row['unit'] ?? ''}'.trim();
    final daysExpiry = row['days_to_expiry'];
    final accent = _healthColor('${row['health']}');

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: Container(
          width: 7,
          height: 44,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        title: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${row['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            _chip('${row['health']}', accent),
            _chip('${row['demand_signal']}', V3Style.info),
            _chip('${row['demand_state'] ?? 'Demand review'}', (row['auto_purchase_eligible'] as num? ?? 0).toInt()==1 ? V3Style.success : V3Style.warning),
            _chip('$confidence confidence', _confidenceColor(confidence)),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${row['explanation'] ?? ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 16,
                runSpacing: 5,
                children: [
                  _compactMetric('On hand', '${_n(row, 'stock').toStringAsFixed(2)} $unit'),
                  _compactMetric('Stock will last', coverage < 0 ? 'Unknown' : '${coverage.toStringAsFixed(0)} days'),
                  _compactMetric('Last sold', row['days_since_sale'] == null ? 'Never / no record' : '${row['days_since_sale']} days ago'),
                  _compactMetric('Suggested purchase', _n(row, 'suggested_order') <= 0 ? 'None' : '${_n(row, 'suggested_order').toStringAsFixed(2)} $unit'),
                ],
              ),
            ],
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: V3Style.rowStripe(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Recommended action', style: TextStyle(fontWeight: FontWeight.w800, color: accent)),
                const SizedBox(height: 5),
                Text('${row['recommendation'] ?? 'Keep monitoring'}'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 18,
                  runSpacing: 12,
                  children: [
                    _detailMetric('SKU', '${row['sku'] ?? '—'}'),
                    _detailMetric('Category', '${row['category'] ?? '—'}'),
                    _detailMetric('Recent sales', '${_n(row, 'sold_qty').toStringAsFixed(2)} $unit'),
                    _detailMetric('Forecast daily demand', _n(row, 'velocity').toStringAsFixed(2)),
                    _detailMetric('Demand trend', trend == null ? '${row['demand_signal']}' : '${trend >= 0 ? '+' : ''}${trend.toStringAsFixed(0)}%'),
                    _detailMetric('Forecast confidence', '$confidence (${_n(row, 'forecast_confidence_score').toStringAsFixed(0)}/100)'),
                    _detailMetric('Demand state', '${row['demand_state'] ?? 'Review'}'),
                    _detailMetric('Purchase eligibility', (row['purchase_blocked'] as num? ?? 0).toInt()==1 ? 'Blocked — ${row['purchase_block_reason'] ?? 'Review'}' : 'Eligible'),
                    _detailMetric('Forecast model', '${row['forecast_model'] ?? 'Adaptive ensemble'}'),
                    _detailMetric('Demand history source', '${row['forecast_history_source'] ?? 'Own product history'}'),
                    _detailMetric('7-day forecast', '${_n(row, 'forecast_7_days').toStringAsFixed(2)} $unit'),
                    _detailMetric('30-day forecast', '${_n(row, 'forecast_30_days').toStringAsFixed(2)} $unit'),
                    _detailMetric('60-day forecast', '${_n(row, 'forecast_60_days').toStringAsFixed(2)} $unit'),
                    _detailMetric('90-day forecast', '${_n(row, 'forecast_90_days').toStringAsFixed(2)} $unit'),
                    _detailMetric('Last-year same 30 days', _n(row, 'seasonality_available') > 0 ? '${_n(row, 'same_period_last_year_30').toStringAsFixed(2)} $unit' : 'Not enough history'),
                    _detailMetric('Seasonality factor', _n(row, 'seasonality_available') > 0 ? '${_n(row, 'seasonality_factor').toStringAsFixed(2)}×' : 'Not available'),
                    _detailMetric('Demand variability', _n(row, 'demand_variability').toStringAsFixed(2)),
                    _detailMetric('Safety stock', '${_n(row, 'safety_stock').toStringAsFixed(2)} $unit'),
                    _detailMetric('Auto minimum / reorder point', '${_n(row, 'auto_min_stock').toStringAsFixed(2)} $unit'),
                    _detailMetric('Auto target stock', '${_n(row, 'auto_target_stock').toStringAsFixed(2)} $unit'),
                    _detailMetric('Recommended reorder date', '${row['recommended_reorder_date'] ?? '—'}'),
                    _detailMetric('Expected stockout date', '${row['expected_stockout_date'] ?? '—'}'),
                    _detailMetric('Recent fit accuracy', row['forecast_recent_fit_accuracy'] == null ? 'Not enough comparison data' : '${_n(row, 'forecast_recent_fit_accuracy').toStringAsFixed(0)}%'),
                    _detailMetric('Recommended stock', '${_n(row, 'dynamic_target').toStringAsFixed(2)} $unit'),
                    _detailMetric('Target basis', '${row['target_source'] ?? '—'}'),
                    _detailMetric('Stock value', _n(row, 'stock_value').toStringAsFixed(3)),
                    _detailMetric('Nearest expiry', daysExpiry == null ? 'Not tracked / unavailable' : '${row['nearest_expiry']} ($daysExpiry days)'),
                    _detailMetric('Stock likely left at expiry', '${_n(row, 'projected_stock_at_expiry').toStringAsFixed(2)} $unit'),
                    _detailMetric('Expiry value at risk', _n(row, 'projected_expiry_value').toStringAsFixed(3)),
                    FutureBuilder<List<Map<String,Object?>>>(future:AppDatabase.instance.db.rawQuery('SELECT b.name,COALESCE(bs.qty,0) qty FROM branches b LEFT JOIN branch_stock bs ON bs.branch_id=b.id AND bs.product_id=? ORDER BY b.name',['${row['id']}']),builder:(ctx,snap)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Stock across branches',style:TextStyle(fontWeight:FontWeight.w700)),for(final b in snap.data??[])Text('${b['name']}: ${(b['qty'] as num? ?? 0).toStringAsFixed(2)}'),if(snap.hasData)Text('Total: ${snap.data!.fold<double>(0,(sum,b)=>sum+(b['qty'] as num? ?? 0).toDouble()).toStringAsFixed(2)}',style:const TextStyle(fontWeight:FontWeight.w800))])),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon, Color color) {
    return InkWell(onTap:()=>setState((){filter={'Inventory Health':'All','Stock Value':'All','Needs Attention':'Needs Attention','Out of Stock':'Out of Stock','Suggested Purchase':'Reorder Recommended','Expiry Value at Risk':'Projected Expiry Risk'}[label]??'All';page=0;_tabs.index=1;}),child:SizedBox(
      width: 205,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color),
                  const Spacer(),
                  Container(
                    width: 34,
                    height: 4,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _panel(BuildContext context, String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _bar(String label, int value, int total, Color color) {
    final ratio = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text('$value', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 5),
          LayoutBuilder(
            builder: (_, box) => Stack(
              children: [
                Container(
                  height: 8,
                  width: box.maxWidth,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                Container(
                  height: 8,
                  width: box.maxWidth * ratio,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionLine(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  Widget _ranked(
    BuildContext context,
    String title,
    List<Map<String, Object?>> rows,
    String Function(Map<String, Object?>) detail,
  ) {
    return _panel(
      context,
      title,
      [
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('Nothing needs attention here right now.'),
          ),
        for (final row in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.chevron_right),
            title: Text('${row['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(detail(row)),
            trailing: _chip('${row['confidence']}', _confidenceColor('${row['confidence']}')),
          ),
      ],
    );
  }

  Widget _compactMetric(String label, String value) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: value),
        ],
      ),
    );
  }

  Widget _detailMetric(String label, String value) {
    return SizedBox(
      width: 205,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }

  Color _healthColor(String health) {
    switch (health) {
      case 'Healthy':
        return V3Style.success;
      case 'Out of Stock':
        return V3Style.danger;
      case 'Expiry Risk':
        return const Color(0xFFAD1457);
      case 'Reorder':
        return V3Style.warning;
      case 'Overstock':
        return V3Style.purple;
      case 'Dead Stock':
      case 'Dormant':
        return V3Style.muted;
      case 'Stock Discrepancy':
        return V3Style.warning;
      case 'Do Not Buy':
        return V3Style.danger;
      case 'Review':
        return V3Style.info;
      default:
        return V3Style.blue;
    }
  }

  Color _confidenceColor(String confidence) {
    switch (confidence) {
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
}


class _InventoryAnalyticsLoading extends StatelessWidget {
  const _InventoryAnalyticsLoading();
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox.square(dimension: 30, child: CircularProgressIndicator(strokeWidth: 3)),
      const SizedBox(height: 14),
      const Text('Preparing Inventory Intelligence', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
      const SizedBox(height: 6),
      Text('The first calculation can take longer on a large database. RELIQ saves the result and refreshes stale analytics in the background.', textAlign: TextAlign.center, style: TextStyle(color: V3Style.mutedFor(context))),
    ]),
  ));
}
