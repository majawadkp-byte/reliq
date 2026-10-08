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

class CustomersScreen extends StatefulWidget {
  final FocusNode? searchFocusNode;
  final String initialSearch;
  final String initialEntityId;
  final int lookupRevision;
  const CustomersScreen(
      {super.key,
      this.searchFocusNode,
      this.initialSearch = '',
      this.initialEntityId = '',
      this.lookupRevision = 0});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String query = '';
  late final FocusNode searchFocus;
  late final bool _ownsSearchFocus;
  final searchController = TextEditingController();
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

    // A universal-lookup entity id is a navigation target, not a list filter.
    // Open that ledger directly, but keep the customer list ready to show ALL
    // customers when the user comes back from the detail view.
    if (entityId.isNotEmpty) {
      searchController.clear();
      query = '';
      _listFuture = AppDatabase.instance.customers(limit: 10000);
      _scheduleInitialLedgerOpen(entityId);
    } else {
      searchController.text = display;
      query = display;
      _listFuture = AppDatabase.instance.customers(limit: 10000);
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
          await AppDatabase.instance.customers(search: entityId, limit: 5);
      if (!mounted) return;
      final exact = rows
          .where((row) => (row['id'] ?? '').toString() == entityId)
          .toList();
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
          () => _listFuture = AppDatabase.instance.customers(limit: 10000));
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

  Future<void> edit([Map<String, Object?>? customer]) async {
    String name = '${customer?['name'] ?? ''}';
    String phone = '${customer?['phone'] ?? ''}';
    String email = '${customer?['email'] ?? ''}';
    String whatsapp = '${customer?['whatsapp'] ?? customer?['phone'] ?? ''}';
    String preferredDelivery =
        '${customer?['preferred_delivery'] ?? 'WhatsApp'}';
    String address = '${customer?['address'] ?? ''}';
    String limit = '${customer?['credit_limit'] ?? 0}';
    String terms = '${customer?['terms_days'] ?? 0}';
    String groupId = '${customer?['group_id'] ?? ''}';
    bool active = ((customer?['active'] as num?) ?? 1).toInt() == 1;
    bool creditAllowed =
        ((customer?['credit_allowed'] as num?) ?? 0).toInt() == 1;

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
                    decoration:
                        const InputDecoration(labelText: 'Customer name'),
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
                  Row(children: [
                    Expanded(
                        child: TextFormField(
                            initialValue: whatsapp,
                            onChanged: (v) => whatsapp = v,
                            decoration: const InputDecoration(
                                labelText: 'WhatsApp number',
                                hintText:
                                    'Leave same as phone if applicable'))),
                    const SizedBox(width: 10),
                    Expanded(
                        child: DropdownButtonFormField<String>(
                            value: [
                              'WhatsApp',
                              'Email',
                              'Print',
                              'WhatsApp + Email'
                            ].contains(preferredDelivery)
                                ? preferredDelivery
                                : 'WhatsApp',
                            decoration: const InputDecoration(
                                labelText: 'Preferred document delivery'),
                            items: const [
                              'WhatsApp',
                              'Email',
                              'Print',
                              'WhatsApp + Email'
                            ]
                                .map((x) =>
                                    DropdownMenuItem(value: x, child: Text(x)))
                                .toList(),
                            onChanged: (v) => setD(
                                () => preferredDelivery = v ?? 'WhatsApp'))),
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
                    decoration: const InputDecoration(
                        labelText: 'Customer group / pricing cluster'),
                    items: [
                      const DropdownMenuItem(
                          value: '',
                          child: Text('No group / standard pricing')),
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
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Credit limit (0 = unlimited)'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            initialValue: terms,
                            onChanged: (v) => terms = v,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Terms (days)'),
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Customer changes saved')));
      }
    }
  }

  Future<void> receivePayment(Map<String, Object?> customer) async {
    final docs = await AppDatabase.instance
        .openCustomerInvoices(customer['id'].toString());
    if (!mounted) return;

    String amountText =
        (customer['balance'] as num? ?? 0).toDouble().toStringAsFixed(3);
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
          final credit =
              (entered - applied).clamp(0, double.infinity).toDouble();

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
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Amount received'),
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
                              labelText: 'Reference / receipt no.'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Allocate to invoices',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                      'RELIQ allocates oldest bills first. Override any row before posting.',
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
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${d['no']}',
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
                    'Applied ${applied.toStringAsFixed(3)}${credit > 0 ? ' • Unallocated credit ${credit.toStringAsFixed(3)}' : ''}',
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
        final requestedTotal =
            allocations.values.fold<double>(0, (a, b) => a + b);
        if (requestedTotal > entered + 0.000001)
          throw Exception(
              'Allocated amount cannot exceed the payment received.');
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
          if (a > 0)
            receiptAllocations.add(
                {'document_id': d['id'], 'document_no': d['no'], 'amount': a});
        }
        final credit =
            (entered - requestedTotal).clamp(0, double.infinity).toDouble();
        final printSettings = await AppDatabase.instance.settings();
        final printAction = PrintService.actionFromSetting(
            printSettings['customer_receipt_print_action']);
        if (printAction != ReliqPrintAction.none) {
          try {
            await PrintService.printPaymentReceipt(
              paymentId: paymentId,
              partyType: 'Customer',
              partyName: '${customer['name']}',
              amount: entered,
              method: method,
              reference: reference.trim(),
              allocations: receiptAllocations,
              accountCredit: credit,
              action: printAction,
              printerName: printSettings['customer_receipt_printer'] ?? '',
            );
          } catch (e) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Receipt saved, but document output failed: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }
        final freshCustomer = await AppDatabase.instance
                .customerById(customer['id'].toString()) ??
            customer;

        Future<void> openReceiptDocuments() async {
          if (!mounted) return;
          final choice = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text('Receipt $paymentId'),
              content: Text(
                  'Choose a document action for ${customer['name'] ?? 'Customer'}.'),
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
                  partyType: 'Customer',
                  partyName: '${customer['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: receiptAllocations,
                  accountCredit: credit);
              return;
            }
            if (choice == 'save') {
              final attachment = await PrintService.preparePaymentReceiptPdf(
                  paymentId: paymentId,
                  partyType: 'Customer',
                  partyName: '${customer['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: receiptAllocations,
                  accountCredit: credit);
              final savedPath = await DocumentShareService.savePdfAs(attachment,
                  suggestedFileName: 'Receipt_$paymentId.pdf');
              if (savedPath != null && mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Receipt PDF saved to $savedPath')));
              return;
            }
            if (choice == 'whatsapp') {
              final phone =
                  (freshCustomer['whatsapp'] ?? freshCustomer['phone'] ?? '')
                      .toString()
                      .trim();
              if (phone.isEmpty)
                throw Exception(
                    'This customer has no WhatsApp/phone number saved.');
              final payment = <String, Object?>{
                'id': paymentId,
                'party_name': customer['name'],
                'amount': entered,
                'party_balance': freshCustomer['balance']
              };
              final shareResult = await WhatsAppService.shareDocument(
                settings: printSettings,
                phone: phone,
                message: WhatsAppService.customerReceiptMessage(
                    printSettings, payment),
                prepareAttachment: () => PrintService.preparePaymentReceiptPdf(
                    paymentId: paymentId,
                    partyType: 'Customer',
                    partyName: '${customer['name']}',
                    amount: entered,
                    method: method,
                    reference: reference.trim(),
                    allocations: receiptAllocations,
                    accountCredit: credit),
              );
              await AppDatabase.instance.logCommunication(
                  partyType: 'Customer',
                  partyId: customer['id'].toString(),
                  channel: 'WhatsApp',
                  documentType: 'Payment Receipt',
                  documentId: paymentId,
                  action: shareResult.auditAction);
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(shareResult.userMessage('Receipt'))));
              return;
            }
            if (choice == 'email') {
              final attachment = await PrintService.preparePaymentReceiptPdf(
                  paymentId: paymentId,
                  partyType: 'Customer',
                  partyName: '${customer['name']}',
                  amount: entered,
                  method: method,
                  reference: reference.trim(),
                  allocations: receiptAllocations,
                  accountCredit: credit);
              final email = (freshCustomer['email'] ?? '').toString().trim();
              if (email.isEmpty)
                throw Exception('This customer has no email address saved.');
              final businessName =
                  (printSettings['business_name'] ?? 'RELIQ Solutions').trim();
              final currency = (printSettings['currency'] ?? 'KWD').trim();
              final decimals =
                  int.tryParse(printSettings['currency_decimals'] ?? '3') ?? 3;
              await DocumentShareService.openEmailDraftWithAttachment(
                  recipient: email,
                  subject: 'Payment Receipt $paymentId - $businessName',
                  body:
                      'Hello ${customer['name'] ?? 'Customer'},\n\nWe received $currency ${entered.toStringAsFixed(decimals)}. Please find your receipt attached.\n\nThank you,\n$businessName',
                  attachment: attachment);
              await AppDatabase.instance.logCommunication(
                  partyType: 'Customer',
                  partyId: customer['id'].toString(),
                  channel: 'Email',
                  documentType: 'Payment Receipt',
                  documentId: paymentId,
                  action: 'PDF prepared / opened');
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Email draft opened and the receipt PDF is ready in Finder/Explorer. Attach it, then send.')));
            }
          } catch (e) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Receipt document: ${e.toString().replaceFirst('Exception: ', '')}')));
          }
        }

        if (mounted) {
          _reload();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(printAction == ReliqPrintAction.direct
                ? 'Customer receipt saved and sent to printer'
                : printAction == ReliqPrintAction.preview
                    ? 'Customer receipt saved. Preview opened'
                    : 'Customer receipt saved and allocated'),
            action: SnackBarAction(
                label: 'DOCUMENTS',
                onPressed: () {
                  openReceiptDocuments();
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

  Future<void> previewStatement(Map<String, Object?> customer) async {
    try {
      final rows = await AppDatabase.instance
          .customerStatement(customer['id'].toString());
      await PrintService.printCustomerStatement(customer: customer, rows: rows);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Customer statement: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> openLedger(Map<String, Object?> customer) async {
    if (!mounted) return;
    setState(() => _openCustomer = Map<String, Object?>.from(customer));
  }

  void _closeLedger() {
    if (!mounted) return;
    // If this ledger was opened from Cmd/Ctrl+F universal lookup, do not leave
    // the hidden entity id behind as a customer-list filter.
    if (widget.initialEntityId.trim().isNotEmpty) {
      searchController.clear();
      query = '';
      setState(() {
        _openCustomer = null;
        _listFuture = AppDatabase.instance.customers(limit: 10000);
      });
      return;
    }

    setState(() {
      _openCustomer = null;
      _listFuture = AppDatabase.instance.customers(limit: 10000);
    });
  }

  Widget _ledgerView(Map<String, Object?> customer) => PartyLedgerDetailScreen(
        partyType: 'Customer',
        partyId: customer['id'].toString(),
        initialName: (customer['name'] ?? '').toString(),
        searchFocusNode: searchFocus,
        onBack: _closeLedger,
        actionsBuilder: (current) {
          final balance = (current['balance'] as num? ?? 0).toDouble();
          return [
            PartyLedgerAction(
                label: 'Receive Payment',
                icon: Icons.payments_outlined,
                primary: true,
                onPressed: () => receivePayment(current)),
            PartyLedgerAction(
                label: 'Edit Customer',
                icon: Icons.edit_outlined,
                onPressed: () => edit(current)),
            PartyLedgerAction(
                label: 'Preview Statement',
                icon: Icons.description_outlined,
                onPressed: () => previewStatement(current)),
            PartyLedgerAction(
                label: 'WhatsApp Customer',
                icon: Icons.chat_outlined,
                onPressed: () => whatsappCustomer(current)),
            PartyLedgerAction(
                label: 'WhatsApp Statement',
                icon: Icons.description_outlined,
                onPressed: () => whatsappStatement(current)),
            if (balance > 0)
              PartyLedgerAction(
                  label: 'Payment Reminder',
                  icon: Icons.notifications_active_outlined,
                  onPressed: () => whatsappReminder(current)),
            PartyLedgerAction(
                label: 'Communications',
                icon: Icons.history_outlined,
                onPressed: () => communicationHistory(current)),
          ];
        },
      );

  Future<void> whatsappCustomer(Map<String, Object?> customer) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone: (customer['whatsapp'] ?? customer['phone'] ?? '').toString(),
        message:
            'Hello ${customer['name'] ?? 'Customer'}, this is ${settings['business_name'] ?? 'RELIQ Solutions'}.',
        defaultCountryCode: settings['whatsapp_country_code'] ?? '',
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Customer',
        partyId: customer['id'].toString(),
        channel: 'WhatsApp',
        documentType: 'Customer Message',
        documentId: customer['id'].toString(),
        action: 'Prepared / opened',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('WhatsApp opened for customer.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'WhatsApp: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> whatsappStatement(Map<String, Object?> customer) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
        phone: (customer['whatsapp'] ?? customer['phone'] ?? '').toString(),
        message: WhatsAppService.customerStatementMessage(settings, customer),
        defaultCountryCode: settings['whatsapp_country_code'] ?? '',
      );
      await AppDatabase.instance.logCommunication(
        partyType: 'Customer',
        partyId: customer['id'].toString(),
        channel: 'WhatsApp',
        documentType: 'Customer Statement',
        documentId: customer['id'].toString(),
        action: 'Prepared / opened',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'WhatsApp statement message opened. Use Preview Statement separately when you need the PDF.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'WhatsApp statement: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> whatsappReminder(Map<String, Object?> customer) async {
    try {
      final settings = await AppDatabase.instance.settings();
      await WhatsAppService.openChat(
          phone: (customer['whatsapp'] ?? customer['phone'] ?? '').toString(),
          message: WhatsAppService.paymentReminderMessage(settings, customer),
          defaultCountryCode: settings['whatsapp_country_code'] ?? '');
      await AppDatabase.instance.logCommunication(
          partyType: 'Customer',
          partyId: customer['id'].toString(),
          channel: 'WhatsApp',
          documentType: 'Payment Reminder',
          documentId: customer['id'].toString(),
          action: 'Prepared / opened');
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'WhatsApp reminder: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> communicationHistory(Map<String, Object?> customer) async {
    final rows = await AppDatabase.instance
        .communicationHistory('Customer', customer['id'].toString());
    if (!mounted) return;
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('Communication • ${customer['name']}'),
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
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Customers',
                              style: TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w800)),
                          SizedBox(height: 2),
                          Text(
                              'Customer accounts, balances, contact details and payment activity.',
                              style: TextStyle(
                                  color: V3Style.muted, fontSize: 12)),
                        ]),
                  ),
                  FilledButton.icon(
                      onPressed: () => edit(),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add Customer')),
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
                        'Search customer, phone, WhatsApp, email or address',
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
                              'Could not load customers: ${snapshot.error}'));
                    if (!snapshot.hasData)
                      return const ReliqLoadingState(
                          message: 'Loading customers…',
                          detail:
                              'RELIQ is reading account balances and contact details.');
                    final allRows = snapshot.data!;
                    final rows = allRows.where(_matchesSearch).toList();
                    if (rows.isEmpty)
                      return const Center(
                          child:
                              Text('No customers match the current search.'));

                    final receivable = rows.fold<double>(0, (sum, c) {
                      final v = (c['balance'] as num? ?? 0).toDouble();
                      return sum + (v > 0 ? v : 0);
                    });
                    final overdue = rows.fold<double>(
                        0,
                        (sum, c) =>
                            sum +
                            (c['overdue_balance'] as num? ?? 0).toDouble());
                    final credit = rows.fold<double>(
                        0,
                        (sum, c) =>
                            sum +
                            (c['credit_balance'] as num? ?? 0).toDouble());
                    final active = rows
                        .where((c) => ((c['active'] as num?) ?? 1).toInt() == 1)
                        .length;

                    return Column(children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _summaryMetric(
                                label: 'Customers',
                                value: '${rows.length}',
                                icon: Icons.people_outline),
                            _summaryMetric(
                                label: 'Active',
                                value: '$active',
                                icon: Icons.verified_user_outlined),
                            _summaryMetric(
                                label: 'Receivable',
                                value: receivable.toStringAsFixed(3),
                                icon: Icons.account_balance_wallet_outlined,
                                valueColor: receivable > 0
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
                                label: 'Account credit',
                                value: credit.toStringAsFixed(3),
                                icon: Icons.savings_outlined,
                                valueColor:
                                    credit > 0 ? Colors.green.shade700 : null),
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
                                    ? 'All customers'
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
                                  final c = rows[i];
                                  final balance =
                                      (c['balance'] as num? ?? 0).toDouble();
                                  final overdueAmount =
                                      (c['overdue_balance'] as num? ?? 0)
                                          .toDouble();
                                  final creditAmount =
                                      (c['credit_balance'] as num? ?? 0)
                                          .toDouble();
                                  final activeCustomer =
                                      ((c['active'] as num?) ?? 1).toInt() == 1;
                                  return ListTile(
                                    minVerticalPadding: 10,
                                    onTap: () => openLedger(c),
                                    leading: CircleAvatar(
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .10),
                                      child: Icon(
                                          activeCustomer
                                              ? Icons.person_outline
                                              : Icons.person_off_outlined,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary),
                                    ),
                                    title: Row(children: [
                                      Flexible(
                                          child: Text('${c['name']}',
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w800))),
                                      if (!activeCustomer) ...[
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
                                        '${c['phone'] ?? ''}${('${c['email'] ?? ''}').isNotEmpty ? ' • ${c['email']}' : ''}${overdueAmount > 0 ? ' • OVERDUE ${overdueAmount.toStringAsFixed(3)}' : ''}${creditAmount > 0 ? ' • CREDIT ${creditAmount.toStringAsFixed(3)}' : ''}',
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
                                                Text('Outstanding',
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
                                              tooltip: 'Edit customer',
                                              onPressed: () => edit(c),
                                              icon: const Icon(
                                                  Icons.edit_outlined)),
                                          const SizedBox(width: 2),
                                          FilledButton.tonalIcon(
                                              onPressed: () =>
                                                  receivePayment(c),
                                              icon: const Icon(
                                                  Icons.payments_outlined,
                                                  size: 18),
                                              label: const Text('Receive')),
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
