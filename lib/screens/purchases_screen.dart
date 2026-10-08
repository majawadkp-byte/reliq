import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/print_service.dart';
import '../ui/v3_style.dart';
import '../ui/product_search_field.dart';
import '../ui/shortcut_helper_bar.dart';
import '../ui/searchable_map_select.dart';

double? _purchaseUnitMultiplier(String usageUnit, String stockUnit) {
  final from = usageUnit.trim().toLowerCase();
  final to = stockUnit.trim().toLowerCase();
  if (from == to) return 1;
  const factors = <String, double>{
    'g>kg': 0.001,
    'kg>g': 1000,
    'ml>l': 0.001,
    'l>ml': 1000,
  };
  return factors['$from>$to'];
}

class PurchasesScreen extends StatefulWidget {
  final bool showShortcutHelpers;
  const PurchasesScreen({super.key, this.showShortcutHelpers = true});

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  final searchCtl = TextEditingController();
  final documentCtl = TextEditingController();
  final freightCtl = TextEditingController(text: '0');
  final otherCtl = TextEditingController(text: '0');
  final paidCtl = TextEditingController();
  final notesCtl = TextEditingController();
  final items = <Map<String, Object?>>[];
  final searchFocus = FocusNode();
  final supplierFocus = FocusNode();
  final freightFocus = FocusNode();
  final paidFocus = FocusNode();

  String supplierId = '';
  String paymentMethod = 'Cash';
  String query = '';
  int supplierRefresh = 0;

  double _number(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0;
  double get subtotal => items.fold(
      0.0,
      (sum, x) =>
          sum +
          (x['qty'] as num).toDouble() * (x['unit_cost'] as num).toDouble());
  double get discountTotal => items.fold(
      0.0, (sum, x) => sum + (x['discount'] as num? ?? 0).toDouble());
  double _lineTax(Map<String, Object?> x) {
    final taxable =
        ((x['qty'] as num).toDouble() * (x['unit_cost'] as num).toDouble() -
                (x['discount'] as num? ?? 0).toDouble())
            .clamp(0, double.infinity)
            .toDouble();
    final rate =
        (x['tax_rate'] as num? ?? 0).toDouble().clamp(0, 100).toDouble();
    if (rate <= 0) return 0;
    final inclusive = ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1;
    return inclusive ? taxable * rate / (100 + rate) : taxable * rate / 100;
  }

  double _lineTotal(Map<String, Object?> x) {
    final net =
        ((x['qty'] as num).toDouble() * (x['unit_cost'] as num).toDouble() -
                (x['discount'] as num? ?? 0).toDouble())
            .clamp(0, double.infinity)
            .toDouble();
    return ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1
        ? net
        : net + _lineTax(x);
  }

  double get taxTotal => items.fold(0.0, (sum, x) => sum + _lineTax(x));
  double get total => (items.fold<double>(0, (sum, x) => sum + _lineTotal(x)) +
          _number(freightCtl) +
          _number(otherCtl))
      .clamp(0, double.infinity)
      .toDouble();
  double get paidPreview => paidCtl.text.trim().isEmpty
      ? total
      : _number(paidCtl).clamp(0, total).toDouble();
  double get balancePreview =>
      (total - paidPreview).clamp(0, double.infinity).toDouble();

  @override
  void dispose() {
    for (final c in [
      searchCtl,
      documentCtl,
      freightCtl,
      otherCtl,
      paidCtl,
      notesCtl
    ]) {
      c.dispose();
    }
    searchFocus.dispose();
    supplierFocus.dispose();
    freightFocus.dispose();
    paidFocus.dispose();
    super.dispose();
  }

  Future<void> _selectProduct(Map<String, Object?> product,
      {int? editIndex}) async {
    final existing = editIndex == null ? null : items[editIndex];
    final existingCost = existing?['unit_cost'] as num?;
    final productCost = product['cost'] as num?;
    final draft = <String, Object?>{
      'id': product['id'],
      'name': product['name'],
      'sku': product['sku'],
      'barcode':
          product['external_barcode'] ?? product['internal_barcode'] ?? '',
      'unit': product['unit'] ?? 'pcs',
      'product_type': product['product_type'] ?? 'Stocked',
      'track_batch': product['track_batch'] ?? 0,
      'track_expiry': product['track_expiry'] ?? 0,
      'qty': (existing?['qty'] as num? ?? 1).toDouble(),
      'unit_cost': (existingCost ?? productCost ?? 0).toDouble(),
      'discount': (existing?['discount'] as num? ?? 0).toDouble(),
      'tax_rate': ((existing?['tax_rate'] as num?) ??
              (product['tax_rate'] as num?) ??
              0)
          .toDouble(),
      'tax_inclusive': existing?['tax_inclusive'] ??
          product['tax_profile_inclusive'] ??
          product['tax_inclusive'] ??
          0,
      'batch_no': existing?['batch_no'] ?? '',
      'expiry_date': existing?['expiry_date'],
    };
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => _PurchaseLineDialog(product: product, draft: draft),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (editIndex != null) {
        items[editIndex] = result;
      } else {
        final existingIndex = items.indexWhere((x) => x['id'] == result['id']);
        if (existingIndex >= 0) {
          items[existingIndex] = result;
        } else {
          items.add(result);
        }
      }
      searchCtl.clear();
      query = '';
    });
  }

  Future<void> _submitSearch(String value) async {
    final q = value.trim();
    if (q.isEmpty) return;
    final rows =
        (await AppDatabase.instance.products(search: q, activeOnly: true))
            .where((p) => ((p['purchasable'] as num?) ?? 1).toInt() == 1)
            .toList();
    if (!mounted) return;
    Map<String, Object?>? exact;
    for (final p in rows) {
      if ((p['sku'] ?? '').toString().toLowerCase() == q.toLowerCase() ||
          (p['external_barcode'] ?? '').toString() == q ||
          (p['internal_barcode'] ?? '').toString() == q) {
        exact = p;
        break;
      }
    }
    if (exact != null) {
      await _selectProduct(exact);
    } else if (rows.length == 1) {
      await _selectProduct(rows.first);
    } else if (rows.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Product not found.')));
    }
  }

  Future<void> _editLine(int index) async {
    final line = items[index];
    final rows = await AppDatabase.instance.products(
        search: (line['sku'] ?? line['name'] ?? '').toString(),
        activeOnly: false);
    if (!mounted) return;
    Map<String, Object?>? product;
    for (final p in rows) {
      if (p['id'] == line['id']) {
        product = p;
        break;
      }
    }
    if (product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This product could not be reloaded.')));
      return;
    }
    await _selectProduct(product, editIndex: index);
  }

  Future<void> _addSupplier() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final terms = TextEditingController(text: '0');
    final lead = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Supplier'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Supplier name')),
            const SizedBox(height: 10),
            TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: lead,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Lead time days'))),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: terms,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Payment terms days'))),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add Supplier')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      try {
        final id = await AppDatabase.instance.saveSupplier({
          'name': name.text.trim(),
          'phone': phone.text.trim(),
          'email': '',
          'address': '',
          'lead_days': int.tryParse(lead.text) ?? 0,
          'terms_days': int.tryParse(terms.text) ?? 0,
          'active': 1,
        });
        if (mounted)
          setState(() {
            supplierId = id;
            supplierRefresh++;
          });
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      name.dispose();
      phone.dispose();
      terms.dispose();
      lead.dispose();
    });
  }

  Future<void> savePurchase() async {
    if (supplierId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Select a supplier.')));
      return;
    }
    if (items.isEmpty) return;
    try {
      final paid = paidCtl.text.trim().isEmpty ? total : _number(paidCtl);
      final no = await AppDatabase.instance.postPurchase(
        supplierId: supplierId,
        items: items,
        documentNo: documentCtl.text.trim(),
        freight: _number(freightCtl),
        otherCharges: _number(otherCtl),
        paid: paid,
        paymentMethod: paymentMethod,
        notes: notesCtl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        items.clear();
        supplierId = '';
        searchCtl.clear();
        query = '';
        documentCtl.clear();
        freightCtl.text = '0';
        otherCtl.text = '0';
        paidCtl.clear();
        notesCtl.clear();
        paymentMethod = 'Cash';
      });
      final printSettings = await AppDatabase.instance.settings();
      final printAction = PrintService.actionFromSetting(
          printSettings['purchase_print_action']);
      if (printAction != ReliqPrintAction.none) {
        try {
          final data = await AppDatabase.instance.purchaseDataByNo(no);
          await PrintService.printPurchaseFromData(
            data,
            action: printAction,
            printerName: printSettings['purchase_printer'] ?? '',
          );
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(printAction == ReliqPrintAction.direct
                    ? 'Purchase $no received and sent to printer.'
                    : 'Purchase $no received. Document preview opened.')));
        } catch (e) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                    'Purchase $no received, but document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Purchase $no received and stock updated.')));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  void _focusSearch() {
    searchFocus.requestFocus();
    searchCtl.selection =
        TextSelection(baseOffset: 0, extentOffset: searchCtl.text.length);
  }

  Future<void> _newPurchase() async {
    if (items.isNotEmpty) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Start a new purchase?'),
          content: const Text('The current unsaved purchase will be cleared.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep current purchase')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Start new purchase')),
          ],
        ),
      );
      if (clear != true || !mounted) return;
    }
    setState(() {
      items.clear();
      supplierId = '';
      documentCtl.clear();
      freightCtl.text = '0';
      otherCtl.text = '0';
      paidCtl.clear();
      notesCtl.clear();
      paymentMethod = 'Cash';
      searchCtl.clear();
      query = '';
    });
    _focusSearch();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            supplierFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f3): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f7): () =>
            freightFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f9): () =>
            paidFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f10): () {
          if (items.isNotEmpty) savePurchase();
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _newPurchase,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _newPurchase,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (items.isNotEmpty) savePurchase();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          if (items.isNotEmpty) savePurchase();
        },
      };

  Widget _shortcutHints() => ShortcutHelperBar(items: const [
        ('F2', 'Supplier'),
        ('F3', 'Product'),
        ('F7', 'Freight'),
        ('F9', 'Payment'),
        ('F10', 'Receive'),
        ('Ctrl/Cmd+F', 'Universal Lookup'),
        ('Ctrl/Cmd+S', 'Save'),
      ]);

  @override
  Widget build(BuildContext context) {
    final stacked = MediaQuery.sizeOf(context).width < 1080;
    return CallbackShortcuts(
      bindings: _shortcutBindings(),
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Receive Purchase',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                        'Receive incoming stock with supplier, discounts, payment and batch details.',
                        style: TextStyle(color: V3Style.mutedFor(context))),
                  ])),
              OutlinedButton.icon(
                  onPressed: items.isEmpty ? null : () => setState(items.clear),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: V3Style.danger,
                      backgroundColor: V3Style.danger.withValues(alpha: .06),
                      side: BorderSide(
                          color: V3Style.danger.withValues(alpha: .22))),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                  label: const Text('Clear')),
            ]),
            const SizedBox(height: 14),
            Expanded(
              child: stacked
                  ? Column(children: [
                      Expanded(child: _purchaseLines()),
                      const SizedBox(height: 12),
                      SizedBox(height: 460, child: _summaryPanel())
                    ])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          Expanded(flex: 3, child: _purchaseLines()),
                          const SizedBox(width: 14),
                          SizedBox(width: 400, child: _summaryPanel())
                        ]),
            ),
            if (widget.showShortcutHelpers) _shortcutHints(),
          ]),
        ),
      ),
    );
  }

  Widget _purchaseLines() => Card(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(children: [
            V4ProductSearchField(
              controller: searchCtl,
              focusNode: searchFocus,
              activeOnly: true,
              purchasableOnly: true,
              onSelected: (product) => _selectProduct(product),
              hintText:
                  'Scan barcode / type SKU / product name — first match is selected with Enter',
            ),
            const SizedBox(height: 12),
            Container(
              height: (Theme.of(context).listTileTheme.minTileHeight ?? 38)
                  .clamp(38, 58)
                  .toDouble(),
              color: V3Style.tableHeader(context),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: const Row(children: [
                Expanded(
                    flex: 4,
                    child: Text('PRODUCT',
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(
                    width: 72,
                    child: Text('QTY',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(
                    width: 92,
                    child: Text('UNIT COST',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(
                    width: 88,
                    child: Text('DISCOUNT',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(
                    width: 72,
                    child: Text('TAX',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(
                    width: 100,
                    child: Text('TOTAL',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w800))),
                SizedBox(width: 86),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                          'No purchase items yet.\nSearch or scan a product to add it.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: V3Style.mutedFor(context))))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final x = items[i];
                        final qty = (x['qty'] as num).toDouble();
                        final cost = (x['unit_cost'] as num).toDouble();
                        final discount =
                            (x['discount'] as num? ?? 0).toDouble();
                        final lineTax = _lineTax(x);
                        final net = _lineTotal(x);
                        return Container(
                          constraints: BoxConstraints(
                              minHeight: (Theme.of(context)
                                          .listTileTheme
                                          .minTileHeight ??
                                      55)
                                  .clamp(55, 72)
                                  .toDouble()),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          color: i.isOdd
                              ? V3Style.rowStripe(context)
                              : Colors.transparent,
                          child: Row(children: [
                            Expanded(
                                flex: 4,
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text('${x['name']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                          '${x['sku'] ?? '—'} • ${x['barcode'] ?? 'No barcode'} • ${x['product_type'] ?? 'Stocked'}${(x['batch_no'] ?? '').toString().isNotEmpty ? ' • Batch ${x['batch_no']}' : ''}${(x['expiry_date'] ?? '').toString().isNotEmpty ? ' • Exp ${x['expiry_date']}' : ''}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              color: V3Style.muted)),
                                    ])),
                            SizedBox(
                                width: 72,
                                child: Text(qty.toStringAsFixed(2),
                                    textAlign: TextAlign.right)),
                            SizedBox(
                                width: 92,
                                child: Text(cost.toStringAsFixed(3),
                                    textAlign: TextAlign.right)),
                            SizedBox(
                                width: 88,
                                child: Text(discount.toStringAsFixed(3),
                                    textAlign: TextAlign.right)),
                            SizedBox(
                                width: 72,
                                child: Text(lineTax.toStringAsFixed(3),
                                    textAlign: TextAlign.right)),
                            SizedBox(
                                width: 100,
                                child: Text(net.toStringAsFixed(3),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700))),
                            SizedBox(
                                width: 86,
                                child: Row(children: [
                                  IconButton(
                                      tooltip: 'Edit line',
                                      onPressed: () => _editLine(i),
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 18)),
                                  IconButton(
                                      tooltip: 'Remove',
                                      onPressed: () =>
                                          setState(() => items.removeAt(i)),
                                      style: IconButton.styleFrom(
                                          foregroundColor: V3Style.danger),
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18)),
                                ])),
                          ]),
                        );
                      },
                    ),
            ),
          ]),
        ),
      );

  Widget _summaryPanel() => Card(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Purchase Details',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
                  key: ValueKey(supplierRefresh),
                  future: AppDatabase.instance
                      .suppliers(activeOnly: true, limit: 10000),
                  builder: (context, snapshot) {
                    final suppliers = snapshot.data ?? [];
                    return SearchableMapSelect(
                      options: suppliers,
                      value: supplierId.isEmpty ? null : supplierId,
                      focusNode: supplierFocus,
                      labelText: 'Supplier',
                      hintText: 'Type name, phone or email...',
                      display: (s) => '${s['name']}',
                      subtitle: (s) {
                        final phone = '${s['phone'] ?? ''}'.trim();
                        final email = '${s['email'] ?? ''}'.trim();
                        final balance = (s['balance'] as num? ?? 0).toDouble();
                        return [
                          if (phone.isNotEmpty) phone,
                          if (email.isNotEmpty) email,
                          if (balance > 0) 'Due ${balance.toStringAsFixed(3)}',
                        ].join(' • ');
                      },
                      onChanged: (v) => setState(() => supplierId = v ?? ''),
                    );
                  },
                ),
              ),
              const SizedBox(width: 7),
              IconButton.filledTonal(
                  tooltip: 'Add supplier',
                  onPressed: _addSupplier,
                  style: IconButton.styleFrom(foregroundColor: V3Style.info),
                  icon: const Icon(Icons.add_business, size: 18)),
            ]),
            const SizedBox(height: 10),
            TextField(
                controller: documentCtl,
                decoration: const InputDecoration(
                    labelText: 'Supplier invoice / document no.')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: _amountField(freightCtl, 'Freight / delivery',
                      focusNode: freightFocus)),
              const SizedBox(width: 8),
              Expanded(child: _amountField(otherCtl, 'Other charges')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: paidCtl,
                      focusNode: paidFocus,
                      onChanged: (_) => setState(() {}),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Paid (blank = full)'))),
              const SizedBox(width: 8),
              Expanded(
                  child: DropdownButtonFormField<String>(
                      value: paymentMethod,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: ['Cash', 'Card', 'Bank', 'Cheque', 'Other']
                          .map(
                              (x) => DropdownMenuItem(value: x, child: Text(x)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => paymentMethod = v ?? 'Cash'))),
            ]),
            const SizedBox(height: 10),
            TextField(
                controller: notesCtl,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes')),
            const Spacer(),
            const Divider(),
            _moneyRow('Subtotal', subtotal),
            _moneyRow('Discounts', discountTotal, negative: true),
            _moneyRow('Tax', taxTotal),
            _moneyRow('Freight / delivery', _number(freightCtl)),
            _moneyRow('Other charges', _number(otherCtl)),
            _moneyRow('Total', total, strong: true),
            _moneyRow('Paid', paidPreview),
            _moneyRow('Balance due', balancePreview),
            const SizedBox(height: 12),
            SizedBox(
                height: 46,
                child: FilledButton.icon(
                    onPressed: items.isEmpty ? null : savePurchase,
                    style:
                        FilledButton.styleFrom(backgroundColor: V3Style.teal),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(
                        'Receive Purchase  •  ${total.toStringAsFixed(3)}'))),
          ]),
        ),
      );

  Widget _amountField(TextEditingController controller, String label,
          {FocusNode? focusNode}) =>
      TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: label),
      );

  Widget _moneyRow(String label, double value,
          {bool strong = false, bool negative = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight: strong ? FontWeight.w800 : FontWeight.w500))),
          Text(
              '${negative && value != 0 ? '-' : ''}${value.toStringAsFixed(3)}',
              style: TextStyle(
                  fontSize: strong ? 19 : 13,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w700)),
        ]),
      );
}

class _PurchaseLineDialog extends StatefulWidget {
  final Map<String, Object?> product;
  final Map<String, Object?> draft;
  const _PurchaseLineDialog({required this.product, required this.draft});
  @override
  State<_PurchaseLineDialog> createState() => _PurchaseLineDialogState();
}

class _PurchaseLineDialogState extends State<_PurchaseLineDialog> {
  late double qty;
  late double cost;
  late double discount;
  late double taxRate;
  late bool taxInclusive;
  late String batch;
  late String expiry;
  List<Map<String, Object?>> components = [];
  List<Map<String, Object?>> availableProducts = [];
  List<String> availableUnits = const ['pcs', 'kg', 'g', 'L', 'ml'];
  bool loadingComponents = false;
  String componentId = '';
  final componentSearch = TextEditingController();
  double componentQty = 1;
  String componentUnit = 'pcs';
  double componentMultiplier = 1;

  bool get recipeLike => ['Recipe', 'Combo']
      .contains((widget.product['product_type'] ?? '').toString());
  bool get trackBatch =>
      (widget.product['track_batch'] as num? ?? 0).toInt() == 1;
  bool get trackExpiry =>
      (widget.product['track_expiry'] as num? ?? 0).toInt() == 1;

  @override
  void initState() {
    super.initState();
    qty = (widget.draft['qty'] as num? ?? 1).toDouble();
    cost = (widget.draft['unit_cost'] as num? ?? 0).toDouble();
    discount = (widget.draft['discount'] as num? ?? 0).toDouble();
    taxRate = (widget.draft['tax_rate'] as num? ?? 0).toDouble();
    taxInclusive = ((widget.draft['tax_inclusive'] as num?) ?? 0).toInt() == 1;
    batch = (widget.draft['batch_no'] ?? '').toString();
    expiry = (widget.draft['expiry_date'] ?? '').toString();
    if (recipeLike) _loadComponents();
  }

  @override
  void dispose() {
    componentSearch.dispose();
    super.dispose();
  }

  Future<void> _loadComponents() async {
    setState(() => loadingComponents = true);
    final current = await AppDatabase.instance
        .recipeComponents(widget.product['id'].toString());
    final all = await AppDatabase.instance.products(activeOnly: true);
    final units = await AppDatabase.instance.units();
    if (!mounted) return;
    setState(() {
      components = current.map((e) => Map<String, Object?>.from(e)).toList();
      availableProducts = all
          .where((p) =>
              p['id'] != widget.product['id'] &&
              (p['product_type'] ?? 'Stocked').toString() == 'Stocked')
          .toList();
      availableUnits =
          units.isEmpty ? const ['pcs', 'kg', 'g', 'L', 'ml'] : units;
      if (availableProducts.isNotEmpty) {
        componentId = availableProducts.first['id'].toString();
        componentUnit = (availableProducts.first['unit'] ?? 'pcs').toString();
        if (!availableUnits.contains(componentUnit))
          availableUnits = [...availableUnits, componentUnit];
        componentMultiplier = _purchaseUnitMultiplier(componentUnit,
                (availableProducts.first['unit'] ?? 'pcs').toString()) ??
            1;
      }
      loadingComponents = false;
    });
  }

  void _addComponent() {
    if (componentId.isEmpty || componentQty <= 0 || componentMultiplier <= 0)
      return;
    final p = availableProducts.firstWhere((x) => x['id'] == componentId);
    setState(() {
      components.removeWhere((x) => x['component_product_id'] == componentId);
      components.add({
        'component_product_id': componentId,
        'component_name': p['name'],
        'component_sku': p['sku'],
        'stock_unit': p['unit'],
        'qty': componentQty,
        'unit': componentUnit,
        'multiplier': componentMultiplier,
      });
    });
  }

  double _currentTax() {
    final taxable =
        (qty * cost - discount).clamp(0, double.infinity).toDouble();
    if (taxRate <= 0) return 0;
    return taxInclusive
        ? taxable * taxRate / (100 + taxRate)
        : taxable * taxRate / 100;
  }

  double _currentTotal() {
    final net = (qty * cost - discount).clamp(0, double.infinity).toDouble();
    return taxInclusive ? net : net + _currentTax();
  }

  Future<void> _apply() async {
    final gross = qty * cost;
    if (qty <= 0 || cost < 0 || discount < 0 || discount > gross) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Check quantity, unit cost and discount. Discount cannot exceed the line amount.')));
      return;
    }
    if (trackExpiry && expiry.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This product tracks expiry. Enter the expiry date.')));
      return;
    }
    if (recipeLike) {
      await AppDatabase.instance
          .saveRecipeComponents(widget.product['id'].toString(), components);
    }
    if (!mounted) return;
    Navigator.pop(context, {
      ...widget.draft,
      'qty': qty,
      'unit_cost': cost,
      'discount': discount,
      'tax_rate': taxRate,
      'tax_inclusive': taxInclusive ? 1 : 0,
      'tax_amount': _currentTax(),
      'batch_no': batch.trim(),
      'expiry_date': expiry.trim().isEmpty ? null : expiry.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final barcode = (widget.product['external_barcode'] ??
            widget.product['internal_barcode'] ??
            '—')
        .toString();
    final type = (widget.product['product_type'] ?? 'Stocked').toString();
    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: 860, maxHeight: recipeLike ? 760 : 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('${widget.product['name']}',
                            style: const TextStyle(
                                fontSize: 21, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(
                            '${widget.product['sku'] ?? '—'} • Barcode $barcode • $type • Stock unit ${widget.product['unit'] ?? 'pcs'}',
                            style: TextStyle(color: V3Style.mutedFor(context))),
                      ])),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close)),
                ]),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          initialValue: qty.toString(),
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Quantity'),
                          onChanged: (v) => qty = double.tryParse(v) ?? 0)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextFormField(
                          initialValue: cost.toString(),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Unit cost'),
                          onChanged: (v) => cost = double.tryParse(v) ?? 0)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextFormField(
                          initialValue: discount.toString(),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Line discount'),
                          onChanged: (v) => setState(
                              () => discount = double.tryParse(v) ?? 0))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          initialValue: taxRate.toString(),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(labelText: 'Tax %'),
                          onChanged: (v) => setState(() => taxRate =
                              (double.tryParse(v) ?? 0)
                                  .clamp(0, 100)
                                  .toDouble()))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Tax included in cost'),
                          subtitle:
                              const Text('Otherwise tax is added on top.'),
                          value: taxInclusive,
                          onChanged: (v) => setState(() => taxInclusive = v))),
                ]),
                if (trackBatch || trackExpiry) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    if (trackBatch)
                      Expanded(
                          child: TextFormField(
                              initialValue: batch,
                              decoration: const InputDecoration(
                                  labelText: 'Batch / lot'),
                              onChanged: (v) => batch = v)),
                    if (trackBatch && trackExpiry) const SizedBox(width: 10),
                    if (trackExpiry)
                      Expanded(
                          child: Row(children: [
                        Expanded(
                            child: TextFormField(
                                key: ValueKey('expiry-$expiry'),
                                initialValue: expiry,
                                decoration: const InputDecoration(
                                    labelText: 'Expiry date',
                                    hintText: 'YYYY-MM-DD'),
                                onChanged: (v) => expiry = v)),
                        const SizedBox(width: 6),
                        IconButton(
                            tooltip: 'Choose expiry date',
                            onPressed: () async {
                              final initial = DateTime.tryParse(expiry) ??
                                  DateTime.now().add(const Duration(days: 30));
                              final picked = await showDatePicker(
                                  context: context,
                                  firstDate: DateTime.now()
                                      .subtract(const Duration(days: 3650)),
                                  lastDate: DateTime.now()
                                      .add(const Duration(days: 3650)),
                                  initialDate: initial);
                              if (picked != null && mounted)
                                setState(() => expiry =
                                    '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                            },
                            icon: const Icon(Icons.calendar_month_outlined)),
                      ])),
                  ]),
                ],
                if (recipeLike) ...[
                  const SizedBox(height: 18),
                  const Text('RECIPE / COMBO COMPONENTS',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                          color: Color(0xFF778B9E))),
                  const SizedBox(height: 7),
                  Text(
                      'Configure ingredient/product usage here. The multiplier converts the entered usage unit into the component stock unit. Example: 250 g × 0.001 = 0.25 kg.',
                      style: TextStyle(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  if (loadingComponents)
                    const Center(
                        child: Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator()))
                  else ...[
                    Row(children: [
                      Expanded(
                          flex: 3,
                          child: V4ProductSearchField(
                            controller: componentSearch,
                            activeOnly: true,
                            allowedProductTypes: const {'Stocked'},
                            excludeProductId: '${widget.product['id']}',
                            hintText: 'Type component name / SKU / barcode...',
                            onSelected: (p) {
                              final stockUnit = (p['unit'] ?? 'pcs').toString();
                              setState(() {
                                componentId = '${p['id']}';
                                componentSearch.text = '${p['name']}';
                                componentUnit = stockUnit;
                                if (!availableUnits.contains(componentUnit))
                                  availableUnits = [
                                    ...availableUnits,
                                    componentUnit
                                  ];
                                componentMultiplier = 1;
                              });
                            },
                          )),
                      const SizedBox(width: 8),
                      Expanded(
                          child: TextFormField(
                              initialValue: '1',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration:
                                  const InputDecoration(labelText: 'Use qty'),
                              onChanged: (v) =>
                                  componentQty = double.tryParse(v) ?? 0)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: DropdownButtonFormField<String>(
                              value: availableUnits.contains(componentUnit)
                                  ? componentUnit
                                  : null,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: 'Use unit'),
                              items: [
                                for (final u in availableUnits)
                                  DropdownMenuItem(value: u, child: Text(u))
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                final p = availableProducts
                                    .firstWhere((x) => x['id'] == componentId);
                                final stockUnit =
                                    (p['unit'] ?? 'pcs').toString();
                                setState(() {
                                  componentUnit = v;
                                  componentMultiplier =
                                      _purchaseUnitMultiplier(v, stockUnit) ??
                                          componentMultiplier;
                                });
                              })),
                      const SizedBox(width: 8),
                      Expanded(
                          child: TextFormField(
                              key: ValueKey(
                                  'purchase-mult-$componentId-$componentUnit-$componentMultiplier'),
                              initialValue: componentMultiplier.toString(),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Multiplier'),
                              onChanged: (v) => componentMultiplier =
                                  double.tryParse(v) ?? 0)),
                      const SizedBox(width: 8),
                      FilledButton(
                          onPressed: _addComponent, child: const Text('Add')),
                    ]),
                    const SizedBox(height: 8),
                    Flexible(
                        child: Container(
                      constraints: const BoxConstraints(maxHeight: 230),
                      decoration: BoxDecoration(
                          border:
                              Border.all(color: Theme.of(context).dividerColor),
                          borderRadius: BorderRadius.circular(10)),
                      child: components.isEmpty
                          ? const Center(
                              child: Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text('No components configured.')))
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: components.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final c = components[i];
                                final q = (c['qty'] as num? ?? 0).toDouble();
                                final m =
                                    (c['multiplier'] as num? ?? 1).toDouble();
                                return ListTile(
                                    dense: true,
                                    title: Text(
                                        '${c['component_name'] ?? c['component_product_id']}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                    subtitle: Text(
                                        '${q.toStringAsFixed(3)} ${c['unit'] ?? ''} × ${m.toStringAsFixed(4)} = ${(q * m).toStringAsFixed(4)} ${c['stock_unit'] ?? ''}'),
                                    trailing: IconButton(
                                        onPressed: () => setState(
                                            () => components.removeAt(i)),
                                        icon:
                                            const Icon(Icons.delete_outline)));
                              }),
                    )),
                  ],
                ],
                const SizedBox(height: 18),
                Row(children: [
                  Text(
                      'Tax ${_currentTax().toStringAsFixed(3)}  •  Line total ${_currentTotal().toStringAsFixed(3)}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                      onPressed: _apply,
                      icon: const Icon(Icons.check, size: 17),
                      label: const Text('Add / Apply Line')),
                ]),
              ]),
        ),
      ),
    );
  }
}
