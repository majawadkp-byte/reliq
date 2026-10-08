import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/document_share_service.dart';
import '../services/print_service.dart';
import '../services/whatsapp_service.dart';
import '../ui/v3_style.dart';
import '../ui/shortcut_helper_bar.dart';
import '../ui/searchable_map_select.dart';
import '../ui/reliq_loading.dart';

class SalesPosScreen extends StatefulWidget {
  final bool touchMode;
  final bool defaultTileView;
  final String defaultPaymentMethod;
  final bool showShortcutHelpers;
  const SalesPosScreen({
    super.key,
    this.touchMode = false,
    this.defaultTileView = true,
    this.defaultPaymentMethod = 'Cash',
    this.showShortcutHelpers = true,
  });

  @override
  State<SalesPosScreen> createState() => _SalesPosScreenState();
}

class _SalesPosScreenState extends State<SalesPosScreen> {
  final searchCtl = TextEditingController();
  final discountCtl = TextEditingController(text: '0');
  final deliveryCtl = TextEditingController(text: '0');
  final otherCtl = TextEditingController(text: '0');
  final paidCtl = TextEditingController();
  final notesCtl = TextEditingController();
  final searchFocus = FocusNode();
  final customerFocus = FocusNode();
  final discountFocus = FocusNode();
  final deliveryFocus = FocusNode();
  final paidFocus = FocusNode();
  final cart = <String, Map<String, Object?>>{};

  late Future<List<Map<String, Object?>>> _customersFuture;
  late Future<List<Map<String, Object?>>> _productsFuture;
  Timer? _productSearchDebounce;
  String query = '';
  String category = 'All';
  String customerId = '';
  String paymentMethod = 'Cash';
  bool tileView = true;
  final List<Map<String,Object?>> splitTenders = [];

  @override
  void initState() {
    super.initState();
    tileView = widget.defaultTileView;
    paymentMethod = widget.defaultPaymentMethod;
    _customersFuture = AppDatabase.instance.customers(activeOnly: true, limit: 10000);
    _productsFuture = AppDatabase.instance.products(activeOnly: true);
  }

  double _number(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
  double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
  double _lineGross(Map<String, Object?> row) => _d(row['qty']) * _d(row['price']);
  double _lineDiscount(Map<String, Object?> row) => math.min(_d(row['line_discount']).clamp(0, double.infinity), _lineGross(row));
  bool _taxInclusive(Map<String, Object?> row) => ((row['tax_inclusive'] as num?) ?? (row['tax_profile_inclusive'] as num?) ?? 0).toInt() == 1;
  double _lineTax(Map<String, Object?> row) {
    final taxable = (_lineGross(row) - _lineDiscount(row)).clamp(0, double.infinity).toDouble();
    final rate = _d(row['tax_rate']).clamp(0, 100).toDouble();
    if (rate <= 0) return 0;
    return _taxInclusive(row) ? taxable * rate / (100 + rate) : taxable * rate / 100;
  }
  double _lineTotal(Map<String, Object?> row) {
    final net = (_lineGross(row) - _lineDiscount(row)).clamp(0, double.infinity).toDouble();
    return _taxInclusive(row) ? net : net + _lineTax(row);
  }

  double get subtotal => cart.values.fold(0.0, (sum, row) => sum + _lineGross(row));
  double get itemDiscount => cart.values.fold(0.0, (sum, row) => sum + _lineDiscount(row));
  double get taxTotal => cart.values.fold(0.0, (sum, row) => sum + _lineTax(row));
  double get total => (cart.values.fold<double>(0, (sum, row) => sum + _lineTotal(row)) - _number(discountCtl) + _number(deliveryCtl) + _number(otherCtl)).clamp(0, double.infinity).toDouble();

  @override
  void dispose() {
    searchCtl.dispose();
    discountCtl.dispose();
    deliveryCtl.dispose();
    otherCtl.dispose();
    paidCtl.dispose();
    notesCtl.dispose();
    _productSearchDebounce?.cancel();
    searchFocus.dispose();
    customerFocus.dispose();
    discountFocus.dispose();
    deliveryFocus.dispose();
    paidFocus.dispose();
    super.dispose();
  }

  bool _canAddProduct(Map<String, Object?> product) {
    if (((product['sellable'] as num?) ?? 1).toInt() != 1) return false;
    final type = (product['product_type'] ?? 'Stocked').toString();
    if (type == 'Service' || type == 'Non-stocked' || type == 'Recipe' || type == 'Combo') return true;
    return _d(product['stock']) > 0;
  }

  void _showUnavailableProduct(Map<String, Object?> product) {
    final sellable = ((product['sellable'] as num?) ?? 1).toInt() == 1;
    final name = '${product['name'] ?? 'Product'}';
    final stock = _d(product['stock']);
    final message = sellable
        ? 'OUT OF STOCK — $name cannot be added to this sale. Current stock: ${stock.toStringAsFixed(1)}.'
        : '$name is not marked as sellable and cannot be added to this sale.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        backgroundColor: Theme.of(context).colorScheme.error,
        content: Row(children: [
          const Icon(Icons.inventory_2_outlined, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        ]),
      ));
  }

  void _tryAddProduct(Map<String, Object?> product) {
    if (_canAddProduct(product)) {
      _add(product);
    } else {
      _showUnavailableProduct(product);
    }
  }

  Future<void> _add(Map<String, Object?> product) async {
    final id = product['id'] as String;
    final old = cart[id];
    final next = _d(old?['qty']) + 1;
    final type = (product['product_type'] ?? 'Stocked').toString();
    if (((product['sellable'] as num?) ?? 1).toInt() != 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This product is not marked as sellable.')));
      return;
    }
    if (type == 'Stocked' && next > _d(product['stock'])) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not enough stock for this product.')));
      return;
    }
    double groupPct = _d(old?['group_discount_pct']);
    Map<String,Object?>? pricing;
    if (old == null && customerId.isNotEmpty) {
      pricing = await AppDatabase.instance.customerProductPricing(customerId, id);
      groupPct = (pricing['discount_pct'] as num? ?? 0).toDouble();
    }
    if (!mounted) return;
    final unitPrice = _d(old?['price'] ?? product['price']);
    final autoDiscount = groupPct > 0 ? (unitPrice * next * groupPct / 100) : 0.0;
    setState(() {
      cart[id] = {
        ...product,
        'qty': next,
        'price': old?['price'] ?? product['price'] ?? 0,
        'line_discount': old == null ? autoDiscount : (groupPct > 0 ? autoDiscount : old['line_discount'] ?? 0.0),
        'group_discount_pct': groupPct,
        'last_customer_price': pricing?['last_price'],
        'last_customer_discount': pricing?['last_discount'],
        'tax_rate': old?['tax_rate'] ?? product['tax_rate'] ?? 0.0,
        'tax_inclusive': old?['tax_inclusive'] ?? product['tax_profile_inclusive'] ?? product['tax_inclusive'] ?? 0,
      };
      searchCtl.clear();
      query = '';
      _productsFuture = AppDatabase.instance.products(activeOnly: true);
    });
    searchFocus.requestFocus();
  }

  Future<void> _applyCustomerPricing(String id) async {
    if (id.isEmpty || cart.isEmpty) return;
    for (final entry in cart.entries.toList()) {
      final pricing = await AppDatabase.instance.customerProductPricing(id, entry.key);
      final pct = (pricing['discount_pct'] as num? ?? 0).toDouble();
      final line = cart[entry.key];
      if (line == null) continue;
      line['group_discount_pct'] = pct;
      line['line_discount'] = _d(line['price']) * _d(line['qty']) * pct / 100;
      line['last_customer_price'] = pricing['last_price'];
      line['last_customer_discount'] = pricing['last_discount'];
    }
    if (mounted) setState(() {});
  }

  void _changeQty(String id, double change) {
    final line = cart[id];
    if (line == null) return;
    final next = _d(line['qty']) + change;
    if (next <= 0) {
      setState(() => cart.remove(id));
      return;
    }
    final type = (line['product_type'] ?? 'Stocked').toString();
    if (type == 'Stocked' && next > _d(line['stock'])) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not enough stock.')));
      return;
    }
    setState(() => line['qty'] = next);
  }

  Future<void> _submitSearch(String value) async {
    final needle = value.trim();
    if (needle.isEmpty) return;
    final rows = await AppDatabase.instance.products(search: needle, activeOnly: true);
    if (!mounted) return;
    Map<String, Object?>? exact;
    for (final p in rows) {
      if ('${p['external_barcode'] ?? ''}' == needle || '${p['sku'] ?? ''}' == needle || '${p['internal_barcode'] ?? ''}' == needle) {
        exact = p;
        break;
      }
    }
    final eligible = rows.where((p) => ((p['sellable'] as num?) ?? 1).toInt() == 1).toList();
    final chosen = exact != null && ((exact['sellable'] as num?) ?? 1).toInt() == 1 ? exact : (eligible.isNotEmpty ? eligible.first : null);
    if (chosen != null) _tryAddProduct(chosen);
  }

  Future<String?> _quickAddCustomer() async {
    String name = '';
    String phone = '';
    String email = '';
    String address = '';
    String creditLimit = '0';
    String termsDays = '0';
    String groupId = '';
    bool creditAllowed = false;

    final groups = await AppDatabase.instance.customerGroups(activeOnly: true);
    if (!mounted) return null;

    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          title: const Row(children: [
            CircleAvatar(radius: 19, child: Icon(Icons.person_add_alt_1, size: 19)),
            SizedBox(width: 12),
            Text('Add Customer'),
          ]),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(children: [
                TextFormField(autofocus: true, decoration: const InputDecoration(labelText: 'Customer name *'), onChanged: (v) => name = v),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextFormField(decoration: const InputDecoration(labelText: 'Phone'), onChanged: (v) => phone = v)),
                  const SizedBox(width: 10),
                  Expanded(child: TextFormField(decoration: const InputDecoration(labelText: 'Email'), onChanged: (v) => email = v)),
                ]),
                const SizedBox(height: 10),
                TextFormField(decoration: const InputDecoration(labelText: 'Address'), onChanged: (v) => address = v),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: groupId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Customer class / pricing group',
                    helperText: 'Applies the class discount rules configured in Customer Groups.',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Standard customer • no pricing group'),
                    ),
                    ...groups.map(
                      (g) => DropdownMenuItem(
                        value: g['id'].toString(),
                        child: Text(
                          '${g['name']} • ${(g['default_discount_pct'] as num? ?? 0).toStringAsFixed(2)}% default',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setDialog(() => groupId = v ?? ''),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow credit sales'),
                  subtitle: const Text('Enable only if this customer can carry a balance.'),
                  value: creditAllowed,
                  onChanged: (v) => setDialog(() => creditAllowed = v),
                ),
                if (creditAllowed)
                  Row(children: [
                    Expanded(child: TextFormField(initialValue: '0', keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Credit limit (0 = unlimited)'), onChanged: (v) => creditLimit = v)),
                    const SizedBox(width: 10),
                    Expanded(child: TextFormField(initialValue: '0', keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Terms (days)'), onChanged: (v) => termsDays = v)),
                  ]),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Add Customer')),
          ],
        ),
      ),
    );

    if (save != true || name.trim().isEmpty) return null;
    final id = await AppDatabase.instance.saveCustomer({
      'name': name.trim(),
      'phone': phone.trim(),
      'email': email.trim(),
      'address': address.trim(),
      'credit_allowed': creditAllowed ? 1 : 0,
      'credit_limit': double.tryParse(creditLimit) ?? 0,
      'terms_days': int.tryParse(termsDays) ?? 0,
      'group_id': groupId.isEmpty ? null : groupId,
      'active': 1,
    });
    if (!mounted) return id;
    setState(() {
      customerId = id;
      _customersFuture = AppDatabase.instance.customers(activeOnly: true, limit: 10000);
    });
    return id;
  }

  Future<void> _configureSplitTender() async {
    final rows = <Map<String,Object?>>[
      if (splitTenders.isNotEmpty) ...splitTenders.map((x)=>Map<String,Object?>.from(x))
      else {'method':'Cash','tendered':total,'reference':''},
    ];
    final ok = await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD){
      double appliedTotal=0,changeTotal=0;
      for(final r in rows){final tender=(r['tendered'] as num? ?? 0).toDouble();final remaining=(total-appliedTotal).clamp(0,double.infinity);final applied=tender>remaining?remaining:tender;final change=(r['method']=='Cash'?(tender-applied).clamp(0,double.infinity):0).toDouble();r['amount']=applied;r['change_due']=change;appliedTotal+=applied;changeTotal+=change;}
      return AlertDialog(title:const Text('Split Tender / Change Due'),content:SizedBox(width:650,height:430,child:Column(children:[
        Text('Invoice total ${total.toStringAsFixed(3)}',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.w800)),const SizedBox(height:10),
        Expanded(child:ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const SizedBox(height:8),itemBuilder:(context,i){final r=rows[i];return Row(children:[Expanded(flex:2,child:DropdownButtonFormField<String>(value:r['method'].toString(),isExpanded:true,decoration:const InputDecoration(labelText:'Method'),items:const ['Cash','Card','Bank','Cheque','Other'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setD(()=>r['method']=v??'Cash'))),const SizedBox(width:8),Expanded(flex:2,child:TextFormField(key:ValueKey('tender-$i-${r['tendered']}'),initialValue:(r['tendered'] as num? ?? 0).toStringAsFixed(3),keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tendered'),onChanged:(v)=>setD(()=>r['tendered']=double.tryParse(v)??0))),const SizedBox(width:8),Expanded(flex:2,child:TextFormField(initialValue:(r['reference']??'').toString(),decoration:const InputDecoration(labelText:'Reference'),onChanged:(v)=>r['reference']=v)),IconButton(onPressed:rows.length>1?()=>setD(()=>rows.removeAt(i)):null,icon:const Icon(Icons.delete_outline))]);})),
        Row(children:[OutlinedButton.icon(onPressed:()=>setD(()=>rows.add({'method':'Card','tendered':0.0,'reference':''})),icon:const Icon(Icons.add),label:const Text('Add Tender')),const Spacer(),Text('Applied ${appliedTotal.toStringAsFixed(3)}',style:const TextStyle(fontWeight:FontWeight.w700)),if(changeTotal>0)...[const SizedBox(width:12),Text('Change ${changeTotal.toStringAsFixed(3)}',style:TextStyle(fontWeight:FontWeight.w800,color:Theme.of(context).colorScheme.primary))]]),
      ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:appliedTotal+0.000001>=total?()=>Navigator.pop(ctx,true):null,child:const Text('Use Split Tender'))]);
    }));
    if(ok==true){
      setState(()=>splitTenders..clear()..addAll(rows));
      paidCtl.text=total.toStringAsFixed(3); paymentMethod=rows.length>1?'Split':rows.first['method'].toString();
    }
  }

  Future<void> _holdCurrentSale() async {
    if(cart.isEmpty)return;
    final id=await AppDatabase.instance.holdSale(items:cart.values.toList(),customerId:customerId.isEmpty?null:customerId,billDiscount:_number(discountCtl),deliveryCharge:_number(deliveryCtl),otherCharge:_number(otherCtl),notes:notesCtl.text.trim());
    if(!mounted)return;
    setState((){cart.clear();customerId='';discountCtl.text='0';deliveryCtl.text='0';otherCtl.text='0';paidCtl.clear();notesCtl.clear();splitTenders.clear();});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Sale parked as $id')));
  }

  Future<void> _resumeHeldSale() async {
    final held=await AppDatabase.instance.heldSales(); if(!mounted)return;
    if(held.isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('No held sales.')));return;}
    final id=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Held Sales'),content:SizedBox(width:600,height:400,child:ListView.separated(itemCount:held.length,separatorBuilder:(_,__)=>const Divider(height:1),itemBuilder:(context,i){final h=held[i];return ListTile(title:Text('${h['customer_name']??'Walk-in customer'}'),subtitle:Text('${h['line_count']} line(s) • ${(h['created_at']??'').toString().replaceFirst('T',' ')}'),trailing:FilledButton(onPressed:()=>Navigator.pop(ctx,h['id'].toString()),child:const Text('Resume')));})),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
    if(id==null)return; final detail=await AppDatabase.instance.heldSaleDetail(id); if(!mounted)return;
    final h=Map<String,Object?>.from(detail['header'] as Map); final items=List<Map<String,Object?>>.from(detail['items'] as List);
    setState((){cart.clear();for(final x in items){cart[x['product_id'].toString()]={...x,'id':x['product_id'],'qty':x['qty'],'price':x['price'],'line_discount':x['line_discount']??0};}customerId=(h['customer_id']??'').toString();discountCtl.text='${h['bill_discount']??0}';deliveryCtl.text='${h['delivery_charge']??0}';otherCtl.text='${h['other_charge']??0}';notesCtl.text='${h['notes']??''}';});
    await AppDatabase.instance.deleteHeldSale(id);
    // Preserve the exact negotiated/manual pricing that was parked with the sale.
    // Customer-group pricing is only re-evaluated when the cashier actively changes
    // the customer or adds a new product after resuming.
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Held sale resumed')));
  }

  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    try {
      final currentSubtotal = subtotal;
      final currentItemDiscount = itemDiscount;
      final currentDiscount = _number(discountCtl);
      final currentTax = taxTotal;
      final currentDelivery = _number(deliveryCtl);
      final currentOther = _number(otherCtl);
      final currentTotal = total;
      final splitApplied = splitTenders.fold<double>(0,(a,r)=>a+(r['amount'] as num? ?? 0).toDouble());
      final requestedPaid = splitTenders.isNotEmpty ? splitApplied : (paidCtl.text.trim().isEmpty ? currentTotal : _number(paidCtl));
      final safePaid = requestedPaid.clamp(0, currentTotal).toDouble();
      final currentBalance = (currentTotal - safePaid).clamp(0, double.infinity).toDouble();
      final currentMethod = splitTenders.length>1 ? 'Split' : paymentMethod;
      final tenderSnapshot = splitTenders.map((x)=>Map<String,Object?>.from(x)).toList();
      final changeDue = tenderSnapshot.fold<double>(0,(a,r)=>a+(r['change_due'] as num? ?? 0).toDouble());
      final itemSnapshot = cart.values.map((x) => {
        ...x,
        'tax_amount': _lineTax(x),
        'tax_inclusive': x['tax_inclusive'] ?? 0,
        'line_total': _lineTotal(x),
      }).toList();
      final customer = customerId.isEmpty ? null : await AppDatabase.instance.customerById(customerId);
      final customerName = (customer?['name'] ?? 'Walk-in customer').toString();

      final no = await AppDatabase.instance.postSale(
        items: itemSnapshot,
        customerId: customerId.isEmpty ? null : customerId,
        discount: currentDiscount,
        deliveryCharge: currentDelivery,
        otherCharge: currentOther,
        paid: safePaid,
        paymentMethod: currentMethod,
        tenders: tenderSnapshot,
        notes: notesCtl.text.trim(),
      );
      if (!mounted) return;

      setState(() {
        cart.clear();
        query = '';
      _productsFuture = AppDatabase.instance.products(activeOnly: true);
        category = 'All';
        customerId = '';
        paymentMethod = widget.defaultPaymentMethod;
        searchCtl.clear();
        discountCtl.text = '0';
        deliveryCtl.text = '0';
        otherCtl.text = '0';
        paidCtl.clear();
        notesCtl.clear();
        splitTenders.clear();
      });

      final printSettings = await AppDatabase.instance.settings();
      final saleIdRows = await AppDatabase.instance.db.query(
        'sales',
        columns: const ['id'],
        where: 'no=?',
        whereArgs: [no],
        limit: 1,
      );
      final saleDocumentId = saleIdRows.isEmpty ? no : saleIdRows.first['id'].toString();
      final configuredAction = PrintService.actionFromSetting(printSettings['sales_print_action']);
      final configuredPrinter = printSettings['sales_printer'] ?? '';

      Future<void> outputSale(ReliqPrintAction action) => PrintService.printSaleReceipt(
        saleNo: no,
        items: itemSnapshot,
        subtotal: currentSubtotal,
        itemDiscount: currentItemDiscount,
        discount: currentDiscount,
        tax: currentTax,
        delivery: currentDelivery,
        other: currentOther,
        total: currentTotal,
        paid: safePaid,
        balance: currentBalance,
        paymentMethod: currentMethod,
        customerName: customerName,
        action: action,
        printerName: configuredPrinter,
      );

      String? automaticOutputMessage;
      if (configuredAction != ReliqPrintAction.none) {
        try {
          await outputSale(configuredAction);
          automaticOutputMessage = configuredAction == ReliqPrintAction.direct
              ? 'The invoice was sent to the configured printer automatically.'
              : 'The invoice preview was opened automatically.';
        } catch (e) {
          automaticOutputMessage = 'The sale was saved, but automatic document output failed: ${e.toString().replaceFirst('Exception: ', '')}';
        }
      }

      final customerPhone = (customer?['whatsapp'] ?? customer?['phone'] ?? '').toString().trim();
      final customerEmail = (customer?['email'] ?? '').toString().trim();
      final canMessage = customerPhone.isNotEmpty;
      final canEmail = customerEmail.isNotEmpty;

      Future<File> prepareSharePdf() => PrintService.prepareSaleReceiptPdf(
        saleNo: no,
        items: itemSnapshot,
        subtotal: currentSubtotal,
        itemDiscount: currentItemDiscount,
        discount: currentDiscount,
        tax: currentTax,
        delivery: currentDelivery,
        other: currentOther,
        total: currentTotal,
        paid: safePaid,
        balance: currentBalance,
        paymentMethod: currentMethod,
        customerName: customerName,
      );

      final action = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline, color: V3Style.success, size: 34),
          title: Text('Sale $no Completed'),
          content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(automaticOutputMessage ?? 'The sale is saved. Choose what you want to do next.'),
            const SizedBox(height: 14),
            _dialogMoney('Total', currentTotal, strong: true),
            _dialogMoney('Paid', safePaid),
            if (changeDue > 0) _dialogMoney('Change due', changeDue),
            if (currentBalance > 0) _dialogMoney('Balance due', currentBalance),
            if (!canMessage || !canEmail) ...[
              const SizedBox(height: 10),
              Text(
                customer == null
                    ? 'Select a customer with saved contact details to share the invoice.'
                    : [
                        if (!canMessage) 'No WhatsApp/phone number',
                        if (!canEmail) 'No email address',
                      ].join(' • '),
                style: TextStyle(fontSize: 11.5, color: Theme.of(dialogContext).colorScheme.onSurfaceVariant),
              ),
            ],
          ])),
          actions: [
            // Do not offer the same print action again when Settings already
            // performed it automatically.
            if (configuredAction == ReliqPrintAction.none) ...[
              TextButton.icon(onPressed: () => Navigator.pop(dialogContext, 'preview'), icon: const Icon(Icons.preview_outlined, size: 17), label: const Text('Preview')),
              OutlinedButton.icon(onPressed: () => Navigator.pop(dialogContext, 'direct'), icon: const Icon(Icons.print_outlined, size: 17), label: const Text('Print Directly')),
            ],
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(dialogContext, 'save'),
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('Save PDF'),
            ),
            OutlinedButton.icon(
              onPressed: canMessage ? () => Navigator.pop(dialogContext, 'message') : null,
              icon: const Icon(Icons.chat_outlined, size: 17),
              label: const Text('WhatsApp'),
            ),
            OutlinedButton.icon(
              onPressed: canEmail ? () => Navigator.pop(dialogContext, 'email') : null,
              icon: const Icon(Icons.email_outlined, size: 17),
              label: const Text('Email PDF'),
            ),
            FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, 'new'), icon: const Icon(Icons.add_shopping_cart_outlined, size: 17), label: const Text('New Sale')),
          ],
        ),
      );

      if (!mounted) return;
      if (action == 'preview' || action == 'direct') {
        try {
          final mode = action == 'direct' ? ReliqPrintAction.direct : ReliqPrintAction.preview;
          await outputSale(mode);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mode == ReliqPrintAction.direct ? 'Invoice sent to printer.' : 'Invoice preview opened.')));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
        }
      } else if (action == 'save') {
        try {
          final attachment = await prepareSharePdf();
          final savedPath = await DocumentShareService.savePdfAs(
            attachment,
            suggestedFileName: 'Invoice_$no.pdf',
          );
          if (savedPath != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invoice PDF saved to $savedPath')));
          }
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save invoice PDF: ${e.toString().replaceFirst('Exception: ', '')}')));
        }
      } else if (action == 'message') {
        try {
          final message = WhatsAppService.invoiceMessage(printSettings, {
            'customer_name': customerName,
            'no': no,
            'total': currentTotal,
          });
          final shareResult = await WhatsAppService.shareDocument(
            settings: printSettings,
            phone: customerPhone,
            message: message,
            prepareAttachment: prepareSharePdf,
          );
          if (customer != null) {
            await AppDatabase.instance.logCommunication(
              partyType: 'Customer',
              partyId: customer['id'].toString(),
              channel: 'WhatsApp',
              documentType: 'Invoice',
              documentId: saleDocumentId,
              action: shareResult.auditAction,
            );
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(shareResult.userMessage('Invoice')),
            ));
          }
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not prepare WhatsApp invoice: ${e.toString().replaceFirst('Exception: ', '')}')));
        }
      } else if (action == 'email') {
        try {
          final attachment = await prepareSharePdf();
          final businessName = (printSettings['business_name'] ?? 'RELIQ Solutions').trim();
          final currency = (printSettings['currency'] ?? 'KWD').trim();
          final decimals = int.tryParse(printSettings['currency_decimals'] ?? '3') ?? 3;
          await DocumentShareService.openEmailDraftWithAttachment(
            recipient: customerEmail,
            subject: 'Invoice $no - $businessName',
            body: 'Hello $customerName,\n\nPlease find invoice $no attached.\nTotal: $currency ${currentTotal.toStringAsFixed(decimals)}\n\nThank you,\n$businessName',
            attachment: attachment,
          );
          if (customer != null) {
            await AppDatabase.instance.logCommunication(
              partyType: 'Customer',
              partyId: customer['id'].toString(),
              channel: 'Email',
              documentType: 'Invoice',
              documentId: saleDocumentId,
              action: 'PDF prepared / opened',
            );
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Email draft opened and the invoice PDF is ready in Finder/Explorer. Attach it, then send.'),
            ));
          }
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not prepare invoice email: ${e.toString().replaceFirst('Exception: ', '')}')));
        }
      }
      if (mounted) searchFocus.requestFocus();

    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Widget _dialogMoney(String label, double value, {bool strong = false}) => Row(children: [
    Expanded(child: Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w700 : FontWeight.w400))),
    Text(value.toStringAsFixed(3), style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
  ]);

  void _focusSearch() {
    searchFocus.requestFocus();
    searchCtl.selection = TextSelection(baseOffset: 0, extentOffset: searchCtl.text.length);
  }

  Future<void> _newSale() async {
    if (cart.isNotEmpty) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Start a new sale?'),
          content: const Text('The current unsaved sale will be cleared.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep current sale')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start new sale')),
          ],
        ),
      );
      if (clear != true || !mounted) return;
    }
    setState(() {
      cart.clear();
      customerId = '';
      discountCtl.text = '0';
      deliveryCtl.text = '0';
      otherCtl.text = '0';
      paidCtl.clear();
      notesCtl.clear();
      splitTenders.clear();
      query = '';
      _productsFuture = AppDatabase.instance.products(activeOnly: true);
      searchCtl.clear();
    });
    _focusSearch();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
    const SingleActivator(LogicalKeyboardKey.f2): _focusSearch,
    const SingleActivator(LogicalKeyboardKey.f4): () => customerFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.f5): () => setState(() { _productsFuture = AppDatabase.instance.products(search: query, activeOnly: true); _customersFuture = AppDatabase.instance.customers(activeOnly: true, limit: 10000); }),
    const SingleActivator(LogicalKeyboardKey.f6): () => discountFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.f7): () => deliveryFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.f8): () { if (cart.isNotEmpty) _holdCurrentSale(); },
    const SingleActivator(LogicalKeyboardKey.f9): () => paidFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.f10): () { if (cart.isNotEmpty) _checkout(); },
    const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newSale,
    const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _newSale,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): () { if (cart.isNotEmpty) _checkout(); },
    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () { if (cart.isNotEmpty) _checkout(); },
  };

  Widget _shortcutHints() => ShortcutHelperBar(items: const [
    ('F2', 'Product'),
    ('F4', 'Customer'),
    ('F6', 'Discount'),
    ('F7', 'Charges'),
    ('F8', 'Hold'),
    ('F9', 'Payment'),
    ('F10', 'Complete'),
    ('Ctrl/Cmd+F', 'Universal Lookup'),
  ]);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < 1050;
    return CallbackShortcuts(
      bindings: _shortcutBindings(),
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: EdgeInsets.all(widget.touchMode ? 20 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Sales / POS', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            const SizedBox(height: 4),
            Text(tileView ? 'Touch-friendly product tiles and a roomy checkout panel.' : 'Keyboard-first entry with a wide sale-lines workspace.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.grid_view_outlined, size: 17), label: Text('Tiles')),
              ButtonSegment(value: false, icon: Icon(Icons.keyboard_outlined, size: 17), label: Text('Normal')),
            ],
            selected: {tileView},
            onSelectionChanged: (v) => setState(() {
              tileView = v.first;
              query = '';
      _productsFuture = AppDatabase.instance.products(activeOnly: true);
              searchCtl.clear();
              searchFocus.requestFocus();
            }),
            showSelectedIcon: false,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: cart.isEmpty ? null : () => setState(cart.clear),
            style: OutlinedButton.styleFrom(foregroundColor: V3Style.danger, backgroundColor: V3Style.danger.withValues(alpha: .06), side: BorderSide(color: V3Style.danger.withValues(alpha: .22))),
            icon: const Icon(Icons.delete_sweep_outlined, size: 17),
            label: const Text('Clear'),
          ),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: stacked
              ? _stackedLayout()
              : tileView
                  ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(flex: 5, child: _tileWorkspace()),
                      const SizedBox(width: 14),
                      SizedBox(width: math.min(widget.touchMode ? 600.0 : 560.0, width * .42), child: _checkoutPanel(showCartLines: true)),
                    ])
                  : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(flex: 7, child: _normalWorkspace()),
                      const SizedBox(width: 14),
                      SizedBox(width: 430, child: _checkoutPanel(showCartLines: false)),
                    ]),
        ),
        if (widget.showShortcutHelpers) _shortcutHints(),
      ]),
        ),
      ),
    );
  }

  Widget _stackedLayout() => ListView(children: [
    SizedBox(height: tileView ? 460 : 520, child: tileView ? _tileWorkspace() : _normalWorkspace()),
    const SizedBox(height: 12),
    SizedBox(height: tileView ? 620 : 500, child: _checkoutPanel(showCartLines: tileView)),
  ]);

  void _onProductSearchChanged(String value) {
    setState(() => query = value);
    _productSearchDebounce?.cancel();
    _productSearchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      setState(() => _productsFuture = AppDatabase.instance.products(search: query, activeOnly: true));
    });
  }

  Widget _searchField() => TextField(
    controller: searchCtl,
    focusNode: searchFocus,
    autofocus: true,
    style: TextStyle(fontSize: widget.touchMode ? 17 : 14),
    onChanged: _onProductSearchChanged,
    onSubmitted: _submitSearch,
    decoration: InputDecoration(
      prefixIcon: const Icon(Icons.search),
      hintText: tileView ? 'Scan barcode / type SKU / product name...' : 'Scan or type product / SKU / barcode, then press Enter...',
      suffixIcon: query.isEmpty ? null : IconButton(onPressed: () => setState(() { searchCtl.clear(); query = ''; _productsFuture = AppDatabase.instance.products(activeOnly: true); }), icon: const Icon(Icons.close)),
    ),
  );

  Widget _tileWorkspace() => Card(child: Padding(
    padding: EdgeInsets.all(widget.touchMode ? 18 : 16),
    child: Column(children: [
      _searchField(),
      const SizedBox(height: 12),
      Expanded(child: FutureBuilder<List<Map<String, Object?>>>(
        future: _productsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Products could not load: ${snapshot.error}'));
          if (!snapshot.hasData) return const ReliqLoadingState(message: 'Loading sale products…', detail: 'RELIQ is still working.', compact: true);
          final products = snapshot.data!.where((p) => ((p['sellable'] as num?) ?? 1).toInt() == 1).toList();
          final categories = <String>{'All'};
          for (final p in products) {
            final c = '${p['category'] ?? ''}'.trim();
            if (c.isNotEmpty) categories.add(c);
          }
          if (!categories.contains(category)) category = 'All';
          final visible = category == 'All' ? products : products.where((p) => '${p['category'] ?? ''}' == category).toList();
          if (products.isEmpty) return const Center(child: Text('No active sales products found.'));
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: widget.touchMode ? 44 : 38, child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final c in categories)
                Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: ChoiceChip(
                    label: Text(c, style: TextStyle(fontWeight: FontWeight.w700, color: category == c ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface)),
                    selected: category == c,
                    selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .16 : .10),
                    backgroundColor: V3Style.tableHeader(context),
                    side: BorderSide(color: category == c ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor),
                    onSelected: (_) => setState(() => category = c),
                  ),
                ),
            ])),
            const SizedBox(height: 10),
            Expanded(child: _tileCatalog(visible)),
          ]);
        },
      )),
    ]),
  ));

  Widget _tileCatalog(List<Map<String, Object?>> products) => GridView.builder(
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      // Product tile footprint intentionally stays identical in Touch mode.
      // Touch mode still enlarges controls/buttons elsewhere in POS.
      maxCrossAxisExtent: 220,
      childAspectRatio: 1.55,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
    ),
    itemCount: products.length,
    itemBuilder: (context, i) {
      final p = products[i];
      final stock = _d(p['stock']);
      final canAdd = _canAddProduct(p);
      return Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .76),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _tryAddProduct(p),
          child: Container(
            padding: EdgeInsets.all(widget.touchMode ? 15 : 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: canAdd ? Theme.of(context).dividerColor : Theme.of(context).colorScheme.error.withValues(alpha: .65), width: canAdd ? 1 : 1.5)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: widget.touchMode ? 12.5 : 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${p['category'] ?? ''} • ${p['product_type'] ?? 'Stocked'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: widget.touchMode ? 9 : 10, color: const Color(0xFF8190A0))),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: Text(_d(p['price']).toStringAsFixed(3), style: TextStyle(fontSize: widget.touchMode ? 15 : 16, fontWeight: FontWeight.w800, color: V3Style.blueDark))),
                Text((p['product_type'] == 'Recipe' || p['product_type'] == 'Combo') ? '${p['product_type']}' : (stock > 0 ? 'Stock ${stock.toStringAsFixed(1)}' : 'OUT'), style: TextStyle(fontSize: widget.touchMode ? 9 : 10, fontWeight: FontWeight.w700, color: canAdd ? const Color(0xFF5E7183) : Theme.of(context).colorScheme.error)),
              ]),
            ]),
          ),
        ),
      );
    },
  );

  Widget _normalWorkspace() => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _searchField(),
      if (query.trim().isNotEmpty) ...[
        const SizedBox(height: 8),
        SizedBox(height: 190, child: _normalSuggestions()),
      ] else ...[
        const SizedBox(height: 8),
        const Row(children: [Icon(Icons.keyboard_alt_outlined, size: 17, color: V3Style.muted), SizedBox(width: 7), Text('Keep typing or scanning. Press Enter to add the best match.', style: TextStyle(color: V3Style.muted, fontSize: 12))]),
      ],
      const SizedBox(height: 12),
      Row(children: [
        const Text('Sale Lines', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: const Color(0xFFEAF1FF), borderRadius: BorderRadius.circular(99)), child: Text('${cart.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: V3Style.blueDark))),
        const Spacer(),
        Text('Qty, selling price, discount and tax can be edited inline.', style: TextStyle(fontSize: 11, color: V3Style.mutedFor(context))),
      ]),
      const SizedBox(height: 8),
      Expanded(child: _wideCart()),
    ]),
  ));

  Widget _normalSuggestions() => FutureBuilder<List<Map<String, Object?>>>(
    future: _productsFuture,
    builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('Products could not load: ${snapshot.error}'));
      if (!snapshot.hasData) return const ReliqLoadingState(message: 'Searching products…', compact: true);
      final rows = snapshot.data!.where((p) => ((p['sellable'] as num?) ?? 1).toInt() == 1).toList();
      final visible = rows.take(6).toList();
      if (visible.isEmpty) return const Center(child: Text('No matching products.'));
      return Container(
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
        child: ListView.separated(
          itemCount: visible.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final p = visible[i];
            final stock = _d(p['stock']);
            final canAdd = _canAddProduct(p);
            return ListTile(
              dense: true,
              title: Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${p['sku'] ?? '—'} • ${p['external_barcode'] ?? p['internal_barcode'] ?? '—'} • ${p['category'] ?? ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${_d(p['price']).toStringAsFixed(3)}  •  ${(p['product_type'] == 'Recipe' || p['product_type'] == 'Combo') ? p['product_type'] : stock.toStringAsFixed(1)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                IconButton(onPressed: () => _tryAddProduct(p), icon: Icon(canAdd ? Icons.add_circle_outline : Icons.error_outline, color: canAdd ? null : Theme.of(context).colorScheme.error)),
              ]),
              onTap: () => _tryAddProduct(p),
            );
          },
        ),
      );
    },
  );

  Widget _wideCart() {
    if (cart.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.shopping_cart_outlined, size: 36, color: V3Style.muted),
          const SizedBox(height: 8),
          const Text('No sale lines yet', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text('Scan a barcode or search above to add the first item.', style: TextStyle(color: V3Style.mutedFor(context))),
        ])),
      );
    }
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: const Row(children: [
            Expanded(flex: 5, child: Text('PRODUCT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 82, child: Text('QTY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 105, child: Text('PRICE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 95, child: Text('DISCOUNT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 84, child: Text('TAX %', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 90, child: Text('TOTAL', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
            SizedBox(width: 42),
          ]),
        ),
        Expanded(child: ListView.separated(
          itemCount: cart.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final e = cart.entries.elementAt(i);
            return _wideCartLine(e.key, e.value, i);
          },
        )),
      ]),
    );
  }

  Widget _wideCartLine(String id, Map<String, Object?> line, int index) {
    final lineTotal = _lineTotal(line);
    return Container(
      color: index.isOdd ? V3Style.rowStripe(context) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(children: [
        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${line['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          Text('${line['sku'] ?? ''} • ${line['unit'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: V3Style.muted)),
          if (line['last_customer_price'] != null || _d(line['group_discount_pct']) > 0)
            Text([
              if (_d(line['group_discount_pct']) > 0) 'Group ${_d(line['group_discount_pct']).toStringAsFixed(1)}%',
              if (line['last_customer_price'] != null) 'Last ${_d(line['last_customer_price']).toStringAsFixed(3)}',
            ].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
        ])),
        SizedBox(width: 82, child: Row(children: [
          _tinyQty(Icons.remove, () => _changeQty(id, -1)),
          Expanded(child: Text(_d(line['qty']).toStringAsFixed(_d(line['qty']) == _d(line['qty']).roundToDouble() ? 0 : 2), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
          _tinyQty(Icons.add, () => _changeQty(id, 1)),
        ])),
        SizedBox(width: 105, child: _lineField('Price', _d(line['price']), (v) => setState(() => line['price'] = v), showLabel: false, fieldKey: '$id-price')),
        const SizedBox(width: 5),
        SizedBox(width: 90, child: _lineField('Disc.', _d(line['line_discount']), (v) => setState(() => line['line_discount'] = v), showLabel: false, fieldKey: '$id-discount')),
        const SizedBox(width: 5),
        SizedBox(width: 78, child: _lineField('Tax %', _d(line['tax_rate']), (v) => setState(() => line['tax_rate'] = v), showLabel: false, fieldKey: '$id-tax')),
        SizedBox(width: 90, child: Text(lineTotal.toStringAsFixed(3), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800))),
        SizedBox(width: 42, child: IconButton(tooltip: 'Remove', visualDensity: VisualDensity.compact, onPressed: () => setState(() => cart.remove(id)), style: IconButton.styleFrom(foregroundColor: V3Style.danger), icon: const Icon(Icons.delete_outline, size: 18))),
      ]),
    );
  }

  Widget _checkoutPanel({required bool showCartLines}) => Card(child: Padding(
    padding: EdgeInsets.all(widget.touchMode ? 18 : 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(showCartLines ? 'Current Sale' : 'Checkout', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const Spacer(),
        Text('${cart.length} lines', style: const TextStyle(fontSize: 11, color: V3Style.blueDark, fontWeight: FontWeight.w700)),
      ]),
      if (showCartLines) ...[
        const SizedBox(height: 10),
        Expanded(child: cart.isEmpty
            ? Center(child: Text('Cart is empty\nScan or select a product to begin.', textAlign: TextAlign.center, style: TextStyle(color: V3Style.mutedFor(context))))
            : ListView(children: [for (final e in cart.entries) _compactCartLine(e.key, e.value)])),
        const Divider(height: 18),
      ] else
        const SizedBox(height: 12),
      if (showCartLines)
        SingleChildScrollView(child: _checkoutDetails())
      else
        Expanded(child: SingleChildScrollView(child: _checkoutDetails())),
    ]),
  ));

  Widget _checkoutDetails() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _customerSection(),
    const SizedBox(height: 10),
    Wrap(spacing: 7, runSpacing: 7, children: [
      SizedBox(width: 124, child: _moneyField(discountCtl, 'Bill discount', focusNode: discountFocus)),
      SizedBox(width: 124, child: _moneyField(deliveryCtl, 'Delivery', focusNode: deliveryFocus)),
      SizedBox(width: 124, child: _moneyField(otherCtl, 'Other')),
    ]),
    const SizedBox(height: 10),
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(10), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(children: [
        _totalRow('Subtotal', subtotal, false),
        if (itemDiscount > 0) _totalRow('Item discounts', -itemDiscount, false),
        if (taxTotal > 0) _totalRow('Tax', taxTotal, false),
        if (_number(discountCtl) > 0) _totalRow('Bill discount', -_number(discountCtl), false),
        if (_number(deliveryCtl) > 0) _totalRow('Delivery', _number(deliveryCtl), false),
        if (_number(otherCtl) > 0) _totalRow('Other', _number(otherCtl), false),
        const Divider(),
        _totalRow('Total', total, true),
      ]),
    ),
    const SizedBox(height: 10),
    Wrap(spacing:8,runSpacing:8,children: [
      SizedBox(width:170,child: TextField(controller: paidCtl, focusNode: paidFocus, onChanged: (_) => setState(() {splitTenders.clear();}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Paid (blank = full)'))),
      SizedBox(width:150,child: DropdownButtonFormField<String>(isExpanded:true,value: ['Cash','Card','Bank','Cheque','Other'].contains(paymentMethod)?paymentMethod:'Cash',items:['Cash','Card','Bank','Cheque','Other'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState((){paymentMethod=v??'Cash';splitTenders.clear();}),decoration:const InputDecoration(labelText:'Method'))),
      OutlinedButton.icon(onPressed:cart.isEmpty?null:_configureSplitTender,icon:const Icon(Icons.call_split_outlined),label:Text(splitTenders.isEmpty?'Split tender':'${splitTenders.length} tenders')),
    ]),
    const SizedBox(height: 8),
    TextField(controller: notesCtl, minLines: 1, maxLines: 2, decoration: const InputDecoration(labelText: 'Sale note / reference')),
    const SizedBox(height: 10),
    Row(children:[
      OutlinedButton.icon(onPressed:_resumeHeldSale,icon:const Icon(Icons.restore_outlined),label:const Text('Held')),
      const SizedBox(width:7),
      OutlinedButton.icon(onPressed:cart.isEmpty?null:_holdCurrentSale,icon:const Icon(Icons.pause_circle_outline),label:const Text('Hold')),
      const SizedBox(width:7),
      Expanded(child:SizedBox(height:widget.touchMode?56:48,child:FilledButton.icon(onPressed:cart.isEmpty?null:_checkout,style:FilledButton.styleFrom(backgroundColor:V3Style.success),icon:const Icon(Icons.check_circle_outline),label:Text('Complete Sale  •  ${total.toStringAsFixed(3)}')))),
    ]),
  ]);

  Widget _customerSection() => FutureBuilder<List<Map<String, Object?>>>(
    future: _customersFuture,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const ReliqLoadingState(message: 'Loading customers…', compact: true);
      final customers = snapshot.data!;
      Map<String, Object?>? selected;
      if (customerId.isNotEmpty) {
        for (final c in customers) {
          if (c['id'] == customerId) {
            selected = c;
            break;
          }
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: SearchableMapSelect(
            options: customers,
            value: customerId.isEmpty ? null : customerId,
            focusNode: customerFocus,
            labelText: 'Customer',
            hintText: 'Type name, phone or email...',
            allowClear: true,
            display: (c) => '${c['name']}',
            subtitle: (c) {
              final phone = '${c['phone'] ?? ''}'.trim();
              final email = '${c['email'] ?? ''}'.trim();
              final balance = _d(c['balance']);
              return [
                if (phone.isNotEmpty) phone,
                if (email.isNotEmpty) email,
                if (balance > 0) 'Due ${balance.toStringAsFixed(3)}',
              ].join(' • ');
            },
            onChanged: (v) async {
              final next = v ?? '';
              setState(() => customerId = next);
              if (next.isNotEmpty) await _applyCustomerPricing(next);
            },
          )),
          const SizedBox(width: 7),
          SizedBox(height: 47, child: OutlinedButton.icon(onPressed: _quickAddCustomer, style: OutlinedButton.styleFrom(foregroundColor: V3Style.info, backgroundColor: V3Style.info.withValues(alpha: .06), side: BorderSide(color: V3Style.info.withValues(alpha: .22))), icon: const Icon(Icons.person_add_alt_1, size: 17), label: const Text('Add'))),
        ]),
        if (selected != null) ...[
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(9), border: Border.all(color: Theme.of(context).dividerColor)),
            child: Row(children: [
              const Icon(Icons.person_outline, size: 18, color: V3Style.blueDark),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${selected['phone'] ?? ''}${('${selected['email'] ?? ''}').trim().isNotEmpty ? ' • ${selected['email']}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                Text('Outstanding ${_d(selected['balance']).toStringAsFixed(3)}${((selected['credit_allowed'] as num?) ?? 0).toInt() == 1 ? ' • Credit enabled' : ''}${selected['group_id'] != null ? ' • Group pricing active' : ''}', style: const TextStyle(fontSize: 10, color: V3Style.muted)),
              ])),
            ]),
          ),
        ],
      ]);
    },
  );

  Widget _compactCartLine(String id, Map<String, Object?> line) {
    final lineTotal = _lineTotal(line);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${line['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            Text('${line['sku'] ?? ''} • ${line['unit'] ?? ''}', style: const TextStyle(fontSize: 10, color: V3Style.muted)),
            if (line['last_customer_price'] != null || _d(line['group_discount_pct']) > 0)
              Text([
                if (_d(line['group_discount_pct']) > 0) 'Group ${_d(line['group_discount_pct']).toStringAsFixed(1)}%',
                if (line['last_customer_price'] != null) 'Last ${_d(line['last_customer_price']).toStringAsFixed(3)}',
              ].join(' • '), style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
          ])),
          Text(lineTotal.toStringAsFixed(3), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Remove line', visualDensity: VisualDensity.compact, onPressed: () => setState(() => cart.remove(id)), icon: const Icon(Icons.delete_outline, size: 18)),
        ]),
        const SizedBox(height: 5),
        Wrap(spacing: 7, runSpacing: 7, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Container(
            height: 42,
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _qtyButton(Icons.remove, () => _changeQty(id, -1)),
              SizedBox(width: 38, child: Text(_d(line['qty']).toStringAsFixed(_d(line['qty']) == _d(line['qty']).roundToDouble() ? 0 : 2), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
              _qtyButton(Icons.add, () => _changeQty(id, 1)),
            ]),
          ),
          SizedBox(width: 118, child: _lineField('Price', _d(line['price']), (v) => setState(() => line['price'] = v), fieldKey: '$id-price-compact')),
          SizedBox(width: 110, child: _lineField('Discount', _d(line['line_discount']), (v) => setState(() => line['line_discount'] = v), fieldKey: '$id-discount-compact')),
          SizedBox(width: 94, child: _lineField('Tax %', _d(line['tax_rate']), (v) => setState(() => line['tax_rate'] = v), fieldKey: '$id-tax-compact')),
        ]),
      ]),
    );
  }

  Widget _lineField(String label, double value, ValueChanged<double> onChanged, {bool showLabel = true, String? fieldKey}) => TextFormField(
    key: fieldKey == null ? null : ValueKey(fieldKey),
    initialValue: value.toStringAsFixed(value == value.roundToDouble() ? 0 : 3),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: const TextStyle(fontSize: 12),
    decoration: InputDecoration(
      labelText: showLabel ? label : null,
      hintText: showLabel ? null : label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
    ),
    onChanged: (s) => onChanged(double.tryParse(s) ?? 0),
  );

  Widget _qtyButton(IconData icon, VoidCallback onTap) => SizedBox(width: widget.touchMode ? 38 : 32, height: widget.touchMode ? 38 : 38, child: IconButton(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact, onPressed: onTap, icon: Icon(icon, size: 17)));
  Widget _tinyQty(IconData icon, VoidCallback onTap) => SizedBox(width: 25, height: 30, child: IconButton(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact, onPressed: onTap, icon: Icon(icon, size: 14)));
  Widget _moneyField(TextEditingController ctl, String label, {FocusNode? focusNode}) => TextField(controller: ctl, focusNode: focusNode, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: label, isDense: true));
  Widget _totalRow(String label, double value, bool strong) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
    Expanded(child: Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w500))),
    Text(value.toStringAsFixed(3), style: TextStyle(fontSize: strong ? 20 : 13, fontWeight: strong ? FontWeight.w800 : FontWeight.w600)),
  ]));
}
