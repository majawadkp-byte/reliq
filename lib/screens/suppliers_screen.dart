import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/document_share_service.dart';
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
  const SuppliersScreen(
      {super.key,
      this.searchFocusNode,
      this.initialSearch = '',
      this.initialEntityId = '',
      this.lookupRevision = 0});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  String query = '';
  late final FocusNode searchFocus;
  late final bool _ownsSearchFocus;
  final searchController = TextEditingController();
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

    // A universal-lookup entity id is a navigation target, not a list filter.
    // Open that ledger directly, but keep the supplier list ready to show ALL
    // suppliers when the user comes back from the detail view.
    if (entityId.isNotEmpty) {
      searchController.clear();
      query = '';
      _listFuture = AppDatabase.instance.suppliers(limit: 10000);
      _scheduleInitialLedgerOpen(entityId);
    } else {
      searchController.text = display;
      query = display;
      _listFuture = AppDatabase.instance.suppliers(limit: 10000);
    }

    if (!initial && mounted) setState(() {});
  }

  void _scheduleInitialLedgerOpen(String entityId) {
    final key = '${widget.lookupRevision}:$entityId';
    if (_autoOpenedEntityKey == key) return;
    _autoOpenedEntityKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final rows =
          await AppDatabase.instance.suppliers(search: entityId, limit: 5);
      if (!mounted) return;
      final exact = rows
          .where((row) => (row['id'] ?? '').toString() == entityId)
          .toList();
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
      _applyInitialLookup();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.initialEntityId.isEmpty &&
            widget.initialSearch.isNotEmpty) {
          searchFocus.requestFocus();
        }
      });
    }
  }

  void _reload() {
    if (mounted)
      setState(
          () => _listFuture = AppDatabase.instance.suppliers(limit: 10000));
  }

  bool _matchesSearch(Map<String, Object?> row) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty);
    if (terms.isEmpty) return true;
    final haystack = [
      row['name'],
      row['phone'],
      row['whatsapp'],
      row['email'],
      row['address'],
      row['id'],
    ].map((value) => '${value ?? ''}'.toLowerCase()).join(' ');
    return terms.every(haystack.contains);
  }

  void _onSearchChanged(String value) {
    if (!mounted) return;
    setState(() => query = value.trim());
  }

  void _submitSearch(String value) {
    if (!mounted) return;
    setState(() => query = value.trim());
  }

  void _clearSearch() {
    searchController.clear();
    if (mounted) setState(() => query = '');
    searchFocus.requestFocus();
  }

  @override
  void dispose() {
    searchController.dispose();
    if (_ownsSearchFocus) searchFocus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            edit(),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            edit(),
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
                  TextFormField(
                      initialValue: name,
                      onChanged: (v) => name = v,
                      decoration:
                          const InputDecoration(labelText: 'Supplier name')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          child: TextFormField(
                              initialValue: phone,
                              onChanged: (v) => phone = v,
                              decoration:
                                  const InputDecoration(labelText: 'Phone'))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextFormField(
                              initialValue: email,
                              onChanged: (v) => email = v,
                              decoration:
                                  const InputDecoration(labelText: 'Email'))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                      initialValue: whatsapp,
                      onChanged: (v) => whatsapp = v,
                      decoration: const InputDecoration(
                          labelText: 'WhatsApp number',
                          hintText: 'Leave same as phone if applicable')),
                  const SizedBox(height: 10),
                  TextFormField(
                      initialValue: address,
                      onChanged: (v) => address = v,
                      decoration: const InputDecoration(labelText: 'Address')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                          child: TextFormField(
                              initialValue: lead,
                              onChanged: (v) => lead = v,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: 'Lead time (days)'))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextFormField(
                              initialValue: terms,
                              onChanged: (v) => terms = v,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: 'Payment terms (days)'))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: minOrder,
                    onChanged: (v) => minOrder = v,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Minimum supplier order value'),
                  ),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      value: active,
                      onChanged: (v) => setD(() => active = v)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
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
          'min_order_value':
              (double.tryParse(minOrder) ?? 0).clamp(0, double.infinity),
          'active': active ? 1 : 0,
        },
        id: supplier?['id'] as String?,
      );
      if (mounted) {
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Supplier changes saved')));
      }
    }
  }

  Future<void> previewStatement(Map<String, Object?> supplier) async {
    try {
      final rows = await AppDatabase.instance
          .supplierStatement(supplier['id'].toString());
      await PrintService.printSupplierStatement(supplier: supplier, rows: rows);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Supplier statement: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> openLedger(Map<String, Object?> supplier) async {
    if (!mounted) return;
    setState(() => _openSupplier = Map<String, Object?>.from(supplier));
  }

  void _closeLedger() {
    if (!mounted) return;
    // If this ledger was opened from Cmd/Ctrl+F universal lookup, do not leave
    // the hidden entity id behind as a supplier-list filter.
    if (widget.initialEntityId.trim().isNotEmpty) {
      searchController.clear();
      query = '';
      setState(() {
        _openSupplier = null;
        _listFuture = AppDatabase.instance.suppliers(limit: 10000);
      });
      return;
    }

    setState(() {
      _openSupplier = null;
      _listFuture = AppDatabase.instance.suppliers(limit: 10000);
    });
  }

  Widget _ledgerView(Map<String, Object?> supplier) => PartyLedgerDetailScreen(
        partyType: 'Supplier',
        partyId: supplier['id'].toString(),
        initialName: (supplier['name'] ?? '').toString(),
        searchFocusNode: searchFocus,
        onBack: _closeLedger,
        actionsBuilder: (current) => [
          PartyLedgerAction(
              label: 'Pay Supplier',
              icon: Icons.payments_outlined,
              primary: true,
              onPressed: () => makePayment(current)),
          PartyLedgerAction(
              label: 'Edit Supplier',
              icon: Icons.edit_outlined,
              onPressed: () => edit(current)),
          PartyLedgerAction(
              label: 'Preview Statement',
              icon: Icons.description_outlined,
              onPressed: () => previewStatement(current)),
          PartyLedgerAction(
              label: 'WhatsApp Supplier',
              icon: Icons.chat_outlined,
              onPressed: () => whatsappSupplier(current)),
          PartyLedgerAction(
              label: 'Communications',
              icon: Icons.history_outlined,
              onPressed: () => communicationHistory(current)),
        ],
      );

  Future<void> whatsappSupplier(Map<String, Object?> supplier) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone: (supplier['whatsapp'] ?? supplier['phone'] ?? '').toString(),
        message:
            'Hello ${supplier['name']}, this is ${settings['business_name'] ?? 'RELIQ Solutions'}.',
        defaultCountryCode: settings['whatsapp_country_code'] ?? '',
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Supplier',
        partyId: supplier['id'].toString(),
        channel: 'WhatsApp',
        documentType: 'Supplier Message',
        documentId: supplier['id'].toString(),
        action: 'Prepared / opened',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('WhatsApp opened for supplier.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'WhatsApp: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> communicationHistory(Map<String, Object?> supplier) async {
    final rows = await AppDatabase.instance
        .communicationHistory('Supplier', supplier['id'].toString());
    if (!mounted) return;
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('Communication • ${supplier['name']}'),
                content: SizedBox(
                    width: 650,
                    height: 430,
                    child: rows.isEmpty
                        ? const Center(
                            child: Text('No communication actions recorded yet.'))
                        : ListView.separated(
                            itemCount: rows.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final r = rows[i];
                              final dt =
                                  DateTime.tryParse('${r['created_at'] ?? ''}');
                              return ListTile(
                                  dense: true,
                                  leading: Icon(r['channel'] == 'WhatsApp'
                                      ? Icons.chat_outlined
                                      : Icons.mail_outline),
                                  title: Text(
                                      '${r['document_type']} • ${r['action']}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  subtitle: Text(
                                      '${r['channel']}${dt == null ? '' : ' • ${dt.toLocal().toString().substring(0, 16)}'}'));
                            })),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'))
                ]));
  }

  Future<void> makePayment(Map<String, Object?> supplier) async {
    final docs =
        await AppDatabase.instance.openSupplierBills(supplier['id'].toString());
    if (!mounted) return;

    String amountText =
        (supplier['balance'] as num? ?? 0).toDouble().toStringAsFixed(3);
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
          final advance =
              (entered - applied).clamp(0, double.infinity).toDouble();

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
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Payment amount'),
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
                          decoration:
                              const InputDecoration(labelText: 'Method'),
                          items: const [
                            'Cash',
                            'Card',
                            'Bank',
                            'Cheque',
                            'Other'
                          ]
                              .map((x) =>
                                  DropdownMenuItem(value: x, child: Text(x)))
                              .toList(),
                          onChanged: (v) => setD(() => method = v ?? 'Cash'),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: TextFormField(
                          initialValue: reference,
                          onChanged: (v) => reference = v,
                          decoration: const InputDecoration(
                              labelText: 'Reference / voucher no.'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Allocate to supplier bills',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                      'Oldest bills are proposed first. You can override the allocation.',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
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
                          title: Text(
                              '${d['no']}${documentNo.isEmpty ? '' : ' • $documentNo'}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              'Balance ${balance.toStringAsFixed(3)}${d['due_date'] == null ? '' : ' • Due ${d['due_date'].toString().split('T').first}'}'),
                          trailing: SizedBox(
                            width: 150,
                            child: TextFormField(
                              key: ValueKey('$id-${allocations[id] ?? 0}'),
                              initialValue:
                                  (allocations[id] ?? 0).toStringAsFixed(3),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration:
                                  const InputDecoration(labelText: 'Apply'),
                              onChanged: (v) {
                                allocations[id] = (double.tryParse(v) ?? 0)
                                    .clamp(0, balance)
                                    .toDouble();
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
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
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
        final requestedTotal =
            allocations.values.fold<double>(0, (a, b) => a + b);
        if (requestedTotal > entered + 0.000001)
          throw Exception(
              'Allocated amount cannot exceed the supplier payment.');
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
          if (a > 0)
            voucherAllocations.add({
              'document_id': d['id'],
              'document_no': (d['document_no'] ?? '').toString().isEmpty
                  ? d['no']
                  : '${d['no']} • ${d['document_no']}',
              'amount': a
            });
        }
        final advance =
            (entered - requestedTotal).clamp(0, double.infinity).toDouble();
        final printSettings = await AppDatabase.instance.settings();
        final printAction = PrintService.actionFromSetting(
            printSettings['supplier_payment_print_action']);
        if (printAction != ReliqPrintAction.none) {
          try {
            await PrintService.printPaymentReceipt(
              paymentId: paymentId,
              partyType: 'Supplier',
              partyName: '${supplier['name']}',
              amount: entered,
              method: method,
              reference: reference.trim(),
              allocations: voucherAllocations,
              accountCredit: advance,
              action: printAction,
              printerName: printSettings['supplier_payment_printer'] ?? '',
            );
          } catch (e) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Supplier payment saved, but document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }
        final supplierRows = await AppDatabase.instance.db.query(
          'suppliers',
          where: 'id=?',
          whereArgs: [supplier['id']],
          limit: 1,
        );
        final freshSupplier =
            supplierRows.isEmpty ? supplier : supplierRows.first;

        Future<void> openPaymentDocuments() async {
          if (!mounted) return;
          final choice = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text('Supplier Payment $paymentId'),
              content: Text(
                  'Choose a document action for ${supplier['name'] ?? 'Supplier'}.'),
              actions: [
                TextButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, 'preview'),
                    icon: const Icon(Icons.preview_outlined),
                    label: const Text('Preview / Print')),
                TextButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, 'save'),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save PDF')),
                TextButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, 'whatsapp'),
                    icon: const Icon(Icons.chat_outlined),
                    label: const Text('WhatsApp')),
                TextButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, 'email'),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Email PDF')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Done')),
              ],
            ),
          );
          if (choice == null || !mounted) return;
          try {
            if (choice == 'preview') {
              await PrintService.printPaymentReceipt(
                  paymentId: paymentId,
                  partyType: 'Supplier',
                  partyName: '${supplier['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: voucherAllocations,
                  accountCredit: advance);
              return;
            }
            if (choice == 'save') {
              final attachment = await PrintService.preparePaymentReceiptPdf(
                  paymentId: paymentId,
                  partyType: 'Supplier',
                  partyName: '${supplier['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: voucherAllocations,
                  accountCredit: advance);
              final savedPath = await DocumentShareService.savePdfAs(attachment,
                  suggestedFileName: 'Supplier_Payment_$paymentId.pdf');
              if (savedPath != null && mounted)
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Supplier payment PDF saved to $savedPath')));
              return;
            }
            if (choice == 'whatsapp') {
              final phone =
                  (freshSupplier['whatsapp'] ?? freshSupplier['phone'] ?? '')
                      .toString()
                      .trim();
              if (phone.isEmpty)
                throw Exception(
                    'This supplier has no WhatsApp/phone number saved.');
              final payment = <String, Object?>{
                'id': paymentId,
                'party_name': supplier['name'],
                'amount': entered,
                'party_balance': freshSupplier['balance']
              };
              final shareResult = await WhatsAppService.shareDocument(
                settings: printSettings,
                phone: phone,
                message: WhatsAppService.supplierPaymentAdviceMessage(
                    printSettings, payment),
                prepareAttachment: () => PrintService.preparePaymentReceiptPdf(
                    paymentId: paymentId,
                    partyType: 'Supplier',
                    partyName: '${supplier['name']}',
                    amount: entered,
                    method: method,
                    reference: reference.trim(),
                    allocations: voucherAllocations,
                    accountCredit: advance),
              );
              await AppDatabase.instance.logCommunication(
                  partyType: 'Supplier',
                  partyId: supplier['id'].toString(),
                  channel: 'WhatsApp',
                  documentType: 'Supplier Payment Advice',
                  documentId: paymentId,
                  action: shareResult.auditAction);
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(shareResult.userMessage('Payment advice'))));
              return;
            }
            if (choice == 'email') {
              final attachment = await PrintService.preparePaymentReceiptPdf(
                  paymentId: paymentId,
                  partyType: 'Supplier',
                  partyName: '${supplier['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: voucherAllocations,
                  accountCredit: advance);
              final email = (freshSupplier['email'] ?? '').toString().trim();
              if (email.isEmpty)
                throw Exception('This supplier has no email address saved.');
              final businessName =
                  (printSettings['business_name'] ?? 'RELIQ Solutions').trim();
              final currency = (printSettings['currency'] ?? 'KWD').trim();
              final decimals =
                  int.tryParse(printSettings['currency_decimals'] ?? '3') ?? 3;
              await DocumentShareService.openEmailDraftWithAttachment(
                  recipient: email,
                  subject: 'Supplier Payment Advice $paymentId - $businessName',
                  body:
                      'Hello ${supplier['name'] ?? 'Supplier'},\n\nPayment of $currency ${entered.toStringAsFixed(decimals)} has been recorded. Please find the payment advice attached.\n\nRegards,\n$businessName',
                  attachment: attachment);
              await AppDatabase.instance.logCommunication(
                  partyType: 'Supplier',
                  partyId: supplier['id'].toString(),
                  channel: 'Email',
                  documentType: 'Supplier Payment Advice',
                  documentId: paymentId,
                  action: 'PDF prepared / opened');
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Email draft opened and the payment PDF is ready in Finder/Explorer. Attach it, then send.')));
            }
          } catch (e) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Supplier payment document: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }

        if (mounted) {
          _reload();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(printAction == ReliqPrintAction.direct
                ? 'Supplier payment saved and sent to printer'
                : printAction == ReliqPrintAction.preview
                    ? 'Supplier payment saved. Preview opened'
                    : 'Supplier payment saved and allocated'),
            action: SnackBarAction(
                label: 'DOCUMENTS',
                onPressed: () {
                  openPaymentDocuments();
                }),
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
        }
      }
    }
  }

  Widget _summaryMetric(
      {required String label,
      required String value,
      required IconData icon,
      Color? valueColor}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 170, maxWidth: 240),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .09),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  size: 19, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: valueColor)),
                  ]),
            ),
          ]),
        ),
      ),
    );
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
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Suppliers',
                              style: TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w800)),
                          SizedBox(height: 2),
                          Text(
                              'Supplier accounts, purchasing contacts, terms and payment activity.',
                              style: TextStyle(
                                  color: V3Style.muted, fontSize: 12)),
                        ]),
                  ),
                  FilledButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.add_business),
                      label: const Text('Add Supplier')),
                ],
              ),
              const SizedBox(height: 14),
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
                    hintText:
                        'Search supplier, phone, WhatsApp, email or address',
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: _clearSearch,
                            icon: const Icon(Icons.close)),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: _listFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasError)
                      return Center(
                          child: Text(
                              'Could not load suppliers: ${snapshot.error}'));
                    if (!snapshot.hasData)
                      return const ReliqLoadingState(
                          message: 'Loading suppliers…',
                          detail:
                              'RELIQ is reading account balances and contact details.');
                    final allRows = snapshot.data!;
                    final rows = allRows.where(_matchesSearch).toList();
                    if (rows.isEmpty)
                      return const Center(
                          child:
                              Text('No suppliers match the current search.'));

                    final payable = rows.fold<double>(0, (sum, s) {
                      final v = (s['balance'] as num? ?? 0).toDouble();
                      return sum + (v > 0 ? v : 0);
                    });
                    final overdue = rows.fold<double>(
                        0,
                        (sum, s) =>
                            sum +
                            (s['overdue_balance'] as num? ?? 0).toDouble());
                    final advance = rows.fold<double>(
                        0,
                        (sum, s) =>
                            sum +
                            (s['credit_balance'] as num? ?? 0).toDouble());
                    final active = rows
                        .where((s) => ((s['active'] as num?) ?? 1).toInt() == 1)
                        .length;

                    return Column(children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _summaryMetric(
                                label: 'Suppliers',
                                value: '${rows.length}',
                                icon: Icons.local_shipping_outlined),
                            _summaryMetric(
                                label: 'Active',
                                value: '$active',
                                icon: Icons.verified_user_outlined),
                            _summaryMetric(
                                label: 'Payable',
                                value: payable.toStringAsFixed(3),
                                icon: Icons.account_balance_wallet_outlined,
                                valueColor: payable > 0
                                    ? Theme.of(context).colorScheme.error
                                    : null),
                            _summaryMetric(
                                label: 'Overdue',
                                value: overdue.toStringAsFixed(3),
                                icon: Icons.schedule_outlined,
                                valueColor: overdue > 0
                                    ? Theme.of(context).colorScheme.error
                                    : null),
                            _summaryMetric(
                                label: 'Supplier advance',
                                value: advance.toStringAsFixed(3),
                                icon: Icons.savings_outlined,
                                valueColor:
                                    advance > 0 ? Colors.green.shade700 : null),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: .35),
                              child: Text(
                                query.trim().isEmpty
                                    ? 'All suppliers'
                                    : 'Search results for “${query.trim()}”',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 12),
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                itemCount: rows.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, i) {
                                  final s = rows[i];
                                  final balance =
                                      (s['balance'] as num? ?? 0).toDouble();
                                  final overdueAmount =
                                      (s['overdue_balance'] as num? ?? 0)
                                          .toDouble();
                                  final creditAmount =
                                      (s['credit_balance'] as num? ?? 0)
                                          .toDouble();
                                  final activeSupplier =
                                      ((s['active'] as num?) ?? 1).toInt() == 1;
                                  return ListTile(
                                    minVerticalPadding: 10,
                                    onTap: () => openLedger(s),
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .10),
                                      child: Icon(
                                          activeSupplier
                                              ? Icons.local_shipping_outlined
                                              : Icons.visibility_off_outlined,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary),
                                    ),
                                    title: Row(children: [
                                      Flexible(
                                          child: Text('${s['name']}',
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w800))),
                                      if (!activeSupplier) ...[
                                        const SizedBox(width: 7),
                                        const Text('Inactive',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: V3Style.muted,
                                                fontWeight: FontWeight.w700)),
                                      ],
                                    ]),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        '${s['phone'] ?? ''}${('${s['email'] ?? ''}').isNotEmpty ? ' • ${s['email']}' : ''} • Lead ${s['lead_days'] ?? 0}d • Terms ${s['terms_days'] ?? 0}d${overdueAmount > 0 ? ' • OVERDUE ${overdueAmount.toStringAsFixed(3)}' : ''}${creditAmount > 0 ? ' • ADVANCE ${creditAmount.toStringAsFixed(3)}' : ''}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 115,
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                Text('Payable',
                                                    style: TextStyle(
                                                        fontSize: 10,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant)),
                                                const SizedBox(height: 2),
                                                Text(balance.toStringAsFixed(3),
                                                    style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: balance > 0
                                                            ? Theme.of(context)
                                                                .colorScheme
                                                                .error
                                                            : null)),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                              tooltip: 'Edit supplier',
                                              onPressed: () => edit(s),
                                              icon: const Icon(
                                                  Icons.edit_outlined)),
                                          const SizedBox(width: 2),
                                          FilledButton.tonalIcon(
                                              onPressed: () => makePayment(s),
                                              icon: const Icon(
                                                  Icons.payments_outlined,
                                                  size: 18),
                                              label: const Text('Pay')),
                                          const SizedBox(width: 4),
                                          const Icon(Icons.chevron_right),
                                        ]),
                                  );
                                },
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ]);
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
