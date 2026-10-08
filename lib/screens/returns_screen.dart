import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/pagination_bar.dart';
import '../ui/v3_style.dart';
import '../ui/product_search_field.dart';
import '../ui/searchable_map_select.dart';

class ReturnsScreen extends StatefulWidget {
  const ReturnsScreen({super.key});
  @override
  State<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends State<ReturnsScreen> {
  final search = TextEditingController();
  int refreshKey = 0;
  String query = '';
  String status = 'All';
  String sort = 'Newest';
  int page = 0;
  int pageSize = 10;
  DateTime? from;
  DateTime? to;
  bool purchaseMode = false;
  int purchaseRefresh = 0;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<Map<String, Object>> _load() => AppDatabase.instance.salesHistoryPage(
        limit: pageSize,
        offset: page * pageSize,
        search: query,
        status: status,
        sort: sort,
        from: from,
        to: to,
      );

  Future<void> _startReturn(Map<String, Object?> sale) async {
    final items =
        await AppDatabase.instance.returnableSaleItems(sale['id'] as String);
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This sale has no returnable quantities remaining.')));
      return;
    }
    final quantities = <int, TextEditingController>{};
    for (var i = 0; i < items.length; i++)
      quantities[i] = TextEditingController(text: '0');
    final notes = TextEditingController();
    var method = 'Cash';

    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Row(children: [
            const Icon(Icons.keyboard_return_outlined),
            const SizedBox(width: 10),
            Expanded(child: Text('Sales Return • ${sale['no']}'))
          ]),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${sale['customer_name'] ?? 'Walk-in customer'} • Sale total ${(sale['total'] as num? ?? 0).toStringAsFixed(3)}',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: V3Style.softFor(V3Style.info,
                              dark: Theme.of(context).brightness ==
                                  Brightness.dark),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: V3Style.info.withValues(alpha: .20))),
                      child: Row(children: [
                        const Icon(Icons.info_outline, color: V3Style.info),
                        const SizedBox(width: 9),
                        Expanded(
                            child: Text(
                                'Enter only the quantity being returned. Stock and customer balance will be updated with an audit trail.',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface)))
                      ]),
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < items.length; i++)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            border: Border.all(
                                color: Theme.of(context).dividerColor),
                            borderRadius: BorderRadius.circular(10)),
                        child: Row(children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text('${items[i]['name']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(
                                    'Sold ${(items[i]['qty'] as num? ?? 0).toStringAsFixed(2)} • Returned ${(items[i]['returned_qty'] as num? ?? 0).toStringAsFixed(2)} • Available ${(items[i]['returnable_qty'] as num? ?? 0).toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        fontSize: 11, color: V3Style.muted)),
                              ])),
                          const SizedBox(width: 12),
                          SizedBox(
                              width: 135,
                              child: TextField(
                                  controller: quantities[i],
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: 'Return qty'))),
                        ]),
                      ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                          child: DropdownButtonFormField<String>(
                              value: method,
                              decoration: const InputDecoration(
                                  labelText: 'Refund method'),
                              items: const ['Cash', 'Card', 'Bank', 'Other']
                                  .map((x) => DropdownMenuItem(
                                      value: x, child: Text(x)))
                                  .toList(),
                              onChanged: (v) =>
                                  setDialog(() => method = v ?? method))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextField(
                              controller: notes,
                              decoration: const InputDecoration(
                                  labelText: 'Return reason / notes'))),
                    ]),
                  ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.keyboard_return),
                label: const Text('Post Return')),
          ],
        ),
      ),
    );

    if (ok == true) {
      final returnLines = <Map<String, Object?>>[];
      for (var i = 0; i < items.length; i++) {
        final qty = double.tryParse(quantities[i]!.text) ?? 0;
        if (qty > 0)
          returnLines.add({'sale_item_id': items[i]['id'], 'qty': qty});
      }
      try {
        final no = await AppDatabase.instance.postSaleReturn(
            saleId: sale['id'] as String,
            items: returnLines,
            refundMethod: method,
            notes: notes.text.trim());
        if (mounted) {
          setState(() {
            refreshKey++;
            page = 0;
          });
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Return $no posted.')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
    // Do not dispose dialog controllers synchronously after Navigator.pop; Flutter may still be
    // finishing the route animation for a frame. They are short-lived and released with the route.
  }

  Future<void> _unlinkedReturn() async {
    final purchase = purchaseMode;
    final parties = purchase
        ? await AppDatabase.instance.suppliers(activeOnly: true, limit: 10000)
        : await AppDatabase.instance.customers(activeOnly: true, limit: 10000);
    if (!mounted) return;
    final productSearch = TextEditingController();
    final reason = TextEditingController();
    final lines = <Map<String, Object?>>[];
    final qty = <String, TextEditingController>{};
    final values = <String, TextEditingController>{};
    List<Map<String, Object?>> candidates = [];
    String? party;
    var method = 'Cash';
    var restore = true;
    var posting = false;
    var error = '';
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title:
                      Text('Create ${purchase ? 'Purchase' : 'Sales'} Return'),
                  content: SizedBox(
                      width: 760,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(purchase
                                ? 'Stock will leave this branch. The return reduces supplier dues; any excess becomes supplier credit.'
                                : 'The refund is recorded today as a separate return. Restore stock only when the goods can be resold.'),
                            const SizedBox(height: 12),
                            SearchableMapSelect(
                              options: parties,
                              value: party,
                              labelText: purchase
                                  ? 'Supplier *'
                                  : 'Customer (optional)',
                              hintText: purchase
                                  ? 'Type supplier name / phone...'
                                  : 'Type customer name / phone...',
                              enabled: !posting,
                              allowClear: !purchase,
                              display: (v) => '${v['name']}',
                              subtitle: (v) =>
                                  '${v['phone'] ?? ''} ${v['email'] ?? ''}'
                                      .trim(),
                              onChanged: (v) => update(() => party = v),
                            ),
                            const SizedBox(height: 12),
                            if (!posting)
                              V4ProductSearchField(
                                  controller: productSearch,
                                  activeOnly: true,
                                  onSelected: (product) => update(() {
                                        final id = '${product['id']}';
                                        if (qty.containsKey(id)) {
                                          error =
                                              'Product already added; update its quantity.';
                                          return;
                                        }
                                        lines.add(product);
                                        qty[id] =
                                            TextEditingController(text: '1');
                                        values[id] = TextEditingController(
                                            text: ((product[purchase
                                                                ? 'cost'
                                                                : 'price']
                                                            as num? ??
                                                        0)
                                                    .toDouble())
                                                .toStringAsFixed(3));
                                        productSearch.clear();
                                      })),
                            for (final product in lines)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Row(children: [
                                    Expanded(child: Text('${product['name']}')),
                                    SizedBox(
                                        width: 100,
                                        child: TextField(
                                            enabled: !posting,
                                            controller: qty['${product['id']}'],
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: const InputDecoration(
                                                labelText: 'Quantity'))),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                        width: 150,
                                        child: TextField(
                                            enabled: !posting,
                                            controller:
                                                values['${product['id']}'],
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: const InputDecoration(
                                                labelText:
                                                    'Total return KWD'))),
                                    IconButton(
                                        onPressed: posting
                                            ? null
                                            : () => update(() {
                                                  lines.remove(product);
                                                  qty.remove(
                                                      '${product['id']}');
                                                  values.remove(
                                                      '${product['id']}');
                                                }),
                                        icon: const Icon(Icons.close))
                                  ])),
                            OutlinedButton.icon(
                                onPressed: posting
                                    ? null
                                    : () async {
                                        try {
                                          final matches = await AppDatabase
                                              .instance
                                              .returnCandidates(
                                                  purchase: purchase,
                                                  productIds: lines
                                                      .map((p) => '${p['id']}')
                                                      .toList(),
                                                  partyId: party);
                                          if (ctx.mounted)
                                            update(() {
                                              candidates = matches;
                                              error = matches.isEmpty
                                                  ? 'No matching invoices found. You can continue with an unlinked return.'
                                                  : '';
                                            });
                                        } catch (e) {
                                          if (ctx.mounted)
                                            update(() => error = '$e');
                                        }
                                      },
                                icon: const Icon(Icons.manage_search),
                                label: const Text(
                                    'Find possible original invoices')),
                            for (final invoice in candidates)
                              ListTile(
                                  title: Text('${invoice['no']}'),
                                  subtitle: Text(
                                      '${invoice['created_at']} · KWD ${(invoice['total'] as num? ?? 0).toStringAsFixed(3)}'),
                                  trailing: const Icon(Icons.arrow_forward),
                                  onTap: posting
                                      ? null
                                      : () {
                                          Navigator.pop(ctx);
                                          if (purchase) {
                                            _startPurchaseReturn(invoice);
                                          } else {
                                            _startReturn(invoice);
                                          }
                                        }),
                            if (!purchase) ...[
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Restore resellable stock'),
                                  value: restore,
                                  onChanged: posting
                                      ? null
                                      : (v) => update(() => restore = v)),
                              DropdownButtonFormField<String>(
                                  value: method,
                                  decoration: const InputDecoration(
                                      labelText: 'Refund method'),
                                  items: ['Cash', 'Card', 'Bank', 'Other']
                                      .map((v) => DropdownMenuItem(
                                          value: v, child: Text(v)))
                                      .toList(),
                                  onChanged: posting
                                      ? null
                                      : (v) => update(() => method = v!)),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                                enabled: !posting,
                                controller: reason,
                                decoration: const InputDecoration(
                                    labelText: 'Return reason *')),
                            const SizedBox(height: 8),
                            const Text(
                                'Without an invoice, tax is not reversed automatically. Use the original invoice for tax-sensitive returns.',
                                style: TextStyle(fontSize: 12)),
                            if (error.isNotEmpty)
                              Text(error,
                                  style: const TextStyle(color: Colors.red)),
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: posting ? null : () => Navigator.pop(ctx),
                        child: const Text('Cancel')),
                    FilledButton.icon(
                        onPressed: posting
                            ? null
                            : () async {
                                final prepared = <Map<String, Object?>>[];
                                for (final product in lines) {
                                  final id = '${product['id']}';
                                  final q = double.tryParse(qty[id]!.text);
                                  final amount =
                                      double.tryParse(values[id]!.text);
                                  if (q == null ||
                                      amount == null ||
                                      !q.isFinite ||
                                      !amount.isFinite ||
                                      q <= 0 ||
                                      amount <= 0) {
                                    update(() => error =
                                        'Enter positive quantities and return amounts.');
                                    return;
                                  }
                                  prepared.add({
                                    'product_id': id,
                                    'qty': q,
                                    'amount': amount
                                  });
                                }
                                update(() {
                                  posting = true;
                                  error = '';
                                });
                                try {
                                  final no = await AppDatabase.instance
                                      .postUnlinkedReturn(
                                          purchase: purchase,
                                          partyId: party,
                                          items: prepared,
                                          notes: reason.text,
                                          refundMethod: method,
                                          restoreStock: restore);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) {
                                    setState(() {
                                      refreshKey++;
                                      purchaseRefresh++;
                                    });
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content:
                                                Text('Return $no posted.')));
                                  }
                                } catch (e) {
                                  if (ctx.mounted)
                                    update(() {
                                      posting = false;
                                      error = '$e';
                                    });
                                }
                              },
                        icon: const Icon(Icons.keyboard_return),
                        label: Text(posting ? 'Posting…' : 'Post Return'))
                  ],
                )));
  }

  Future<void> _history() async {
    final now = DateTime.now();
    final rows = await AppDatabase.instance.returnsBetween(DateTime(2000), now);
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Posted Return History'),
                content: SizedBox(
                    width: 850,
                    height: 500,
                    child: rows.isEmpty
                        ? const Center(child: Text('No returns posted.'))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (ctx, i) {
                              final r = rows[i];
                              return ListTile(
                                  title: Text(
                                      '${r['no']} · ${r['return_type']} · KWD ${(r['total'] as num? ?? 0).toStringAsFixed(3)}'),
                                  subtitle: Text(
                                      '${r['counterparty']} · ${r['created_at']}\nSource: ${r['source_no']}'),
                                  isThreeLine: true,
                                  trailing: r['original_id'] != null
                                      ? null
                                      : OutlinedButton(
                                          onPressed: () async {
                                            try {
                                              await _linkReference(r);
                                              if (ctx.mounted)
                                                Navigator.pop(ctx);
                                              _history();
                                            } catch (e) {
                                              if (mounted)
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(SnackBar(
                                                        content: Text('$e')));
                                            }
                                          },
                                          child: const Text('Link reference')));
                            })),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'))
                ]));
  }

  Future<void> _linkReference(Map<String, Object?> r) async {
    final purchase = r['return_type'] == 'Supplier Return';
    final lines = await AppDatabase.instance.db.query(
        purchase ? 'purchase_return_items' : 'sale_return_items',
        where: 'return_id=?',
        whereArgs: [r['return_id']]);
    final matches = await AppDatabase.instance.returnCandidates(
        purchase: purchase,
        productIds: lines.map((l) => '${l['product_id']}').toList(),
        partyId: r['party_id'] as String?);
    if (!mounted) return;
    final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Link invoice reference'),
                content: SizedBox(
                    width: 650,
                    height: 350,
                    child: Column(children: [
                      const Text(
                          'This adds an audit reference. Stock, refund, supplier balance and tax will keep their existing posting.'),
                      const SizedBox(height: 10),
                      Expanded(
                          child: matches.isEmpty
                              ? const Center(
                                  child: Text(
                                      'No matching invoices in this branch.'))
                              : ListView(children: [
                                  for (final invoice in matches)
                                    ListTile(
                                        title: Text('${invoice['no']}'),
                                        subtitle:
                                            Text('${invoice['created_at']}'),
                                        onTap: () => Navigator.pop(
                                            ctx, '${invoice['id']}'))
                                ]))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'))
                ]));
    if (selected != null)
      await AppDatabase.instance.linkReturnReference(
          purchase: purchase,
          returnId: '${r['return_id']}',
          invoiceId: selected);
  }

  Future<void> _pickDate(bool start) async {
    final initial = start ? (from ?? DateTime.now()) : (to ?? DateTime.now());
    final value = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 366)));
    if (value == null) return;
    setState(() {
      if (start)
        from = value;
      else
        to = value;
      page = 0;
    });
  }

  Widget _salesBody(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Customer Returns',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              'Find the original sale, narrow the list with filters, then return only the required lines.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          _filters(),
          const SizedBox(height: 12),
          Expanded(
              child: FutureBuilder<Map<String, Object>>(
            key: ValueKey(refreshKey),
            future: _load(),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows =
                  (snapshot.data!['rows'] as List).cast<Map<String, Object?>>();
              final total = snapshot.data!['total'] as int;
              if (rows.isEmpty && total == 0)
                return const Card(
                    child:
                        Center(child: Text('No sales match these filters.')));
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  Expanded(
                      child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
                      final returned =
                          (r['returned_total'] as num? ?? 0).toDouble();
                      final totalValue = (r['total'] as num? ?? 0).toDouble();
                      return V4AlternateRow(
                        index: i,
                        minHeight: 68,
                        child: Row(children: [
                          Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                  color: const Color(0xFFEAF1FF),
                                  borderRadius: BorderRadius.circular(9)),
                              child: const Icon(Icons.receipt_long_outlined,
                                  color: V3Style.blue, size: 20)),
                          const SizedBox(width: 11),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                Text(
                                    '${r['no']} • ${r['customer_name'] ?? 'Walk-in customer'}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                Text(
                                    '${dt == null ? '' : DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal())} • ${r['payment_method'] ?? ''} • ${r['status'] ?? ''}',
                                    style: const TextStyle(
                                        fontSize: 11, color: V3Style.muted)),
                              ])),
                          SizedBox(
                              width: 120,
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Text('Sale',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: V3Style.muted)),
                                    Text(totalValue.toStringAsFixed(3),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800))
                                  ])),
                          const SizedBox(width: 15),
                          SizedBox(
                              width: 120,
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Text('Returned',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: V3Style.muted)),
                                    Text(returned.toStringAsFixed(3),
                                        style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: returned > 0
                                                ? const Color(0xFF7C3AED)
                                                : null))
                                  ])),
                          const SizedBox(width: 16),
                          OutlinedButton.icon(
                            onPressed: returned + .000001 >= totalValue
                                ? null
                                : () => _startReturn(r),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: V3Style.labelAccent(context),
                              backgroundColor: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? V3Style.lime.withValues(alpha: .08)
                                  : const Color(0xFFF3F8F6),
                            ),
                            icon: const Icon(Icons.keyboard_return, size: 17),
                            label:
                                Text(returned > 0 ? 'Return More' : 'Return'),
                          ),
                        ]),
                      );
                    },
                  )),
                  V4PaginationBar(
                      total: total,
                      page: page,
                      pageSize: pageSize,
                      onPageChanged: (v) => setState(() => page = v),
                      onPageSizeChanged: (v) => setState(() {
                            pageSize = v;
                            page = 0;
                          })),
                ]),
              );
            },
          )),
        ]),
      );

  Future<void> _startPurchaseReturn(Map<String, Object?> purchase) async {
    final items = await AppDatabase.instance
        .returnablePurchaseItems(purchase['id'] as String);
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('This purchase has no returnable quantities remaining.')));
      return;
    }
    final quantities = <int, TextEditingController>{
      for (var i = 0; i < items.length; i++) i: TextEditingController(text: '0')
    };
    final notes = TextEditingController();
    var method = 'Bank';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialog) => AlertDialog(
                title: Text('Return to Supplier • ${purchase['no']}'),
                content: SizedBox(
                    width: 720,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              '${purchase['supplier_name'] ?? 'Supplier'} • Purchase total ${(purchase['total'] as num? ?? 0).toStringAsFixed(3)}'),
                          const SizedBox(height: 10),
                          Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                  color: V3Style.softFor(V3Style.warning,
                                      dark: Theme.of(context).brightness ==
                                          Brightness.dark),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: V3Style.warning
                                          .withValues(alpha: .20))),
                              child: Row(children: [
                                const Icon(Icons.info_outline,
                                    color: V3Style.warning),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(
                                        'Returning stock reduces on-hand inventory and supplier payable. If the invoice is already paid, the excess is recorded as a supplier refund / credit.',
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface)))
                              ])),
                          const SizedBox(height: 12),
                          for (var i = 0; i < items.length; i++)
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Theme.of(context).dividerColor),
                                  borderRadius: BorderRadius.circular(10)),
                              child: Row(children: [
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('${items[i]['name']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                          'Purchased ${(items[i]['qty'] as num? ?? 0).toStringAsFixed(2)} • Already returned ${(items[i]['returned_qty'] as num? ?? 0).toStringAsFixed(2)} • Available ${(items[i]['returnable_qty'] as num? ?? 0).toStringAsFixed(2)}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: V3Style.muted))
                                    ])),
                                const SizedBox(width: 12),
                                SizedBox(
                                    width: 135,
                                    child: TextField(
                                        controller: quantities[i],
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: true),
                                        decoration: const InputDecoration(
                                            labelText: 'Return qty'))),
                              ]),
                            ),
                          Row(children: [
                            Expanded(
                                child: DropdownButtonFormField<String>(
                                    value: method,
                                    decoration: const InputDecoration(
                                        labelText: 'Refund / credit method'),
                                    items: const [
                                      'Bank',
                                      'Cash',
                                      'Card',
                                      'Supplier Credit',
                                      'Other'
                                    ]
                                        .map((x) => DropdownMenuItem(
                                            value: x, child: Text(x)))
                                        .toList(),
                                    onChanged: (v) =>
                                        setDialog(() => method = v ?? method))),
                            const SizedBox(width: 10),
                            Expanded(
                                child: TextField(
                                    controller: notes,
                                    decoration: const InputDecoration(
                                        labelText: 'Reason / notes'))),
                          ]),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel')),
                  FilledButton.icon(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      icon: const Icon(Icons.assignment_return_outlined),
                      label: const Text('Post Supplier Return'))
                ],
              )),
    );
    if (ok == true) {
      final lines = <Map<String, Object?>>[];
      for (var i = 0; i < items.length; i++) {
        final qty = double.tryParse(quantities[i]!.text) ?? 0;
        if (qty > 0)
          lines.add({'purchase_item_id': items[i]['id'], 'qty': qty});
      }
      try {
        final no = await AppDatabase.instance.postPurchaseReturn(
            purchaseId: purchase['id'] as String,
            items: lines,
            refundMethod: method,
            notes: notes.text.trim());
        if (mounted) {
          setState(() => purchaseRefresh++);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Supplier return $no posted.')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Widget _purchaseBody(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Purchase Returns',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              'Return damaged, expired, excess or incorrect stock to suppliers. RELIQ reverses stock, payable and tax impact together.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          _filters(),
          const SizedBox(height: 12),
          Expanded(
              child: FutureBuilder<Map<String, Object>>(
            key: ValueKey(
                'purchase-$purchaseRefresh-$page-$pageSize-$query-$status-$sort-$from-$to'),
            future: AppDatabase.instance.purchaseHistoryPage(
                limit: pageSize,
                offset: page * pageSize,
                search: query,
                status: status,
                sort: sort,
                from: from,
                to: to),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows =
                  (snapshot.data!['rows'] as List).cast<Map<String, Object?>>();
              final total = snapshot.data!['total'] as int;
              if (rows.isEmpty)
                return const Card(
                    child: Center(
                        child: Text('No purchases match these filters.')));
              return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    Expanded(
                        child: ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final r = rows[i];
                              final dt =
                                  DateTime.tryParse('${r['created_at'] ?? ''}');
                              return V4AlternateRow(
                                  index: i,
                                  minHeight: 68,
                                  child: Row(children: [
                                    const Icon(Icons.local_shipping_outlined,
                                        color: V3Style.blue),
                                    const SizedBox(width: 11),
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                          Text(
                                              '${r['no']} • ${r['supplier_name'] ?? 'Supplier'}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800)),
                                          Text(
                                              '${dt == null ? '' : DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal())} • ${r['document_no'] ?? ''} • ${r['status'] ?? ''}',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: V3Style.muted))
                                        ])),
                                    SizedBox(
                                        width: 120,
                                        child: Text(
                                            (r['total'] as num? ?? 0)
                                                .toStringAsFixed(3),
                                            textAlign: TextAlign.end,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w800))),
                                    const SizedBox(width: 16),
                                    FilledButton.tonalIcon(
                                        onPressed: () =>
                                            _startPurchaseReturn(r),
                                        icon: const Icon(
                                            Icons.assignment_return_outlined,
                                            size: 17),
                                        label: const Text('Return Stock')),
                                  ]));
                            })),
                    V4PaginationBar(
                        total: total,
                        page: page,
                        pageSize: pageSize,
                        onPageChanged: (v) => setState(() => page = v),
                        onPageSizeChanged: (v) => setState(() {
                              pageSize = v;
                              page = 0;
                            })),
                  ]));
            },
          )),
        ]),
      );

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        icon: Icon(Icons.keyboard_return_outlined),
                        label: Text('Customer Returns')),
                    ButtonSegment(
                        value: true,
                        icon: Icon(Icons.assignment_return_outlined),
                        label: Text('Supplier Returns'))
                  ],
                  selected: {purchaseMode},
                  onSelectionChanged: (v) => setState(() {
                    purchaseMode = v.first;
                    page = 0;
                  }),
                ),
                OutlinedButton.icon(
                    onPressed: _history,
                    icon: const Icon(Icons.history),
                    label: const Text('Return History')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed: _unlinkedReturn,
                    icon: const Icon(Icons.add),
                    label: Text(purchaseMode
                        ? 'Create Purchase Return'
                        : 'Create Sales Return')),
                const SizedBox(width: 8),
                if (purchaseMode)
                  FutureBuilder<List<Map<String, Object?>>>(
                      future:
                          AppDatabase.instance.recentPurchaseReturns(limit: 1),
                      builder: (context, s) => Text(
                          s.hasData && s.data!.isNotEmpty
                              ? 'Latest: ${s.data!.first['no']}'
                              : 'No supplier returns posted yet',
                          style: const TextStyle(
                              fontSize: 11, color: V3Style.muted))),
              ]),
        ),
        Expanded(
            child: purchaseMode ? _purchaseBody(context) : _salesBody(context)),
      ]);

  Widget _filters() => Card(
          child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, box) {
          final controls = <Widget>[
            SizedBox(
                width: box.maxWidth < 900 ? box.maxWidth : 330,
                child: TextField(
                    controller: search,
                    onChanged: (v) => setState(() {
                          query = v.trim();
                          page = 0;
                        }),
                    decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: purchaseMode
                            ? 'Purchase no. or supplier'
                            : 'Sale no. or customer'))),
            SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                    value: status,
                    isExpanded: true,
                    decoration: InputDecoration(
                        labelText:
                            purchaseMode ? 'Purchase status' : 'Sale status'),
                    items: const ['All', 'Paid', 'Due', 'Returned']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) => setState(() {
                          status = v ?? 'All';
                          page = 0;
                        }))),
            SizedBox(
                width: 170,
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
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) => setState(() {
                          sort = v ?? 'Newest';
                          page = 0;
                        }))),
            SizedBox(
                width: 155,
                child: OutlinedButton.icon(
                    onPressed: () => _pickDate(true),
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: Text(from == null
                        ? 'From date'
                        : DateFormat('dd MMM yy').format(from!)))),
            SizedBox(
                width: 155,
                child: OutlinedButton.icon(
                    onPressed: () => _pickDate(false),
                    icon: const Icon(Icons.event_outlined, size: 16),
                    label: Text(to == null
                        ? 'To date'
                        : DateFormat('dd MMM yy').format(to!)))),
            if (from != null || to != null)
              TextButton.icon(
                  onPressed: () => setState(() {
                        from = null;
                        to = null;
                        page = 0;
                      }),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Clear')),
          ];
          return Wrap(
              spacing: 9,
              runSpacing: 9,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: controls);
        }),
      ));
}
