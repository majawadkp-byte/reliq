import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/print_service.dart';
import '../services/whatsapp_service.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_loading.dart';
import '../ui/reliq_surface.dart';
import 'party_ledger_detail_screen.dart';

class SuppliersScreen extends StatefulWidget {
  final FocusNode? searchFocusNode;
  final String initialSearch;
  final String initialEntityId;
  final int lookupRevision;
  const SuppliersScreen({super.key, this.searchFocusNode, this.initialSearch = '', this.initialEntityId = '', this.lookupRevision = 0});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  String query = '';
  late final FocusNode searchFocus;
  late final bool _ownsSearchFocus;
  final searchController = TextEditingController();
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  late Future<List<Map<String, Object?>>> _listFuture;
  String _autoOpenedEntityKey = '';
  Map<String, Object?>? _openSupplier;

  @override
  void initState() {
    super.initState();
    _ownsSearchFocus = widget.searchFocusNode == null;
    searchFocus = widget.searchFocusNode ?? FocusNode();
    _applyInitialLookup(initial: true);
  }

  void _applyInitialLookup({bool initial = false}) {
    final display = widget.initialSearch.trim();
    final entityId = widget.initialEntityId.trim();
    searchController.text = display;
    query = entityId.isNotEmpty ? entityId : display;
    _listFuture = AppDatabase.instance.suppliers(search: query);
    if (entityId.isNotEmpty) _scheduleInitialLedgerOpen(entityId);
    if (!initial && mounted) setState(() {});
  }

  void _scheduleInitialLedgerOpen(String entityId) {
    final key = '${widget.lookupRevision}:$entityId';
    if (_autoOpenedEntityKey == key) return;
    _autoOpenedEntityKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final rows = await AppDatabase.instance.suppliers(search: entityId, limit: 5);
      if (!mounted) return;
      final exact = rows.where((row) => (row['id'] ?? '').toString() == entityId).toList();
      if (exact.isEmpty) return;
      await openLedger(exact.first);
    });
  }

  @override
  void didUpdateWidget(covariant SuppliersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lookupRevision != widget.lookupRevision ||
        oldWidget.initialEntityId != widget.initialEntityId ||
        oldWidget.initialSearch != widget.initialSearch) {
      _searchDebounce?.cancel();
      _searchGeneration++;
      _applyInitialLookup();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.initialSearch.isNotEmpty) searchFocus.requestFocus();
      });
    }
  }

  void _reload() {
    _searchDebounce?.cancel();
    setState(() => _listFuture = AppDatabase.instance.suppliers(search: query));
  }

  void _onSearchChanged(String value) {
    query = value.trim();
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _listFuture = AppDatabase.instance.suppliers(search: query));
    });
  }

  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    query = value.trim();
    _searchGeneration++;
    if (mounted) setState(() => _listFuture = AppDatabase.instance.suppliers(search: query));
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchGeneration++;
    searchController.clear();
    query = '';
    if (mounted) setState(() => _listFuture = AppDatabase.instance.suppliers());
    searchFocus.requestFocus();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchController.dispose();
    if (_ownsSearchFocus) searchFocus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
    const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => edit(),
    const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => edit(),
  };

  Future<void> edit([Map<String, Object?>? supplier]) async {
    String name = '${supplier?['name'] ?? ''}';
    String phone = '${supplier?['phone'] ?? ''}';
    String whatsapp = '${supplier?['whatsapp'] ?? supplier?['phone'] ?? ''}';
    String email = '${supplier?['email'] ?? ''}';
    String address = '${supplier?['address'] ?? ''}';
    String lead = '${supplier?['lead_days'] ?? 0}';
    String terms = '${supplier?['terms_days'] ?? 0}';
    String minOrder = '${supplier?['min_order_value'] ?? 0}';
    bool active = ((supplier?['active'] as num?) ?? 1).toInt() == 1;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(supplier == null ? 'Add Supplier' : 'Edit Supplier'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextFormField(initialValue: name, onChanged: (v) => name = v, decoration: const InputDecoration(labelText: 'Supplier name')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: TextFormField(initialValue: phone, onChanged: (v) => phone = v, decoration: const InputDecoration(labelText: 'Phone'))),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(initialValue: email, onChanged: (v) => email = v, decoration: const InputDecoration(labelText: 'Email'))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(initialValue: whatsapp, onChanged: (v) => whatsapp = v, decoration: const InputDecoration(labelText: 'WhatsApp number', hintText: 'Leave same as phone if applicable')),
                  const SizedBox(height: 10),
                  TextFormField(initialValue: address, onChanged: (v) => address = v, decoration: const InputDecoration(labelText: 'Address')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: TextFormField(initialValue: lead, onChanged: (v) => lead = v, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Lead time (days)'))),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(initialValue: terms, onChanged: (v) => terms = v, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Payment terms (days)'))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: minOrder,
                    onChanged: (v) => minOrder = v,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Minimum supplier order value'),
                  ),
                  SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active'), value: active, onChanged: (v) => setD(() => active = v)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (ok == true && name.trim().isNotEmpty) {
      await AppDatabase.instance.saveSupplier(
        {
          'name': name.trim(),
          'phone': phone.trim(),
          'whatsapp': whatsapp.trim(),
          'email': email.trim(),
          'address': address.trim(),
          'lead_days': int.tryParse(lead) ?? 0,
          'terms_days': int.tryParse(terms) ?? 0,
          'min_order_value': (double.tryParse(minOrder) ?? 0).clamp(0, double.infinity),
          'active': active ? 1 : 0,
        },
        id: supplier?['id'] as String?,
      );
      if (mounted) {
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Supplier changes saved')));
      }
    }
  }

  Future<void> previewStatement(Map<String,Object?> supplier) async {
    try {
      final rows = await AppDatabase.instance.supplierStatement(supplier['id'].toString());
      await PrintService.printSupplierStatement(supplier: supplier, rows: rows);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Supplier statement: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> openLedger(Map<String, Object?> supplier) async {
    if (!mounted) return;
    setState(() => _openSupplier = Map<String, Object?>.from(supplier));
  }

  void _closeLedger() {
    if (!mounted) return;
    setState(() => _openSupplier = null);
    _reload();
  }

  Widget _ledgerView(Map<String, Object?> supplier) => PartyLedgerDetailScreen(
        partyType: 'Supplier',
        partyId: supplier['id'].toString(),
        initialName: (supplier['name'] ?? '').toString(),
        onBack: _closeLedger,
        actionsBuilder: (current) => [
          PartyLedgerAction(label: 'Pay Supplier', icon: Icons.payments_outlined, primary: true, onPressed: () => makePayment(current)),
          PartyLedgerAction(label: 'Edit Supplier', icon: Icons.edit_outlined, onPressed: () => edit(current)),
          PartyLedgerAction(label: 'Preview Statement', icon: Icons.description_outlined, onPressed: () => previewStatement(current)),
          PartyLedgerAction(label: 'WhatsApp Supplier', icon: Icons.chat_outlined, onPressed: () => whatsappSupplier(current)),
          PartyLedgerAction(label: 'Communications', icon: Icons.history_outlined, onPressed: () => communicationHistory(current)),
        ],
      );

  Future<void> whatsappSupplier(Map<String,Object?> supplier) async {
    try {
      final settings=await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone:(supplier['whatsapp']??supplier['phone']??'').toString(),
        message:'Hello ${supplier['name']}, this is ${settings['business_name']??'RELIQ Solutions'}.',
        defaultCountryCode:settings['whatsapp_country_code']??'',
      );
      await AppDatabase.instance.logCommunication(
        partyType:'Supplier',
        partyId:supplier['id'].toString(),
        channel:'WhatsApp',
        documentType:'Supplier Message',
        documentId:supplier['id'].toString(),
        action:'Prepared / opened',
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp opened for supplier.')));
    } catch(e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('WhatsApp: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }
  Future<void> communicationHistory(Map<String,Object?> supplier) async { final rows=await AppDatabase.instance.communicationHistory('Supplier',supplier['id'].toString()); if(!mounted)return; await showDialog(context:context,builder:(ctx)=>AlertDialog(title:Text('Communication • ${supplier['name']}'),content:SizedBox(width:650,height:430,child:rows.isEmpty?const Center(child:Text('No communication actions recorded yet.')):ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const Divider(height:1),itemBuilder:(_,i){final r=rows[i];final dt=DateTime.tryParse('${r['created_at']??''}');return ListTile(dense:true,leading:Icon(r['channel']=='WhatsApp'?Icons.chat_outlined:Icons.mail_outline),title:Text('${r['document_type']} • ${r['action']}',style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${r['channel']}${dt==null?'':' • ${dt.toLocal().toString().substring(0,16)}'}'));})),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))])); }

  Future<void> makePayment(Map<String, Object?> supplier) async {
    final docs = await AppDatabase.instance.openSupplierBills(supplier['id'].toString());
    if (!mounted) return;

    String amountText = (supplier['balance'] as num? ?? 0).toDouble().toStringAsFixed(3);
    String method = 'Cash';
    String reference = '';
    final allocations = <String, double>{};

    void autoAllocate() {
      allocations.clear();
      var remaining = double.tryParse(amountText) ?? 0;
      for (final d in docs) {
        if (remaining <= 0) break;
        final balance = (d['balance'] as num? ?? 0).toDouble();
        final allocation = remaining < balance ? remaining : balance;
        allocations[d['id'].toString()] = allocation;
        remaining -= allocation;
      }
    }

    autoAllocate();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final entered = double.tryParse(amountText) ?? 0;
          final applied = allocations.values.fold<double>(0, (a, b) => a + b);
          final advance = (entered - applied).clamp(0, double.infinity).toDouble();

          return AlertDialog(
            title: Text('Pay Supplier • ${supplier['name']}'),
            content: SizedBox(
              width: 720,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 190,
                        child: TextFormField(
                          initialValue: amountText,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Payment amount'),
                          onChanged: (v) => setD(() {
                            amountText = v;
                            autoAllocate();
                          }),
                        ),
                      ),
                      SizedBox(
                        width: 170,
                        child: DropdownButtonFormField<String>(
                          value: method,
                          decoration: const InputDecoration(labelText: 'Method'),
                          items: const ['Cash', 'Card', 'Bank', 'Cheque', 'Other']
                              .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                              .toList(),
                          onChanged: (v) => setD(() => method = v ?? 'Cash'),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: TextFormField(
                          initialValue: reference,
                          onChanged: (v) => reference = v,
                          decoration: const InputDecoration(labelText: 'Reference / voucher no.'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Allocate to supplier bills', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Oldest bills are proposed first. You can override the allocation.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final d = docs[i];
                        final id = d['id'].toString();
                        final balance = (d['balance'] as num? ?? 0).toDouble();
                        final documentNo = (d['document_no'] ?? '').toString();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${d['no']}${documentNo.isEmpty ? '' : ' • $documentNo'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('Balance ${balance.toStringAsFixed(3)}${d['due_date'] == null ? '' : ' • Due ${d['due_date'].toString().split('T').first}'}'),
                          trailing: SizedBox(
                            width: 150,
                            child: TextFormField(
                              key: ValueKey('$id-${allocations[id] ?? 0}'),
                              initialValue: (allocations[id] ?? 0).toStringAsFixed(3),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(labelText: 'Apply'),
                              onChanged: (v) {
                                allocations[id] = (double.tryParse(v) ?? 0).clamp(0, balance).toDouble();
                                setD(() {});
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Text(
                    'Applied ${applied.toStringAsFixed(3)}${advance > 0 ? ' • Supplier advance ${advance.toStringAsFixed(3)}' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton.icon(
                onPressed: entered > 0 ? () => Navigator.pop(ctx, true) : null,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Post Payment'),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {
      try {
        final entered = double.tryParse(amountText) ?? 0;
        final requestedTotal = allocations.values.fold<double>(0, (a, b) => a + b);
        if (requestedTotal > entered + 0.000001) throw Exception('Allocated amount cannot exceed the supplier payment.');
        final paymentId = await AppDatabase.instance.paySupplier(
          supplierId: supplier['id'].toString(),
          amount: entered,
          method: method,
          reference: reference.trim(),
          allocations: allocations,
        );
        final voucherAllocations = <Map<String, Object?>>[];
        for (final d in docs) {
          final a = allocations[d['id'].toString()] ?? 0;
          if (a > 0) voucherAllocations.add({'document_id': d['id'], 'document_no': (d['document_no'] ?? '').toString().isEmpty ? d['no'] : '${d['no']} • ${d['document_no']}', 'amount': a});
        }
        final advance = (entered - requestedTotal).clamp(0, double.infinity).toDouble();
        final printSettings = await AppDatabase.instance.settings();
        final printAction = PrintService.actionFromSetting(printSettings['supplier_payment_print_action']);
        if (printAction != ReliqPrintAction.none) {
          try {
            await PrintService.printPaymentReceipt(
              paymentId: paymentId, partyType: 'Supplier', partyName: '${supplier['name']}',
              amount: entered, method: method, reference: reference.trim(), allocations: voucherAllocations,
              accountCredit: advance, action: printAction, printerName: printSettings['supplier_payment_printer'] ?? '',
            );
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Supplier payment saved, but document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }
        if (mounted) {
          _reload();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(printAction == ReliqPrintAction.direct ? 'Supplier payment saved and sent to printer' : printAction == ReliqPrintAction.preview ? 'Supplier payment saved. Preview opened' : 'Supplier payment saved and allocated'),
            action: printAction == ReliqPrintAction.none ? SnackBarAction(label: 'PRINT', onPressed: () { PrintService.printPaymentReceipt(paymentId: paymentId, partyType: 'Supplier', partyName: '${supplier['name']}', amount: entered, method: method, reference: reference.trim(), allocations: voucherAllocations, accountCredit: advance); }) : null,
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _openSupplier;
    if (selected != null) return _ledgerView(selected);
    return CallbackShortcuts(
        bindings: _shortcutBindings(),
        child: Focus(
          autofocus: true,
          child: Padding(
            padding: V3Style.pagePadding,
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Suppliers', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800))),
                FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add_business), label: const Text('Add Supplier')),
              ],
            ),
            const SizedBox(height: 16),
            ReliqGlass(
              blur: 14,
              radius: 14,
              padding: EdgeInsets.zero,
              child: TextField(
                controller: searchController,
                focusNode: searchFocus,
                onChanged: _onSearchChanged,
                onSubmitted: _submitSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search supplier, phone, WhatsApp, email or address',
                  suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Clear search', onPressed: _clearSearch, icon: const Icon(Icons.close)),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
                future: _listFuture,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return Center(child: Text('Could not load suppliers: ${snapshot.error}'));
                  if (!snapshot.hasData) return const ReliqLoadingState(message: 'Loading suppliers…', detail: 'RELIQ is reading account balances and contact details.');
                  final rows = snapshot.data!;
                  if (rows.isEmpty) return const Center(child: Text('No suppliers yet.'));
                  return Card(
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = rows[i];
                        final balance = (s['balance'] as num? ?? 0).toDouble();
                        final overdue = (s['overdue_balance'] as num? ?? 0).toDouble();
                        final credit = (s['credit_balance'] as num? ?? 0).toDouble();
                        return ListTile(
                          onTap: () => openLedger(s),
                          leading: Icon(((s['active'] as num?) ?? 1).toInt() == 1 ? Icons.local_shipping_outlined : Icons.visibility_off_outlined),
                          title: Text('${s['name']}'),
                          subtitle: Text(
                            '${s['phone'] ?? ''}${('${s['email'] ?? ''}').isNotEmpty ? ' • ${s['email']}' : ''} • Lead ${s['lead_days'] ?? 0}d • Terms ${s['terms_days'] ?? 0}d${overdue > 0 ? ' • OVERDUE ${overdue.toStringAsFixed(3)}' : ''}${credit > 0 ? ' • ADVANCE ${credit.toStringAsFixed(3)}' : ''}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Text('Payable'),
                                  Text(balance.toStringAsFixed(3), style: TextStyle(fontWeight: FontWeight.w700, color: balance > 0 ? Theme.of(context).colorScheme.error : null)),
                                ],
                              ),
                              const SizedBox(width: 8),
                              IconButton(tooltip: 'Edit supplier', onPressed: () => edit(s), icon: const Icon(Icons.edit_outlined)),
                              const SizedBox(width: 2),
                              FilledButton.icon(onPressed: () => makePayment(s), icon: const Icon(Icons.payments_outlined), label: const Text('Pay Supplier')),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
            ),
          ),
        ),
      );
  }
}
