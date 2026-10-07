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

class CustomersScreen extends StatefulWidget {
  final FocusNode? searchFocusNode;
  final String initialSearch;
  final String initialEntityId;
  final int lookupRevision;
  const CustomersScreen({super.key, this.searchFocusNode, this.initialSearch = '', this.initialEntityId = '', this.lookupRevision = 0});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String query = '';
  late final FocusNode searchFocus;
  late final bool _ownsSearchFocus;
  final searchController = TextEditingController();
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  late Future<List<Map<String, Object?>>> _listFuture;
  String _autoOpenedEntityKey = '';
  Map<String, Object?>? _openCustomer;

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
    _listFuture = AppDatabase.instance.customers(search: query);
    if (entityId.isNotEmpty) _scheduleInitialLedgerOpen(entityId);
    if (!initial && mounted) setState(() {});
  }

  void _scheduleInitialLedgerOpen(String entityId) {
    final key = '${widget.lookupRevision}:$entityId';
    if (_autoOpenedEntityKey == key) return;
    _autoOpenedEntityKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final rows = await AppDatabase.instance.customers(search: entityId, limit: 5);
      if (!mounted) return;
      final exact = rows.where((row) => (row['id'] ?? '').toString() == entityId).toList();
      if (exact.isEmpty) return;
      await openLedger(exact.first);
    });
  }

  @override
  void didUpdateWidget(covariant CustomersScreen oldWidget) {
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
    setState(() => _listFuture = AppDatabase.instance.customers(search: query));
  }

  void _onSearchChanged(String value) {
    query = value.trim();
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _listFuture = AppDatabase.instance.customers(search: query));
    });
  }

  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    query = value.trim();
    _searchGeneration++;
    if (mounted) setState(() => _listFuture = AppDatabase.instance.customers(search: query));
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchGeneration++;
    searchController.clear();
    query = '';
    if (mounted) setState(() => _listFuture = AppDatabase.instance.customers());
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

  Future<void> edit([Map<String, Object?>? customer]) async {
    String name = '${customer?['name'] ?? ''}';
    String phone = '${customer?['phone'] ?? ''}';
    String email = '${customer?['email'] ?? ''}';
    String whatsapp = '${customer?['whatsapp'] ?? customer?['phone'] ?? ''}';
    String preferredDelivery = '${customer?['preferred_delivery'] ?? 'WhatsApp'}';
    String address = '${customer?['address'] ?? ''}';
    String limit = '${customer?['credit_limit'] ?? 0}';
    String terms = '${customer?['terms_days'] ?? 0}';
    String groupId = '${customer?['group_id'] ?? ''}';
    bool active = ((customer?['active'] as num?) ?? 1).toInt() == 1;
    bool creditAllowed = ((customer?['credit_allowed'] as num?) ?? 0).toInt() == 1;

    final groups = await AppDatabase.instance.customerGroups(activeOnly: true);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(customer == null ? 'Add Customer' : 'Edit Customer'),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextFormField(
                    initialValue: name,
                    onChanged: (v) => name = v,
                    decoration: const InputDecoration(labelText: 'Customer name'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: phone,
                          onChanged: (v) => phone = v,
                          decoration: const InputDecoration(labelText: 'Phone'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          initialValue: email,
                          onChanged: (v) => email = v,
                          decoration: const InputDecoration(labelText: 'Email'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(children:[
                    Expanded(child:TextFormField(initialValue:whatsapp,onChanged:(v)=>whatsapp=v,decoration:const InputDecoration(labelText:'WhatsApp number',hintText:'Leave same as phone if applicable'))),
                    const SizedBox(width:10),
                    Expanded(child:DropdownButtonFormField<String>(value:['WhatsApp','Email','Print','WhatsApp + Email'].contains(preferredDelivery)?preferredDelivery:'WhatsApp',decoration:const InputDecoration(labelText:'Preferred document delivery'),items:const ['WhatsApp','Email','Print','WhatsApp + Email'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setD(()=>preferredDelivery=v??'WhatsApp'))),
                  ]),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: address,
                    onChanged: (v) => address = v,
                    decoration: const InputDecoration(labelText: 'Address'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: groups.any((g) => g['id'] == groupId) ? groupId : '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Customer group / pricing cluster'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('No group / standard pricing')),
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
                    onChanged: (v) => setD(() => groupId = v ?? ''),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow credit sales'),
                    value: creditAllowed,
                    onChanged: (v) => setD(() => creditAllowed = v),
                  ),
                  if (creditAllowed)
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: limit,
                            onChanged: (v) => limit = v,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Credit limit (0 = unlimited)'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            initialValue: terms,
                            onChanged: (v) => terms = v,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Terms (days)'),
                          ),
                        ),
                      ],
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => setD(() => active = v),
                  ),
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
      await AppDatabase.instance.saveCustomer(
        {
          'name': name.trim(),
          'phone': phone.trim(),
          'email': email.trim(),
          'whatsapp': whatsapp.trim(),
          'preferred_delivery': preferredDelivery,
          'address': address.trim(),
          'credit_allowed': creditAllowed ? 1 : 0,
          'credit_limit': double.tryParse(limit) ?? 0,
          'terms_days': int.tryParse(terms) ?? 0,
          'group_id': groupId.isEmpty ? null : groupId,
          'active': active ? 1 : 0,
        },
        id: customer?['id'] as String?,
      );
      if (mounted) {
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer changes saved')));
      }
    }
  }

  Future<void> receivePayment(Map<String, Object?> customer) async {
    final docs = await AppDatabase.instance.openCustomerInvoices(customer['id'].toString());
    if (!mounted) return;

    String amountText = (customer['balance'] as num? ?? 0).toDouble().toStringAsFixed(3);
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
          final credit = (entered - applied).clamp(0, double.infinity).toDouble();

          return AlertDialog(
            title: Text('Receive Payment • ${customer['name']}'),
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
                          decoration: const InputDecoration(labelText: 'Amount received'),
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
                          decoration: const InputDecoration(labelText: 'Reference / receipt no.'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Allocate to invoices', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('RELIQ allocates oldest bills first. Override any row before posting.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final d = docs[i];
                        final id = d['id'].toString();
                        final balance = (d['balance'] as num? ?? 0).toDouble();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${d['no']}', style: const TextStyle(fontWeight: FontWeight.w700)),
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
                    'Applied ${applied.toStringAsFixed(3)}${credit > 0 ? ' • Unallocated credit ${credit.toStringAsFixed(3)}' : ''}',
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
                label: const Text('Post Receipt'),
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
        if (requestedTotal > entered + 0.000001) throw Exception('Allocated amount cannot exceed the payment received.');
        final paymentId = await AppDatabase.instance.receiveCustomerPayment(
          customerId: customer['id'].toString(),
          amount: entered,
          method: method,
          reference: reference.trim(),
          allocations: allocations,
        );
        final receiptAllocations = <Map<String, Object?>>[];
        for (final d in docs) {
          final a = allocations[d['id'].toString()] ?? 0;
          if (a > 0) receiptAllocations.add({'document_id': d['id'], 'document_no': d['no'], 'amount': a});
        }
        final credit = (entered - requestedTotal).clamp(0, double.infinity).toDouble();
        final printSettings = await AppDatabase.instance.settings();
        final printAction = PrintService.actionFromSetting(printSettings['customer_receipt_print_action']);
        if (printAction != ReliqPrintAction.none) {
          try {
            await PrintService.printPaymentReceipt(
              paymentId: paymentId, partyType: 'Customer', partyName: '${customer['name']}',
              amount: entered, method: method, reference: reference.trim(), allocations: receiptAllocations,
              accountCredit: credit, action: printAction, printerName: printSettings['customer_receipt_printer'] ?? '',
            );
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Receipt saved, but document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }
        if (mounted) {
          _reload();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(printAction == ReliqPrintAction.direct ? 'Customer receipt saved and sent to printer' : printAction == ReliqPrintAction.preview ? 'Customer receipt saved. Preview opened' : 'Customer receipt saved and allocated'),
            action: printAction == ReliqPrintAction.none ? SnackBarAction(label: 'PRINT', onPressed: () { PrintService.printPaymentReceipt(paymentId: paymentId, partyType: 'Customer', partyName: '${customer['name']}', amount: entered, method: method, reference: reference.trim(), allocations: receiptAllocations, accountCredit: credit); }) : null,
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
        }
      }
    }
  }

  Future<void> previewStatement(Map<String,Object?> customer) async {
    try {
      final rows = await AppDatabase.instance.customerStatement(customer['id'].toString());
      await PrintService.printCustomerStatement(customer: customer, rows: rows);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Customer statement: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> openLedger(Map<String, Object?> customer) async {
    if (!mounted) return;
    setState(() => _openCustomer = Map<String, Object?>.from(customer));
  }

  void _closeLedger() {
    if (!mounted) return;
    setState(() => _openCustomer = null);
    _reload();
  }

  Widget _ledgerView(Map<String, Object?> customer) => PartyLedgerDetailScreen(
        partyType: 'Customer',
        partyId: customer['id'].toString(),
        initialName: (customer['name'] ?? '').toString(),
        onBack: _closeLedger,
        actionsBuilder: (current) {
          final balance = (current['balance'] as num? ?? 0).toDouble();
          return [
            PartyLedgerAction(label: 'Receive Payment', icon: Icons.payments_outlined, primary: true, onPressed: () => receivePayment(current)),
            PartyLedgerAction(label: 'Edit Customer', icon: Icons.edit_outlined, onPressed: () => edit(current)),
            PartyLedgerAction(label: 'Preview Statement', icon: Icons.description_outlined, onPressed: () => previewStatement(current)),
            PartyLedgerAction(label: 'WhatsApp Customer', icon: Icons.chat_outlined, onPressed: () => whatsappCustomer(current)),
            PartyLedgerAction(label: 'WhatsApp Statement', icon: Icons.description_outlined, onPressed: () => whatsappStatement(current)),
            if (balance > 0) PartyLedgerAction(label: 'Payment Reminder', icon: Icons.notifications_active_outlined, onPressed: () => whatsappReminder(current)),
            PartyLedgerAction(label: 'Communications', icon: Icons.history_outlined, onPressed: () => communicationHistory(current)),
          ];
        },
      );

  Future<void> whatsappCustomer(Map<String,Object?> customer) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone: (customer['whatsapp'] ?? customer['phone'] ?? '').toString(),
        message: 'Hello ${customer['name'] ?? 'Customer'}, this is ${settings['business_name'] ?? 'RELIQ Solutions'}.',
        defaultCountryCode: settings['whatsapp_country_code'] ?? '',
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Customer', partyId: customer['id'].toString(), channel: 'WhatsApp',
        documentType: 'Customer Message', documentId: customer['id'].toString(), action: 'Prepared / opened',
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp opened for customer.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('WhatsApp: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> whatsappStatement(Map<String,Object?> customer) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone: (customer['whatsapp'] ?? customer['phone'] ?? '').toString(),
        message: WhatsAppService.customerStatementMessage(settings, customer),
        defaultCountryCode: settings['whatsapp_country_code'] ?? '',
      );
      await AppDatabase.instance.logCommunication(
        partyType:'Customer', partyId:customer['id'].toString(), channel:'WhatsApp',
        documentType:'Customer Statement', documentId:customer['id'].toString(), action:'Prepared / opened',
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('WhatsApp statement message opened. Use Preview Statement separately when you need the PDF.')));
    } catch(e) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('WhatsApp statement: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }
  Future<void> whatsappReminder(Map<String,Object?> customer) async {
    try { final settings=await AppDatabase.instance.settings(); await WhatsAppService.openChat(phone:(customer['whatsapp']??customer['phone']??'').toString(),message:WhatsAppService.paymentReminderMessage(settings,customer),defaultCountryCode:settings['whatsapp_country_code']??''); await AppDatabase.instance.logCommunication(partyType:'Customer',partyId:customer['id'].toString(),channel:'WhatsApp',documentType:'Payment Reminder',documentId:customer['id'].toString(),action:'Prepared / opened'); } catch(e){if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('WhatsApp reminder: ${e.toString().replaceFirst('Exception: ', '')}')));}
  }
  Future<void> communicationHistory(Map<String,Object?> customer) async {
    final rows=await AppDatabase.instance.communicationHistory('Customer',customer['id'].toString()); if(!mounted)return;
    await showDialog(context:context,builder:(ctx)=>AlertDialog(title:Text('Communication • ${customer['name']}'),content:SizedBox(width:650,height:430,child:rows.isEmpty?const Center(child:Text('No communication actions recorded yet.')):ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const Divider(height:1),itemBuilder:(_,i){final r=rows[i];final dt=DateTime.tryParse('${r['created_at']??''}');return ListTile(dense:true,leading:Icon(r['channel']=='WhatsApp'?Icons.chat_outlined:Icons.mail_outline),title:Text('${r['document_type']} • ${r['action']}',style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${r['channel']}${dt==null?'':' • ${dt.toLocal().toString().substring(0,16)}'}'));})),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
  }

  @override
  Widget build(BuildContext context) {
    final selected = _openCustomer;
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
                const Expanded(child: Text('Customers', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800))),
                FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.person_add_alt_1), label: const Text('Add Customer')),
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
                  hintText: 'Search customer, phone, WhatsApp, email or address',
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
                  if (snapshot.hasError) return Center(child: Text('Could not load customers: ${snapshot.error}'));
                  if (!snapshot.hasData) return const ReliqLoadingState(message: 'Loading customers…', detail: 'RELIQ is reading account balances and contact details.');
                  final rows = snapshot.data!;
                  if (rows.isEmpty) return const Center(child: Text('No customers yet.'));
                  return Card(
                    child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = rows[i];
                        final balance = (c['balance'] as num? ?? 0).toDouble();
                        final overdue = (c['overdue_balance'] as num? ?? 0).toDouble();
                        final credit = (c['credit_balance'] as num? ?? 0).toDouble();
                        return ListTile(
                          onTap: () => openLedger(c),
                          leading: Icon(((c['active'] as num?) ?? 1).toInt() == 1 ? Icons.person_outline : Icons.person_off_outlined),
                          title: Text('${c['name']}'),
                          subtitle: Text(
                            '${c['phone'] ?? ''}${('${c['email'] ?? ''}').isNotEmpty ? ' • ${c['email']}' : ''}${overdue > 0 ? ' • OVERDUE ${overdue.toStringAsFixed(3)}' : ''}${credit > 0 ? ' • CREDIT ${credit.toStringAsFixed(3)}' : ''}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Text('Outstanding'),
                                  Text(balance.toStringAsFixed(3), style: TextStyle(fontWeight: FontWeight.w700, color: balance > 0 ? Theme.of(context).colorScheme.error : null)),
                                ],
                              ),
                              const SizedBox(width: 8),
                              IconButton(tooltip: 'Edit customer', onPressed: () => edit(c), icon: const Icon(Icons.edit_outlined)),
                              const SizedBox(width: 2),
                              OutlinedButton.icon(
                                onPressed: () => receivePayment(c),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: V3Style.labelAccent(context),
                                  backgroundColor: Theme.of(context).brightness == Brightness.dark
                                      ? V3Style.lime.withValues(alpha: .08)
                                      : const Color(0xFFF3F8F6),
                                ),
                                icon: const Icon(Icons.payments_outlined),
                                label: const Text('Receive Payment'),
                              ),
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
