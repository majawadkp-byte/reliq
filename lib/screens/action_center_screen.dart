import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';
import '../ui/searchable_map_select.dart';

class ActionCenterScreen extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  final ValueChanged<String>? onInventory;
  const ActionCenterScreen({super.key, this.onNavigate, this.onInventory});

  @override
  State<ActionCenterScreen> createState() => _ActionCenterScreenState();
}

class _ActionCenterScreenState extends State<ActionCenterScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  late Future<Map<String, dynamic>> _future;
  int days = 30;
  bool creatingDrafts=false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _future = AppDatabase.instance.businessActionCenter(lookbackDays: days);
  }

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  void _reload({bool force = false}) => setState(() => _future = AppDatabase.instance.businessActionCenter(lookbackDays: days, forceRefresh: force));
  double _n(Map row, String key) => (row[key] as num? ?? 0).toDouble();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Business Action Center could not load: ${snapshot.error}'));
        if (!snapshot.hasData) return const _ActionAnalyticsLoading();
        final data = snapshot.data!;
        final summary = Map<String, Object?>.from(data['summary'] as Map);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20,18,20,20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Business Action Center', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('One place for the decisions RELIQ identifies need attention — with the reason, confidence and next action.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ])),
              const SizedBox(width: 12),
              DropdownButton<int>(value: days, items: const [14,30,60,90].map((d)=>DropdownMenuItem(value:d,child:Text('$d-day view'))).toList(), onChanged:(v){days=v??30;_reload(force:true);}),
              const SizedBox(width: 8),
              IconButton(tooltip:'Recalculate latest analytics', onPressed:()=>_reload(force:true), icon:const Icon(Icons.refresh)),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing:10,runSpacing:10,children:[
              _metric('Actions','${summary['action_count'] ?? 0}',Icons.task_alt_outlined,V3Style.danger),
              _metric('Stock value','KWD ${_n(summary,'stock_value').toStringAsFixed(3)}',Icons.inventory_2_outlined,V3Style.info),
              _metric('Suggested buy','KWD ${_n(summary,'reorder_value').toStringAsFixed(3)}',Icons.shopping_cart_checkout_outlined,V3Style.success),
              _metric('Expiry risk','KWD ${_n(summary,'expiry_risk').toStringAsFixed(3)}',Icons.event_busy_outlined,V3Style.warning),
              _metric('Overdue','KWD ${_n(summary,'overdue').toStringAsFixed(3)}',Icons.payments_outlined,V3Style.purple),
              _metric('Stock discrepancies','${_n(summary,'stock_discrepancies').toInt()}',Icons.fact_check_outlined,V3Style.warning),
              _metric('Dormant products','${_n(summary,'dormant_products').toInt()}',Icons.bedtime_outlined,V3Style.muted),
            ]),
            const SizedBox(height: 14),
            TabBar(controller:_tabs,isScrollable:true,tabs:const [
              Tab(icon:Icon(Icons.bolt_outlined),text:'Actions'),
              Tab(icon:Icon(Icons.grid_view_outlined),text:'Portfolio'),
              Tab(icon:Icon(Icons.people_alt_outlined),text:'Customers & Suppliers'),
              Tab(icon:Icon(Icons.account_tree_outlined),text:'Branches'),
            ]),
            const SizedBox(height: 10),
            Expanded(child:TabBarView(controller:_tabs,children:[
              _actions(List<Map<String,Object?>>.from(data['actions'] as List)),
              _portfolio(List<Map<String,Object?>>.from(data['portfolio'] as List)),
              _parties(List<Map<String,Object?>>.from(data['customers'] as List),List<Map<String,Object?>>.from(data['suppliers'] as List)),
              _branches(List<Map<String,Object?>>.from(data['branches'] as List)),
            ])),
          ]),
        );
      },
    );
  }

  Future<void> _draftOrders() async {
    if(creatingDrafts)return;
    creatingDrafts=true;
    try {
      final products = (await AppDatabase.instance.inventoryIntelligence(lookbackDays: days)).where((r)=>_n(r,'suggested_order') > .001).toList();
      final suppliers = await AppDatabase.instance.suppliers(activeOnly:true, limit:10000);
      if (!mounted) return;
      if (products.isEmpty || suppliers.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Add an active supplier and review replenishment products first.'))); return; }
      final selected = <String,String>{};
      final quantities = <String,TextEditingController>{};
      for (final p in products) {
        final id = '${p['id']}';
        quantities[id] = TextEditingController(text:_n(p,'suggested_order').toStringAsFixed(2));
        final matches = suppliers.where((v)=>'${v['name']}'=='${p['supplier']}').toList();
        if(matches.length==1) selected[id]='${matches.first['id']}';
      }
      var error = '';
      final ok = await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
        title:const Text('Review replenishment drafts'),
        content:SizedBox(width:760,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('One draft per supplier. Set quantity to 0 to exclude a product. Quantities follow configured minimums and pack sizes.'),
          const SizedBox(height:12),
          for(final p in products) Padding(padding:const EdgeInsets.only(bottom:12),child:Row(children:[
            Expanded(child:Text('${p['name']}')),
            SizedBox(width:110,child:TextField(controller:quantities['${p['id']}'],keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Quantity'))),
            const SizedBox(width:10),
            SizedBox(width:280,child:SearchableMapSelect(
              options:suppliers,
              value:selected['${p['id']}'],
              labelText:'Supplier',
              hintText:'Name / phone / email',
              display:(v)=>'${v['name']}',
              subtitle:(v)=>[if('${v['phone'] ?? ''}'.trim().isNotEmpty)'${v['phone']}',if('${v['email'] ?? ''}'.trim().isNotEmpty)'${v['email']}'].join(' • '),
              onChanged:(v){if(v!=null)update(()=>selected['${p['id']}']=v);},
            )),
          ])),
          if(error.isNotEmpty) Text(error,style:const TextStyle(color:Colors.red)),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:(){
          for(final p in products){final id='${p['id']}';final qty=double.tryParse(quantities[id]!.text);if(qty==null||!qty.isFinite||qty<0){update(()=>error='Enter valid non-negative quantities.');return;}if(qty>0&&selected[id]==null){update(()=>error='Choose a supplier for every included product.');return;}}
          Navigator.pop(ctx,true);
        },child:const Text('Create Drafts'))],
      )));
      if(ok!=true)return;
      final groups=<String,List<Map<String,Object?>>>{};
      for(final p in products){final id='${p['id']}';final qty=double.parse(quantities[id]!.text);if(qty>0)groups.putIfAbsent(selected[id]!,()=>[]).add({'product_id':id,'qty':qty,'unit_cost':p['cost']});}
      final created=<String>[];
      for(final group in groups.entries){
        try { created.add(await AppDatabase.instance.createPurchaseOrder(supplierId:group.key,items:group.value,placeOrder:false,notes:'RELIQ replenishment recommendation • $days days')); }
        catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${created.length} drafts created; ${suppliers.firstWhere((s)=>s['id']==group.key)['name']}: $e')));_reload();return;}
      }
      if(mounted){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${created.length} supplier drafts created. Review and place them in Purchase Orders.')));widget.onNavigate?.call(19);}
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}finally{creatingDrafts=false;}
  }

  Widget _metric(String label,String value,IconData icon,Color accent){
    return Container(width:210,padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:Theme.of(context).cardColor,borderRadius:BorderRadius.circular(14),border:Border.all(color:Theme.of(context).dividerColor.withValues(alpha:.45))),child:Row(children:[
      Container(width:38,height:38,decoration:BoxDecoration(color:V3Style.softFor(accent,dark:Theme.of(context).brightness==Brightness.dark),borderRadius:BorderRadius.circular(10)),child:Icon(icon,color:accent,size:20)),
      const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:const TextStyle(fontSize:11,color:V3Style.muted)),const SizedBox(height:2),Text(value,style:const TextStyle(fontWeight:FontWeight.w800,fontSize:15))]))
    ]));
  }

  IconData _actionIcon(String icon)=> switch(icon){'buy'=>Icons.shopping_cart_checkout_outlined,'overstock'=>Icons.pause_circle_outline,'dead'=>Icons.trending_down_outlined,'expiry'=>Icons.event_busy_outlined,'sales'=>Icons.show_chart,'margin'=>Icons.percent_outlined,'customer'=>Icons.account_balance_wallet_outlined,'branch'=>Icons.swap_horiz_outlined,'count'=>Icons.fact_check_outlined,_=>Icons.insights_outlined};

  Widget _actions(List<Map<String,Object?>> actions){
    if(actions.isEmpty)return _empty('Nothing urgent','RELIQ did not find an unsnoozed action that crosses the current attention thresholds.');
    return ListView.separated(itemCount:actions.length,separatorBuilder:(_,__)=>const SizedBox(height:10),itemBuilder:(context,i){
      final a=actions[i]; final confidence='${a['confidence']}';
      return Card(child:Padding(padding:const EdgeInsets.all(16),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Container(width:44,height:44,decoration:BoxDecoration(color:V3Style.softFor(i<2?V3Style.danger:V3Style.info,dark:Theme.of(context).brightness==Brightness.dark),borderRadius:BorderRadius.circular(12)),child:Icon(_actionIcon('${a['icon']}'),color:i<2?V3Style.danger:V3Style.info)),
        const SizedBox(width:14),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Wrap(spacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[Text('${a['kind']}',style:const TextStyle(fontSize:11,fontWeight:FontWeight.w800,color:V3Style.muted)),Chip(label:Text('$confidence confidence'),visualDensity:VisualDensity.compact,backgroundColor:Theme.of(context).colorScheme.surfaceContainerHighest,labelStyle:TextStyle(color:Theme.of(context).colorScheme.onSurface,fontWeight:FontWeight.w700))]),
          const SizedBox(height:4),Text('${a['title']}',style:const TextStyle(fontSize:16,fontWeight:FontWeight.w800)),const SizedBox(height:5),Text('${a['message']}',style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant,height:1.35)),
          const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[
            FilledButton.icon(onPressed:(){if(a['key']=='buy'){_draftOrders();return;} final nav=(a['nav'] as num?)?.toInt();if(nav==8){widget.onInventory?.call(a['key']=='overstock'?'Overstock':a['key']=='expiry'?'Projected Expiry Risk':'Not Sold Recently');}else if(nav!=null){widget.onNavigate?.call(nav);}},icon:const Icon(Icons.arrow_forward,size:17),label:Text('${a['action']}')),
            OutlinedButton.icon(onPressed:()async{await AppDatabase.instance.snoozeBusinessAction('${a['key']}',days:7,fingerprint:'${a['fingerprint'] ?? ''}');_reload(force:true);},icon:const Icon(Icons.snooze,size:17),label:const Text('Snooze 7 days')),
            TextButton.icon(onPressed:()async{await AppDatabase.instance.resolveBusinessAction('${a['key']}',fingerprint:'${a['fingerprint'] ?? ''}');_reload(force:true);},icon:const Icon(Icons.check_circle_outline,size:17),label:const Text('Resolve')),
            PopupMenuButton<String>(tooltip:'More action options',onSelected:(v)async{if(v=='dismiss'){await AppDatabase.instance.dismissBusinessAction('${a['key']}',fingerprint:'${a['fingerprint'] ?? ''}');_reload(force:true);}},itemBuilder:(_)=>const [PopupMenuItem(value:'dismiss',child:ListTile(dense:true,leading:Icon(Icons.visibility_off_outlined),title:Text('Dismiss until condition changes')))],child:const Padding(padding:EdgeInsets.symmetric(horizontal:8,vertical:10),child:Icon(Icons.more_horiz))),
          ])
        ]))
      ])));
    });
  }

  Widget _portfolio(List<Map<String,Object?>> rows){
    if(rows.isEmpty)return _empty('No portfolio data','Sales and stock history will populate ABC/XYZ and GMROI signals.');
    return Column(children:[
      Padding(padding:const EdgeInsets.only(bottom:8),child:Align(alignment:Alignment.centerLeft,child:Text('ABC = revenue importance · XYZ = demand consistency proxy · GMROI = gross profit ÷ current inventory cost.',style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant,fontSize:12)))),
      Expanded(child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:SingleChildScrollView(child:DataTable(columns:const [DataColumn(label:Text('Product')),DataColumn(label:Text('Class')),DataColumn(label:Text('Revenue')),DataColumn(label:Text('Gross Profit')),DataColumn(label:Text('Inventory Value')),DataColumn(label:Text('Age')),DataColumn(label:Text('Returns')),DataColumn(label:Text('GMROI'))],rows:rows.take(100).map((r)=>DataRow(cells:[DataCell(SizedBox(width:220,child:Text('${r['name']}',overflow:TextOverflow.ellipsis))),DataCell(Text('${r['abc']}${r['xyz']}',style:const TextStyle(fontWeight:FontWeight.w800))),DataCell(Text('KWD ${_n(r,'revenue').toStringAsFixed(3)}')),DataCell(Text('KWD ${_n(r,'gross_profit').toStringAsFixed(3)}')),DataCell(Text('KWD ${_n(r,'inventory_value').toStringAsFixed(3)}')),DataCell(Text('${_n(r,'avg_age_days').toStringAsFixed(0)}d')),DataCell(Text('${_n(r,'return_rate_pct').toStringAsFixed(1)}%')),DataCell(Text(_n(r,'gmroi').toStringAsFixed(2)))] )).toList()))))
    ]);
  }

  Widget _parties(List<Map<String,Object?>> customers,List<Map<String,Object?>> suppliers){
    return ListView(children:[
      Text('Customer intelligence · last $days days · current branch',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.w800)),
      const SizedBox(height:8),
      if(customers.isEmpty)const Text('No customer activity in this period.'),
      ...customers.map((r)=>_partyCard(r,false,customers.fold<double>(0,(s,r)=>s+_n(r,'revenue')))),
      const SizedBox(height:18),
      Text('Supplier intelligence · last $days days · current branch',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.w800)),
      const SizedBox(height:8),
      if(suppliers.isEmpty)const Text('No supplier activity in this period.'),
      ...suppliers.map((r)=>_partyCard(r,true,suppliers.fold<double>(0,(s,r)=>s+_n(r,'spend')))),
    ]);
  }

  Widget _partyCard(Map<String,Object?> r,bool supplier,double total){
    final value=_n(r,supplier?'spend':'revenue');final count=_n(r,supplier?'purchase_count':'visits');final share=total>0?value/total:0.0;
    return Card(child:ExpansionTile(
      key:PageStorageKey('party-${supplier}-${r['id']}-$days'),
      leading:CircleAvatar(child:Icon(supplier?Icons.local_shipping_outlined:Icons.person_outline)),
      title:Text('${r['name']}',style:const TextStyle(fontWeight:FontWeight.w800)),
      subtitle:Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('${count.toInt()} ${supplier?'purchases':'visits'} · Average KWD ${(count>0?value/count:0).toStringAsFixed(3)} · Outstanding KWD ${_n(r,'balance').toStringAsFixed(3)} (all branches)'),
        Text('Last ${supplier?'purchase':'sale'}: ${r[supplier?'last_purchase':'last_sale']??'No history'}'),
        if(!supplier)Text('Overdue KWD ${_n(r,'overdue').toStringAsFixed(3)}'),
        if(supplier && r['cost_change_pct']!=null)Text('Comparable cost change: ${_n(r,'cost_change_pct').toStringAsFixed(1)}%'),
        const SizedBox(height:6),LinearProgressIndicator(value:share.clamp(0,1).toDouble(),minHeight:5),
        const SizedBox(height:4),Text('${(share*100).toStringAsFixed(1)}% of displayed ${supplier?'supplier spend':'customer revenue'}'),
      ])),
      trailing:Text('KWD ${value.toStringAsFixed(3)}',style:const TextStyle(fontWeight:FontWeight.w800)),
      children:[_PartyDetails(id:'${r['id']}',supplier:supplier,days:days)],
    ));
  }

  Widget _branches(List<Map<String,Object?>> rows){
    if(rows.isEmpty)return _empty('No transfer opportunity detected','RELIQ needs at least two branches with enough sales and stock separation before suggesting a transfer.');
    return ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const Divider(),itemBuilder:(context,i){final r=rows[i];return ListTile(leading:const CircleAvatar(child:Icon(Icons.swap_horiz_outlined)),title:Text('${r['product_name']}'),subtitle:Text('Move from ${r['from_branch']} (${_n(r,'from_stock').toStringAsFixed(1)} on hand) → ${r['to_branch']} (${_n(r,'to_stock').toStringAsFixed(1)} on hand; ${_n(r,'to_sold').toStringAsFixed(1)} sold in period)'),trailing:FilledButton(onPressed:()=>widget.onNavigate?.call(4),child:const Text('Transfer')));});
  }

  Widget _empty(String title,String message)=>Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:520),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.check_circle_outline,size:42,color:V3Style.success),const SizedBox(height:10),Text(title,style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.w800)),const SizedBox(height:5),Text(message,textAlign:TextAlign.center,style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant))])));
}

class _PartyDetails extends StatefulWidget {
  final String id;final bool supplier;final int days;
  const _PartyDetails({required this.id,required this.supplier,required this.days});
  @override State<_PartyDetails> createState()=>_PartyDetailsState();
}
class _PartyDetailsState extends State<_PartyDetails>{
  late final future=AppDatabase.instance.partyInsight(widget.id,supplier:widget.supplier,days:widget.days);
  @override Widget build(BuildContext context)=>FutureBuilder<Map<String,dynamic>>(future:future,builder:(ctx,snap){
    if(snap.hasError)return Padding(padding:const EdgeInsets.all(12),child:Text('${snap.error}'));
    if(!snap.hasData)return const Padding(padding:EdgeInsets.all(12),child:CircularProgressIndicator());
    final trend=(snap.data!['trend'] as List).cast<Map<String,Object?>>();final products=(snap.data!['products'] as List).cast<Map<String,Object?>>();final payments=snap.data!['payments'] as Map;
    Widget bars(List<Map<String,Object?>> rows,String label){final maxValue=rows.fold<double>(1,(m,r){final v=(r['value'] as num? ?? 0).toDouble();return v>m?v:m;});return Column(children:[for(final r in rows)Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Row(children:[SizedBox(width:180,child:Text('${r[label]}',overflow:TextOverflow.ellipsis)),Expanded(child:LinearProgressIndicator(value:((r['value'] as num? ?? 0).toDouble()/maxValue).clamp(0,1).toDouble(),minHeight:10)),const SizedBox(width:10),Text('KWD ${(r['value'] as num? ?? 0).toStringAsFixed(3)}')]))]);}
    return Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Monthly invoice value · before returns',style:TextStyle(fontWeight:FontWeight.w700)),bars(trend,'month'),
      const SizedBox(height:10),const Text('Top products by invoice value',style:TextStyle(fontWeight:FontWeight.w700)),bars(products,'name'),
      const SizedBox(height:10),Text('${payments['count']} payment entries · KWD ${(payments['total'] as num? ?? 0).toStringAsFixed(3)} total payment activity · Last payment: ${payments['last_payment']??'No history'}'),
    ]));
  });
}


class _ActionAnalyticsLoading extends StatelessWidget {
  const _ActionAnalyticsLoading();
  @override
  Widget build(BuildContext context) => const Center(child: Padding(
    padding: EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(dimension: 30, child: CircularProgressIndicator(strokeWidth: 3)),
      SizedBox(height: 14),
      Text('Preparing Business Action Center', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
      SizedBox(height: 6),
      Text('Using the shared RELIQ analytics snapshot so inventory, Smart Buying and the Morning Brief stay consistent.', textAlign: TextAlign.center, style: TextStyle(color: V3Style.muted)),
    ]),
  ));
}
