import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/document_share_service.dart';
import '../services/print_service.dart';
import '../services/whatsapp_service.dart';
import '../ui/v3_style.dart';
import '../ui/searchable_map_select.dart';
import '../ui/reliq_loading.dart';

class PurchaseOrdersScreen extends StatefulWidget {
  const PurchaseOrdersScreen({super.key});

  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> {
  int refreshKey = 0;
  String status = '';

  Future<void> _newOrder() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => const _PurchaseOrderDialog(),
    );
    if (ok == true && mounted) setState(() => refreshKey++);
  }

  Future<void> _receive(Map<String, Object?> order) async {
    final lines =
        await AppDatabase.instance.purchaseOrderItems(order['id'].toString());
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => _ReceivePurchaseOrderDialog(order: order, lines: lines),
    );
    if (ok == true && mounted) setState(() => refreshKey++);
  }

  Future<Map<String, Object?>> _supplierForOrder(
      Map<String, Object?> order) async {
    final rows = await AppDatabase.instance.db.query(
      'suppliers',
      where: 'id=?',
      whereArgs: [order['supplier_id']],
      limit: 1,
    );
    if (rows.isEmpty) throw Exception('Supplier record not found.');
    return rows.first;
  }

  Future<void> _previewPo(Map<String, Object?> order) async {
    try {
      final lines =
          await AppDatabase.instance.purchaseOrderItems(order['id'].toString());
      await PrintService.printPurchaseOrder(order: order, items: lines);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Purchase order preview opened.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'PO preview: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _savePo(Map<String, Object?> order) async {
    try {
      final lines =
          await AppDatabase.instance.purchaseOrderItems(order['id'].toString());
      final attachment = await PrintService.preparePurchaseOrderPdf(
          order: order, items: lines);
      final savedPath = await DocumentShareService.savePdfAs(attachment,
          suggestedFileName: 'PO_${order['no'] ?? 'order'}.pdf');
      if (savedPath != null && mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Purchase order PDF saved to $savedPath')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Save PO PDF: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _emailPo(Map<String, Object?> order) async {
    try {
      final lines =
          await AppDatabase.instance.purchaseOrderItems(order['id'].toString());
      final supplier = await _supplierForOrder(order);
      final email = (supplier['email'] ?? '').toString().trim();
      if (email.isEmpty)
        throw Exception('This supplier has no email address saved.');
      final settings = await AppDatabase.instance.settings();
      final attachment = await PrintService.preparePurchaseOrderPdf(
          order: order, items: lines);
      final businessName =
          (settings['business_name'] ?? 'RELIQ Solutions').trim();
      final currency = (settings['currency'] ?? 'KWD').trim();
      final decimals = int.tryParse(settings['currency_decimals'] ?? '3') ?? 3;
      final total = (order['ordered_total'] as num? ?? 0).toDouble();
      await DocumentShareService.openEmailDraftWithAttachment(
        recipient: email,
        subject: 'Purchase Order ${order['no'] ?? ''} - $businessName',
        body:
            'Hello ${supplier['name'] ?? 'Supplier'},\n\nPlease find purchase order ${order['no'] ?? ''} attached.\nOrder value: $currency ${total.toStringAsFixed(decimals)}\n\nKindly confirm availability and expected delivery date.\n\nRegards,\n$businessName',
        attachment: attachment,
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Supplier',
        partyId: supplier['id'].toString(),
        channel: 'Email',
        documentType: 'Purchase Order',
        documentId: order['id'].toString(),
        action: 'PDF prepared / opened',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Email draft opened and the PO PDF is ready in Finder/Explorer. Attach it, then send.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Email PO: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _whatsappPo(Map<String, Object?> order) async {
    try {
      final lines =
          await AppDatabase.instance.purchaseOrderItems(order['id'].toString());
      final supplier = await _supplierForOrder(order);
      final settings = await AppDatabase.instance.settings();
      final shareResult = await WhatsAppService.shareDocument(
        settings: settings,
        phone: (supplier['whatsapp'] ?? supplier['phone'] ?? '').toString(),
        message: WhatsAppService.purchaseOrderMessage(settings, order),
        prepareAttachment: () => PrintService.preparePurchaseOrderPdf(
          order: order,
          items: lines,
        ),
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Supplier',
        partyId: supplier['id'].toString(),
        channel: 'WhatsApp',
        documentType: 'Purchase Order',
        documentId: order['id'].toString(),
        action: shareResult.auditAction,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(shareResult.userMessage('Purchase order')),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'WhatsApp PO: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  Future<void> _changeStatus(Map<String, Object?> order, String next) async {
    try {
      await AppDatabase.instance
          .setPurchaseOrderStatus(order['id'].toString(), next);
      if (mounted) setState(() => refreshKey++);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
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
                    Text('Purchase Orders',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800)),
                    SizedBox(height: 3),
                    Text(
                        'Plan supplier orders, track incoming stock and receive partial deliveries.',
                        style: TextStyle(color: V3Style.muted)),
                  ]),
            ),
            FilledButton.icon(
                onPressed: _newOrder,
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('New Purchase Order')),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: '', child: Text('All statuses')),
                  DropdownMenuItem(value: 'Draft', child: Text('Draft')),
                  DropdownMenuItem(value: 'Ordered', child: Text('Ordered')),
                  DropdownMenuItem(
                      value: 'Partially Received',
                      child: Text('Partially Received')),
                  DropdownMenuItem(value: 'Received', child: Text('Received')),
                  DropdownMenuItem(
                      value: 'Cancelled', child: Text('Cancelled')),
                ],
                onChanged: (v) => setState(() => status = v ?? ''),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
              key: ValueKey('$refreshKey-$status'),
              future: AppDatabase.instance.purchaseOrders(status: status),
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Center(child: Text('${snapshot.error}'));
                if (!snapshot.hasData)
                  return const ReliqLoadingState(
                      message: 'Loading purchase orders…',
                      detail:
                          'RELIQ is checking supplier orders and incoming quantities.');
                final rows = snapshot.data!;
                if (rows.isEmpty)
                  return const Center(child: Text('No purchase orders found.'));
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final st = '${r['status'] ?? ''}';
                    final incoming =
                        (r['incoming_qty'] as num? ?? 0).toDouble();
                    final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          CircleAvatar(
                              child: Icon(
                                  st == 'Received'
                                      ? Icons.check
                                      : Icons.local_shipping_outlined,
                                  size: 18)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${r['no']} • ${r['supplier_name'] ?? 'Supplier'}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 4),
                                  Text(
                                      '${dt == null ? '—' : DateFormat('dd MMM yyyy').format(dt.toLocal())} • ${r['line_count'] ?? 0} lines • Incoming ${incoming.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                          color: V3Style.muted)),
                                  if ((r['expected_date'] ?? '')
                                      .toString()
                                      .isNotEmpty)
                                    Text('Expected ${r['expected_date']}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: V3Style.muted)),
                                ]),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: Theme.of(context).dividerColor)),
                            child: Text(st,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12)),
                          ),
                          const SizedBox(width: 4),
                          PopupMenuButton<String>(
                            tooltip: 'Document actions',
                            icon: const Icon(Icons.share_outlined),
                            onSelected: (value) {
                              if (value == 'preview') _previewPo(r);
                              if (value == 'save') _savePo(r);
                              if (value == 'whatsapp') _whatsappPo(r);
                              if (value == 'email') _emailPo(r);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                  value: 'preview',
                                  child: ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.preview_outlined),
                                      title: Text('Preview / Print'))),
                              PopupMenuItem(
                                  value: 'save',
                                  child: ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.download_outlined),
                                      title: Text('Save PDF'))),
                              PopupMenuItem(
                                  value: 'whatsapp',
                                  child: ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.chat_outlined),
                                      title: Text('WhatsApp'))),
                              PopupMenuItem(
                                  value: 'email',
                                  child: ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.email_outlined),
                                      title: Text('Email PDF'))),
                            ],
                          ),
                          const SizedBox(width: 4),
                          if (st == 'Draft')
                            TextButton(
                                onPressed: () => _changeStatus(r, 'Ordered'),
                                child: const Text('Place Order')),
                          if (st == 'Ordered' || st == 'Partially Received')
                            FilledButton.tonalIcon(
                                onPressed: () => _receive(r),
                                icon: const Icon(Icons.download, size: 17),
                                label: const Text('Receive')),
                          if (st == 'Draft' || st == 'Ordered')
                            IconButton(
                                onPressed: () => _changeStatus(r, 'Cancelled'),
                                icon: const Icon(Icons.cancel_outlined),
                                tooltip: 'Cancel order'),
                        ]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      );
}

class _PurchaseOrderDialog extends StatefulWidget {
  const _PurchaseOrderDialog();

  @override
  State<_PurchaseOrderDialog> createState() => _PurchaseOrderDialogState();
}

class _PurchaseOrderDialogState extends State<_PurchaseOrderDialog> {
  String supplierId = '';
  String search = '';
  String expectedDate = '';
  String notes = '';
  bool placeOrder = true;
  final lines = <Map<String, Object?>>[];

  void _add(Map<String, Object?> p) {
    final id = p['id'].toString();
    final index = lines.indexWhere((x) => x['id'] == id);
    if (index >= 0) {
      setState(() =>
          lines[index]['qty'] = (lines[index]['qty'] as num).toDouble() + 1);
      return;
    }
    final moq = (p['purchase_moq'] as num? ?? 0).toDouble();
    final multiple = (p['order_multiple'] as num? ?? 1).toDouble();
    final initial = moq > 0 ? moq : (multiple > 1 ? multiple : 1.0);
    setState(() => lines.add({
          'id': id,
          'name': p['name'],
          'sku': p['sku'],
          'unit': p['unit'],
          'qty': initial,
          'unit_cost': (p['cost'] as num? ?? 0).toDouble(),
          'purchase_moq': moq,
          'order_multiple': multiple,
          'case_pack': (p['case_pack'] as num? ?? 1).toDouble(),
        }));
  }

  Future<void> _save() async {
    try {
      final no = await AppDatabase.instance.createPurchaseOrder(
        supplierId: supplierId,
        items: lines,
        expectedDate: expectedDate,
        notes: notes,
        placeOrder: placeOrder,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Purchase order $no created.')));
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
          height: 760,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                    child: Text('New Purchase Order',
                        style: TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w800))),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 14),
              FutureBuilder<List<Map<String, Object?>>>(
                future: AppDatabase.instance
                    .suppliers(activeOnly: true, limit: 10000),
                builder: (context, snap) => SearchableMapSelect(
                  options: snap.data ?? const <Map<String, Object?>>[],
                  value: supplierId.isEmpty ? null : supplierId,
                  labelText: 'Supplier',
                  hintText: 'Type name, phone or email...',
                  display: (s) => '${s['name']}',
                  subtitle: (s) => [
                    if ('${s['phone'] ?? ''}'.trim().isNotEmpty)
                      '${s['phone']}',
                    if ('${s['email'] ?? ''}'.trim().isNotEmpty)
                      '${s['email']}',
                  ].join(' • '),
                  onChanged: (v) => setState(() => supplierId = v ?? ''),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextField(
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'Search products to order'),
                        onChanged: (v) => setState(() => search = v))),
                const SizedBox(width: 10),
                SizedBox(
                    width: 220,
                    child: TextFormField(
                        key: ValueKey(expectedDate),
                        initialValue: expectedDate,
                        decoration: const InputDecoration(
                            labelText: 'Expected date', hintText: 'YYYY-MM-DD'),
                        onChanged: (v) => expectedDate = v)),
                const SizedBox(width: 6),
                IconButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                          context: context,
                          firstDate: DateTime.now(),
                          lastDate:
                              DateTime.now().add(const Duration(days: 1460)),
                          initialDate:
                              DateTime.now().add(const Duration(days: 7)));
                      if (picked != null && mounted)
                        setState(() => expectedDate =
                            '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                    },
                    icon: const Icon(Icons.calendar_month_outlined)),
              ]),
              if (search.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 135,
                  child: FutureBuilder<List<Map<String, Object?>>>(
                    future: AppDatabase.instance
                        .products(search: search, activeOnly: true),
                    builder: (context, snap) {
                      final rows = (snap.data ?? []).take(8).toList();
                      return ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final p = rows[i];
                          return ListTile(
                            dense: true,
                            title: Text('${p['name']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                                '${p['sku'] ?? '—'} • Cost ${(p['cost'] as num? ?? 0).toStringAsFixed(3)}'),
                            trailing: IconButton(
                                onPressed: () => _add(p),
                                icon: const Icon(Icons.add_circle_outline)),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: Card(
                  child: lines.isEmpty
                      ? const Center(
                          child: Text('Add products to the purchase order.'))
                      : ListView.separated(
                          itemCount: lines.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final x = lines[i];
                            return ListTile(
                              title: Text('${x['name']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              subtitle: Text(
                                  'MOQ ${(x['purchase_moq'] as num).toStringAsFixed(2)} • Order multiple ${(x['order_multiple'] as num).toStringAsFixed(2)} • Case ${(x['case_pack'] as num).toStringAsFixed(2)}'),
                              trailing: SizedBox(
                                  width: 310,
                                  child: Row(children: [
                                    Expanded(
                                        child: TextFormField(
                                            initialValue: '${x['qty']}',
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: const InputDecoration(
                                                labelText: 'Qty'),
                                            onChanged: (v) => x['qty'] =
                                                double.tryParse(v) ?? 0)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: TextFormField(
                                            initialValue: '${x['unit_cost']}',
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: const InputDecoration(
                                                labelText: 'Cost'),
                                            onChanged: (v) => x['unit_cost'] =
                                                double.tryParse(v) ?? 0)),
                                    IconButton(
                                        onPressed: () =>
                                            setState(() => lines.removeAt(i)),
                                        icon: const Icon(Icons.delete_outline)),
                                  ])),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'Notes'),
                  onChanged: (v) => notes = v),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Place order now'),
                  subtitle: const Text('Turn off to save as Draft.'),
                  value: placeOrder,
                  onChanged: (v) => setState(() => placeOrder = v)),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed:
                        supplierId.isEmpty || lines.isEmpty ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(
                        placeOrder ? 'Create & Place Order' : 'Save Draft')),
              ]),
            ]),
          ),
        ),
      );
}

class _ReceivePurchaseOrderDialog extends StatefulWidget {
  final Map<String, Object?> order;
  final List<Map<String, Object?>> lines;
  const _ReceivePurchaseOrderDialog({required this.order, required this.lines});

  @override
  State<_ReceivePurchaseOrderDialog> createState() =>
      _ReceivePurchaseOrderDialogState();
}

class _ReceivePurchaseOrderDialogState
    extends State<_ReceivePurchaseOrderDialog> {
  late final List<Map<String, Object?>> lines;
  String documentNo = '';
  String notes = '';
  String paymentMethod = 'Cash';
  double freight = 0;
  double other = 0;
  double paid = 0;

  @override
  void initState() {
    super.initState();
    lines = widget.lines
        .map((x) => {
              ...x,
              'receive_qty': 0.0,
              'receive_batch': x['batch_no'] ?? '',
              'receive_expiry': x['expiry_date']
            })
        .toList();
  }

  Future<void> _save() async {
    try {
      final no = await AppDatabase.instance.receivePurchaseOrder(
        purchaseOrderId: widget.order['id'].toString(),
        items: [
          for (final x in lines)
            {
              'purchase_order_item_id': x['id'],
              'qty': x['receive_qty'],
              'unit_cost': x['unit_cost'],
              'batch_no': x['receive_batch'],
              'expiry_date': x['receive_expiry'],
            }
        ],
        supplierDocumentNo: documentNo,
        freight: freight,
        otherCharges: other,
        paid: paid,
        paymentMethod: paymentMethod,
        notes: notes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Purchase $no received from ${widget.order['no']}.')));
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
                Expanded(
                    child: Text('Receive ${widget.order['no']}',
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w800))),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 10),
              Expanded(
                  child: Card(
                      child: ListView.separated(
                itemCount: lines.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final x = lines[i];
                  final remaining =
                      (x['remaining_qty'] as num? ?? 0).toDouble();
                  final batch = (x['track_batch'] as num? ?? 0).toInt() == 1;
                  final expiry = (x['track_expiry'] as num? ?? 0).toInt() == 1;
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      Expanded(
                          flex: 3,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${x['name']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                Text(
                                    '${x['sku'] ?? '—'} • Remaining ${remaining.toStringAsFixed(2)} ${x['unit'] ?? ''}',
                                    style: const TextStyle(
                                        fontSize: 12, color: V3Style.muted)),
                              ])),
                      SizedBox(
                          width: 120,
                          child: TextFormField(
                              initialValue: '0',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration:
                                  const InputDecoration(labelText: 'Receive'),
                              onChanged: (v) =>
                                  x['receive_qty'] = double.tryParse(v) ?? 0)),
                      if (batch) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                            width: 150,
                            child: TextFormField(
                                initialValue: '${x['receive_batch'] ?? ''}',
                                decoration: const InputDecoration(
                                    labelText: 'Batch / lot'),
                                onChanged: (v) => x['receive_batch'] = v)),
                      ],
                      if (expiry) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                            width: 150,
                            child: TextFormField(
                                initialValue: '${x['receive_expiry'] ?? ''}',
                                decoration:
                                    const InputDecoration(labelText: 'Expiry'),
                                onChanged: (v) => x['receive_expiry'] = v)),
                      ],
                    ]),
                  );
                },
              ))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(
                            labelText: 'Supplier document no.'),
                        onChanged: (v) => documentNo = v)),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(labelText: 'Freight'),
                        onChanged: (v) => freight = double.tryParse(v) ?? 0)),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Other charges'),
                        onChanged: (v) => other = double.tryParse(v) ?? 0)),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Paid now'),
                        onChanged: (v) => paid = double.tryParse(v) ?? 0)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                        value: paymentMethod,
                        decoration:
                            const InputDecoration(labelText: 'Payment method'),
                        items: const ['Cash', 'Card', 'Bank Transfer', 'Credit']
                            .map((x) =>
                                DropdownMenuItem(value: x, child: Text(x)))
                            .toList(),
                        onChanged: (v) => paymentMethod = v ?? 'Cash')),
                const SizedBox(width: 8),
                Expanded(
                    child: TextFormField(
                        decoration:
                            const InputDecoration(labelText: 'Receiving notes'),
                        onChanged: (v) => notes = v)),
                const SizedBox(width: 12),
                FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.download),
                    label: const Text('Receive Selected')),
              ]),
            ]),
          ),
        ),
      );
}
