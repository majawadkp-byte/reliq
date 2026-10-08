import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/document_share_service.dart';
import '../services/print_service.dart';
import '../services/whatsapp_service.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_loading.dart';
import '../ui/searchable_map_select.dart';
import '../ui/reliq_surface.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'customer_groups_screen.dart';

class PaymentsLedgersScreen extends StatefulWidget {
  final int initialTab;
  final bool showShortcutHelpers;
  final String initialPartyId;
  final String initialPartyName;
  final int lookupRevision;
  const PaymentsLedgersScreen({
    super.key,
    this.initialTab = 0,
    this.showShortcutHelpers = true,
    this.initialPartyId = '',
    this.initialPartyName = '',
    this.lookupRevision = 0,
  });

  @override
  State<PaymentsLedgersScreen> createState() => PaymentsLedgersScreenState();
}

class PaymentsLedgersScreenState extends State<PaymentsLedgersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final FocusNode customerSearchFocus =
      FocusNode(debugLabel: 'customer-search');
  final FocusNode supplierSearchFocus =
      FocusNode(debugLabel: 'supplier-search');

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTab.clamp(0, 7).toInt();
    _tabController =
        TabController(length: 8, vsync: this, initialIndex: initial);
  }

  @override
  void didUpdateWidget(covariant PaymentsLedgersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final desired = widget.initialTab.clamp(0, 7).toInt();
    if (oldWidget.initialTab != widget.initialTab &&
        _tabController.index != desired) {
      _tabController.index = desired;
    }
  }

  /// Returns true when Cmd/Ctrl+F can be handled by the active ledger tab.
  bool focusContextSearch() {
    if (_tabController.index == 0) {
      customerSearchFocus.requestFocus();
      return true;
    }
    if (_tabController.index == 1) {
      supplierSearchFocus.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _tabController.dispose();
    customerSearchFocus.dispose();
    supplierSearchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      ReliqGlass(
        blur: 14,
        radius: 0,
        padding: EdgeInsets.zero,
        child: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(
                text: widget.showShortcutHelpers
                    ? 'Customer Ledgers  Alt+5'
                    : 'Customer Ledgers'),
            Tab(
                text: widget.showShortcutHelpers
                    ? 'Supplier Ledgers  Alt+6'
                    : 'Supplier Ledgers'),
            const Tab(text: 'Customer Groups'),
            const Tab(text: 'Aging'),
            Tab(
                text: widget.showShortcutHelpers
                    ? 'Payment Activity  Alt+7'
                    : 'Payment Activity'),
            const Tab(text: 'Unapplied Credits'),
            const Tab(text: 'Adjustments & Opening'),
            const Tab(text: 'Reconciliation'),
          ],
        ),
      ),
      Expanded(
        child: TabBarView(
          controller: _tabController,
          children: [
            CustomersScreen(
              searchFocusNode: customerSearchFocus,
              initialSearch:
                  widget.initialTab == 0 ? widget.initialPartyName : '',
              initialEntityId:
                  widget.initialTab == 0 ? widget.initialPartyId : '',
              lookupRevision:
                  widget.initialTab == 0 ? widget.lookupRevision : 0,
            ),
            SuppliersScreen(
              searchFocusNode: supplierSearchFocus,
              initialSearch:
                  widget.initialTab == 1 ? widget.initialPartyName : '',
              initialEntityId:
                  widget.initialTab == 1 ? widget.initialPartyId : '',
              lookupRevision:
                  widget.initialTab == 1 ? widget.lookupRevision : 0,
            ),
            const CustomerGroupsScreen(),
            const _AgingOverview(),
            const _PaymentActivity(),
            const _UnappliedCredits(),
            const _AccountingAdjustments(),
            const _PaymentReconciliation(),
          ],
        ),
      ),
    ]);
  }
}

class _PaymentActivity extends StatefulWidget {
  const _PaymentActivity();
  @override
  State<_PaymentActivity> createState() => _PaymentActivityState();
}

class _PaymentActivityState extends State<_PaymentActivity>
    with AutomaticKeepAliveClientMixin<_PaymentActivity> {
  String query = '';
  String partyType = 'All',
      method = 'All',
      direction = 'All',
      branchId = 'All',
      documentType = 'All',
      sort = 'Newest';
  DateTime? from, to;
  double? minimum, maximum;
  int resultCount = 0;
  late final Future<List<Map<String, Object?>>> branchFuture =
      AppDatabase.instance.branches();
  late final Future<List<Map<String, Object?>>> typeFuture =
      AppDatabase.instance.db.rawQuery(
          'SELECT DISTINCT document_type FROM payments ORDER BY document_type');
  late Future<List<Map<String, Object?>>> _activityFuture;
  Timer? _filterDebounce;

  @override
  void initState() {
    super.initState();
    _activityFuture = _loadActivity();
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<List<Map<String, Object?>>> _loadActivity() =>
      AppDatabase.instance.paymentLedger(
          limit: pageSize + 1,
          offset: page * pageSize,
          search: query,
          partyType: partyType,
          method: method,
          direction: direction,
          branchId: branchId,
          documentType: documentType,
          sort: sort,
          from: from,
          to: to,
          minimum: minimum,
          maximum: maximum);
  void _reload([VoidCallback? mutation]) {
    if (!mounted) return;
    setState(() {
      mutation?.call();
      _activityFuture = _loadActivity();
    });
  }

  void _debounced(VoidCallback mutation) {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _reload(mutation);
    });
  }

  Future<void> pickDate(bool start) async {
    final value = await showDatePicker(
        context: context,
        initialDate: (start ? from : to) ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2100));
    if (value != null)
      _reload(() {
        if (start) {
          from = value;
        } else {
          to = value;
        }
        page = 0;
      });
  }

  Widget select(String label, String value, List<String> choices,
          ValueChanged<String> change) =>
      SizedBox(
          width: 160,
          child: DropdownButtonFormField<String>(
              value: value,
              isExpanded: true,
              decoration: InputDecoration(labelText: label),
              items: choices
                  .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                  .toList(),
              onChanged: (v) => _reload(() {
                    change(v!);
                    page = 0;
                  })));

  int page = 0;
  int resetKey = 0;
  static const pageSize = 100;

  Future<void> _previewPayment(Map<String, Object?> payment) async {
    try {
      final type = (payment['party_type'] ?? '').toString();
      final allocations = await AppDatabase.instance
          .paymentAllocationsFor(payment['id'].toString());
      final amount = ((payment['amount'] as num?) ?? 0).abs().toDouble();
      final allocated =
          ((payment['allocated_amount'] as num?) ?? 0).abs().toDouble();
      final accountCredit =
          (amount - allocated).clamp(0, double.infinity).toDouble();
      await PrintService.printPaymentReceipt(
        paymentId: payment['id'].toString(),
        partyType: type,
        partyName: (payment['party_name'] ?? type).toString(),
        amount: amount,
        method: (payment['method'] ?? '').toString(),
        reference: (payment['reference'] ?? '').toString(),
        createdAt: (payment['created_at'] ?? '').toString(),
        allocations: allocations,
        accountCredit: accountCredit,
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Payment document preview opened.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Preview: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _savePaymentPdf(Map<String, Object?> payment) async {
    try {
      final type = (payment['party_type'] ?? '').toString();
      final allocations = await AppDatabase.instance
          .paymentAllocationsFor(payment['id'].toString());
      final amount = ((payment['amount'] as num?) ?? 0).abs().toDouble();
      final allocated =
          ((payment['allocated_amount'] as num?) ?? 0).abs().toDouble();
      final accountCredit =
          (amount - allocated).clamp(0, double.infinity).toDouble();
      final attachment = await PrintService.preparePaymentReceiptPdf(
        paymentId: payment['id'].toString(),
        partyType: type,
        partyName: (payment['party_name'] ?? type).toString(),
        amount: amount,
        method: (payment['method'] ?? '').toString(),
        reference: (payment['reference'] ?? '').toString(),
        createdAt: (payment['created_at'] ?? '').toString(),
        allocations: allocations,
        accountCredit: accountCredit,
      );
      final prefix = type == 'Customer' ? 'Receipt' : 'Supplier_Payment';
      final savedPath = await DocumentShareService.savePdfAs(attachment,
          suggestedFileName: '${prefix}_${payment['id']}.pdf');
      if (savedPath != null && mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('PDF saved to $savedPath')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Save PDF: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _emailPayment(Map<String, Object?> payment) async {
    showReliqWorkingSnack(
        context, 'Preparing payment email… RELIQ is still working.');
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final type = (payment['party_type'] ?? '').toString();
      if (type != 'Customer' && type != 'Supplier')
        throw Exception(
            'Email sharing is only available for customer/supplier payments.');
      final email = (payment['party_email'] ?? '').toString().trim();
      if (email.isEmpty)
        throw Exception(
            'No email address is saved for this ${type.toLowerCase()}.');
      final allocations = await AppDatabase.instance
          .paymentAllocationsFor(payment['id'].toString());
      final amount = ((payment['amount'] as num?) ?? 0).abs().toDouble();
      final allocated =
          ((payment['allocated_amount'] as num?) ?? 0).abs().toDouble();
      final accountCredit =
          (amount - allocated).clamp(0, double.infinity).toDouble();
      final attachment = await PrintService.preparePaymentReceiptPdf(
          paymentId: payment['id'].toString(),
          partyType: type,
          partyName: (payment['party_name'] ?? type).toString(),
          amount: amount,
          method: (payment['method'] ?? '').toString(),
          reference: (payment['reference'] ?? '').toString(),
          createdAt: (payment['created_at'] ?? '').toString(),
          allocations: allocations,
          accountCredit: accountCredit);
      final settings = await AppDatabase.instance.settings();
      final businessName =
          (settings['business_name'] ?? 'RELIQ Solutions').trim();
      final currency = (settings['currency'] ?? 'KWD').trim();
      final decimals = int.tryParse(settings['currency_decimals'] ?? '3') ?? 3;
      final isCustomer = type == 'Customer';
      await DocumentShareService.openEmailDraftWithAttachment(
        recipient: email,
        subject:
            '${isCustomer ? 'Payment Receipt' : 'Supplier Payment Advice'} ${payment['id']} - $businessName',
        body: isCustomer
            ? 'Hello ${payment['party_name'] ?? 'Customer'},\n\nWe received $currency ${amount.toStringAsFixed(decimals)}. Please find your receipt attached.\n\nThank you,\n$businessName'
            : 'Hello ${payment['party_name'] ?? 'Supplier'},\n\nPayment of $currency ${amount.toStringAsFixed(decimals)} has been recorded. Please find the payment advice attached.\n\nRegards,\n$businessName',
        attachment: attachment,
      );
      await AppDatabase.instance.logCommunication(
          partyType: type,
          partyId: (payment['party_id'] ?? '').toString(),
          channel: 'Email',
          documentType:
              isCustomer ? 'Payment Receipt' : 'Supplier Payment Advice',
          documentId: payment['id'].toString(),
          action: 'PDF prepared / opened');
      if (mounted) {
        hideReliqWorkingSnack(context);
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Email draft opened and the PDF is ready in Finder/Explorer. Attach it, then send.')));
      }
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Email PDF: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  Future<void> _whatsappPayment(Map<String, Object?> payment) async {
    showReliqWorkingSnack(context,
        'Preparing ${payment['party_type'] == 'Customer' ? 'payment receipt' : 'supplier payment advice'}… RELIQ is still working.');
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final type = (payment['party_type'] ?? '').toString();
      if (type != 'Customer' && type != 'Supplier')
        throw Exception(
            'WhatsApp sharing is only available for customer/supplier payments.');
      final phone = (payment['party_whatsapp'] ?? payment['party_phone'] ?? '')
          .toString();
      if (phone.trim().isEmpty)
        throw Exception(
            'No WhatsApp/phone number is saved for this ${type.toLowerCase()}.');
      final allocations = await AppDatabase.instance
          .paymentAllocationsFor(payment['id'].toString());
      final amount = ((payment['amount'] as num?) ?? 0).abs().toDouble();
      final allocated =
          ((payment['allocated_amount'] as num?) ?? 0).abs().toDouble();
      final accountCredit =
          (amount - allocated).clamp(0, double.infinity).toDouble();
      final settings = await AppDatabase.instance.settings();
      final message = type == 'Customer'
          ? WhatsAppService.customerReceiptMessage(settings, payment)
          : WhatsAppService.supplierPaymentAdviceMessage(settings, payment);
      final shareResult = await WhatsAppService.shareDocument(
        settings: settings,
        phone: phone,
        message: message,
        prepareAttachment: () => PrintService.preparePaymentReceiptPdf(
            paymentId: payment['id'].toString(),
            partyType: type,
            partyName: (payment['party_name'] ?? type).toString(),
            amount: amount,
            method: (payment['method'] ?? '').toString(),
            reference: (payment['reference'] ?? '').toString(),
            createdAt: (payment['created_at'] ?? '').toString(),
            allocations: allocations,
            accountCredit: accountCredit),
      );
      await AppDatabase.instance.logCommunication(
          partyType: type,
          partyId: (payment['party_id'] ?? '').toString(),
          channel: 'WhatsApp',
          documentType: type == 'Customer'
              ? 'Payment Receipt'
              : 'Supplier Payment Advice',
          documentId: payment['id'].toString(),
          action: shareResult.auditAction);
      if (mounted) {
        hideReliqWorkingSnack(context);
        _reload();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(shareResult.userMessage(
                type == 'Customer' ? 'Receipt' : 'Payment advice'))));
      }
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'WhatsApp: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: V3Style.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Payment Activity',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        Text(
            'Customer receipts, supplier payments and references in one ledger.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        TextField(
            onChanged: (v) => _debounced(() {
                  query = v.trim();
                  page = 0;
                }),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search party, method, reference or document')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          select('Party type', partyType, ['All', 'Customer', 'Supplier'],
              (v) => partyType = v),
          select(
              'Method',
              method,
              ['All', 'Cash', 'Card', 'Bank', 'Other', 'Supplier Credit'],
              (v) => method = v),
          select('Direction', direction, ['All', 'Received', 'Paid'],
              (v) => direction = v),
          select(
              'Sort',
              sort,
              ['Newest', 'Oldest', 'Highest Amount', 'Lowest Amount'],
              (v) => sort = v),
          FutureBuilder<List<Map<String, Object?>>>(
              future: typeFuture,
              builder: (ctx, s) => select(
                  'Payment type',
                  documentType,
                  ['All', ...s.data?.map((r) => '${r['document_type']}') ?? []],
                  (v) => documentType = v)),
          FutureBuilder<List<Map<String, Object?>>>(
              future: branchFuture,
              builder: (ctx, s) => SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<String>(
                      value: branchId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Branch'),
                      items: [
                        const DropdownMenuItem(
                            value: 'All', child: Text('All branches')),
                        ...(s.data ?? []).map((b) => DropdownMenuItem(
                            value: '${b['id']}', child: Text('${b['name']}')))
                      ],
                      onChanged: (v) => _reload(() {
                            branchId = v!;
                            page = 0;
                          })))),
          OutlinedButton(
              onPressed: () => pickDate(true),
              child: Text(from == null
                  ? 'From date'
                  : DateFormat('dd MMM yyyy').format(from!))),
          OutlinedButton(
              onPressed: () => pickDate(false),
              child: Text(to == null
                  ? 'To date'
                  : DateFormat('dd MMM yyyy').format(to!))),
          SizedBox(
              width: 130,
              child: TextField(
                  key: ValueKey('min-$resetKey'),
                  decoration: const InputDecoration(labelText: 'Min KWD'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => _debounced(() {
                        minimum = double.tryParse(v);
                        page = 0;
                      }))),
          SizedBox(
              width: 130,
              child: TextField(
                  key: ValueKey('max-$resetKey'),
                  decoration: const InputDecoration(labelText: 'Max KWD'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => _debounced(() {
                        maximum = double.tryParse(v);
                        page = 0;
                      }))),
          TextButton(
              onPressed: () => _reload(() {
                    partyType =
                        method = direction = branchId = documentType = 'All';
                    sort = 'Newest';
                    from = to = null;
                    minimum = maximum = null;
                    page = 0;
                    resetKey++;
                  }),
              child: const Text('Reset filters')),
        ]),
        const SizedBox(height: 12),
        Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
          future: _activityFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Center(
                  child: Text(
                      'Payment activity could not load: ${snapshot.error}'));
            if (snapshot.connectionState == ConnectionState.waiting ||
                !snapshot.hasData) {
              resultCount = 0;
              return const ReliqLoadingState(
                  message: 'Loading payment activity…',
                  detail: 'RELIQ is still working.');
            }
            final all = snapshot.data!;
            resultCount = all.length;
            final rows = all.take(pageSize).toList();
            if (rows.isEmpty)
              return const Center(child: Text('No payment activity found.'));
            return Card(
                child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = rows[i];
                final dt = DateTime.tryParse('${r['created_at'] ?? ''}');
                final amount = (r['amount'] as num? ?? 0).toDouble();
                return ListTile(
                  dense: true,
                  leading: Icon('${r['party_type']}' == 'Supplier'
                      ? Icons.arrow_upward
                      : Icons.arrow_downward),
                  title: Text(
                      '${r['party_name'] ?? r['party_type'] ?? 'Payment'}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${r['document_type'] ?? ''} • ${r['method'] ?? ''}${(r['allocation_count'] as num? ?? 0).toInt() > 0 ? ' • ${(r['allocation_count'] as num).toInt()} allocation(s)' : ''}${('${r['reference'] ?? ''}').isNotEmpty ? ' • Ref ${r['reference']}' : ''}${dt == null ? '' : ' • ${DateFormat('dd MMM yyyy, HH:mm').format(dt.toLocal())}'}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(amount.toStringAsFixed(3),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          if (r['whatsapp_share_at'] != null)
                            const Text('WhatsApp prepared',
                                style: TextStyle(
                                    fontSize: 10, color: V3Style.muted))
                        ]),
                    if (('${r['party_type']}' == 'Customer' ||
                            '${r['party_type']}' == 'Supplier') &&
                        amount > 0.000001)
                      PopupMenuButton<String>(
                        tooltip: 'Document actions',
                        icon: const Icon(Icons.share_outlined),
                        onSelected: (value) {
                          if (value == 'preview') _previewPayment(r);
                          if (value == 'save') _savePaymentPdf(r);
                          if (value == 'whatsapp') _whatsappPayment(r);
                          if (value == 'email') _emailPayment(r);
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
                  ]),
                );
              },
            ));
          },
        )),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton(
              onPressed: page == 0 ? null : () => _reload(() => page--),
              child: const Text('Previous')),
          const SizedBox(width: 10),
          Text('Page ${page + 1}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          OutlinedButton(
              onPressed: () {
                if (resultCount > pageSize) _reload(() => page++);
              },
              child: const Text('Next')),
        ]),
      ]),
    );
  }
}

class _AgingOverview extends StatelessWidget {
  const _AgingOverview();

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: FutureBuilder<List<Map<String, double>>>(
          future: Future.wait([
            AppDatabase.instance.receivablesAging(),
            AppDatabase.instance.payablesAging()
          ]),
          builder: (context, snapshot) {
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final receivable = snapshot.data![0], payable = snapshot.data![1];
            Widget panel(
                    String title, String subtitle, Map<String, double> data) =>
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 4),
                              Text(subtitle,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                              const SizedBox(height: 16),
                              for (final e in data.entries)
                                Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 7),
                                    child: Row(children: [
                                      Expanded(child: Text(e.key)),
                                      Text(e.value.toStringAsFixed(3),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800))
                                    ])),
                            ])));
            return LayoutBuilder(
                builder: (context, c) => c.maxWidth < 900
                    ? ListView(children: [
                        panel('Receivables aging', 'What customers still owe.',
                            receivable),
                        const SizedBox(height: 12),
                        panel('Payables aging',
                            'What is still owed to suppliers.', payable)
                      ])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Expanded(
                                child: panel('Receivables aging',
                                    'What customers still owe.', receivable)),
                            const SizedBox(width: 14),
                            Expanded(
                                child: panel(
                                    'Payables aging',
                                    'What is still owed to suppliers.',
                                    payable))
                          ]));
          },
        ),
      );
}

class _UnappliedCredits extends StatefulWidget {
  const _UnappliedCredits();
  @override
  State<_UnappliedCredits> createState() => _UnappliedCreditsState();
}

class _UnappliedCreditsState extends State<_UnappliedCredits> {
  String partyType = 'All';
  int refreshKey = 0;

  Future<void> _allocate(Map<String, Object?> payment) async {
    final type = (payment['party_type'] ?? '').toString();
    final partyId = (payment['party_id'] ?? '').toString();
    final maxAmount = (payment['unapplied_amount'] as num? ?? 0).toDouble();
    final docs = type == 'Customer'
        ? await AppDatabase.instance.openCustomerInvoices(partyId)
        : await AppDatabase.instance.openSupplierBills(partyId);
    if (!mounted) return;
    if (docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('There are no open documents to allocate this credit to.')));
      return;
    }
    final allocations = <String, double>{};
    var remaining = maxAmount;
    for (final d in docs) {
      if (remaining <= 0) break;
      final bal = (d['balance'] as num? ?? 0).toDouble();
      final a = remaining < bal ? remaining : bal;
      allocations[d['id'].toString()] = a;
      remaining -= a;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final applied = allocations.values.fold<double>(0, (a, b) => a + b);
        return AlertDialog(
          title: Text('Allocate Credit • ${payment['party_name']}'),
          content: SizedBox(
              width: 720,
              height: 500,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Available unapplied amount: ${maxAmount.toStringAsFixed(3)}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(
                        'Allocate the existing receipt/payment to open documents. The original payment record is preserved.',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                    const SizedBox(height: 12),
                    Expanded(
                        child: ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final d = docs[i];
                        final id = d['id'].toString();
                        final bal = (d['balance'] as num? ?? 0).toDouble();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${d['no'] ?? id}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              '${d['document_type'] ?? ''} • Balance ${bal.toStringAsFixed(3)}${d['due_date'] == null ? '' : ' • Due ${d['due_date'].toString().split('T').first}'}'),
                          trailing: SizedBox(
                              width: 150,
                              child: TextFormField(
                                key: ValueKey('ua-$id-${allocations[id] ?? 0}'),
                                initialValue:
                                    (allocations[id] ?? 0).toStringAsFixed(3),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration:
                                    const InputDecoration(labelText: 'Apply'),
                                onChanged: (v) {
                                  allocations[id] = (double.tryParse(v) ?? 0)
                                      .clamp(0, bal)
                                      .toDouble();
                                  setD(() {});
                                },
                              )),
                        );
                      },
                    )),
                    const SizedBox(height: 8),
                    Text(
                        'Applied ${applied.toStringAsFixed(3)} • Remaining ${(maxAmount - applied).clamp(0, double.infinity).toStringAsFixed(3)}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: applied > 0 && applied <= maxAmount + 0.000001
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Allocate')),
          ],
        );
      }),
    );
    if (ok == true) {
      try {
        await AppDatabase.instance
            .allocateUnappliedPayment(payment['id'].toString(), allocations);
        if (mounted) {
          setState(() => refreshKey++);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Unapplied payment allocated')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Unapplied Credits',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(
              'Payments or advances that still have value available to allocate against open invoices or supplier bills.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: partyType,
                decoration: const InputDecoration(labelText: 'Party type'),
                items: const ['All', 'Customer', 'Supplier']
                    .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                    .toList(),
                onChanged: (v) => setState(() => partyType = v ?? 'All'),
              )),
          const SizedBox(height: 12),
          Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
            key: ValueKey('unapplied-$refreshKey-$partyType'),
            future:
                AppDatabase.instance.unappliedPayments(partyType: partyType),
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Center(
                    child: Text(
                        'Unapplied credits could not load: ${snapshot.error}'));
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              if (rows.isEmpty)
                return const Center(
                    child: Text(
                        'No unapplied customer receipts or supplier advances.'));
              return Card(
                  child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = rows[i];
                  final amount =
                      (r['unapplied_amount'] as num? ?? 0).toDouble();
                  return ListTile(
                    leading: Icon(
                        '${r['party_type']}' == 'Customer'
                            ? Icons.south_west
                            : Icons.north_east,
                        color: Theme.of(context).colorScheme.primary),
                    title: Text('${r['party_name']}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        '${r['party_type']} • ${r['method'] ?? ''}${('${r['reference'] ?? ''}').isEmpty ? '' : ' • Ref ${r['reference']}'} • ${r['created_at'].toString().split('T').first}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(amount.toStringAsFixed(3),
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(width: 12),
                      FilledButton.tonal(
                          onPressed: () => _allocate(r),
                          child: const Text('Allocate')),
                    ]),
                  );
                },
              ));
            },
          )),
        ]),
      );
}

class _AccountingAdjustments extends StatefulWidget {
  const _AccountingAdjustments();
  @override
  State<_AccountingAdjustments> createState() => _AccountingAdjustmentsState();
}

class _AccountingAdjustmentsState extends State<_AccountingAdjustments> {
  int refreshKey = 0;
  String partyFilter = 'All';

  Future<void> _newAdjustment() async {
    final customers =
        await AppDatabase.instance.customers(activeOnly: true, limit: 1000);
    final suppliers =
        await AppDatabase.instance.suppliers(activeOnly: true, limit: 1000);
    if (!mounted) return;
    String partyType = 'Customer';
    String? partyId;
    String kind = 'Opening Receivable';
    String amount = '';
    String reference = '';
    String notes = '';
    DateTime? dueDate;
    List<String> kinds() => partyType == 'Customer'
        ? const [
            'Opening Receivable',
            'Opening Credit',
            'Customer Credit Note',
            'Customer Debit Note'
          ]
        : const [
            'Opening Payable',
            'Opening Advance',
            'Supplier Debit Note',
            'Supplier Credit Note'
          ];
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
              final options = partyType == 'Customer' ? customers : suppliers;
              return AlertDialog(
                title: const Text('Post Accounting Adjustment'),
                content: SizedBox(
                    width: 650,
                    child: SingleChildScrollView(
                        child: Column(children: [
                      Row(children: [
                        Expanded(
                            child: DropdownButtonFormField<String>(
                          initialValue: partyType,
                          decoration:
                              const InputDecoration(labelText: 'Party type'),
                          items: const ['Customer', 'Supplier']
                              .map((x) =>
                                  DropdownMenuItem(value: x, child: Text(x)))
                              .toList(),
                          onChanged: (v) => setD(() {
                            partyType = v ?? 'Customer';
                            partyId = null;
                            kind = kinds().first;
                          }),
                        )),
                        const SizedBox(width: 10),
                        Expanded(
                            child: DropdownButtonFormField<String>(
                          value: kinds().contains(kind) ? kind : kinds().first,
                          decoration:
                              const InputDecoration(labelText: 'Adjustment'),
                          items: kinds()
                              .map((x) =>
                                  DropdownMenuItem(value: x, child: Text(x)))
                              .toList(),
                          onChanged: (v) =>
                              setD(() => kind = v ?? kinds().first),
                        )),
                      ]),
                      const SizedBox(height: 12),
                      SearchableMapSelect(
                        options: options,
                        value: partyId,
                        labelText: partyType,
                        hintText: 'Type name, phone or email',
                        display: (r) => '${r['name']}',
                        subtitle: (r) =>
                            '${r['phone'] ?? ''} ${r['email'] ?? ''}',
                        onChanged: (v) => setD(() => partyId = v),
                      ),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: TextFormField(
                                onChanged: (v) => amount = v,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: const InputDecoration(
                                    labelText: 'Amount'))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: TextFormField(
                                onChanged: (v) => reference = v,
                                decoration: const InputDecoration(
                                    labelText: 'Reference / note no.'))),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: OutlinedButton.icon(
                          onPressed: () async {
                            final d = await showDatePicker(
                                context: ctx,
                                initialDate: dueDate ?? DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100));
                            if (d != null) setD(() => dueDate = d);
                          },
                          icon: const Icon(Icons.event_outlined),
                          label: Text(dueDate == null
                              ? 'Optional due date'
                              : DateFormat('dd MMM yyyy').format(dueDate!)),
                        )),
                        if (dueDate != null)
                          TextButton(
                              onPressed: () => setD(() => dueDate = null),
                              child: const Text('Clear')),
                      ]),
                      const SizedBox(height: 12),
                      TextFormField(
                          onChanged: (v) => notes = v,
                          maxLines: 3,
                          decoration: const InputDecoration(
                              labelText: 'Reason / notes')),
                      const SizedBox(height: 10),
                      Text(
                        partyType == 'Customer'
                            ? 'Customer Credit Note reduces receivables; Customer Debit Note increases receivables. Opening Credit records money/credit already owed to the customer.'
                            : 'Supplier Debit Note reduces payables; Supplier Credit Note increases payables. Opening Advance records money/credit already held by the supplier.',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed:
                          partyId != null && (double.tryParse(amount) ?? 0) > 0
                              ? () => Navigator.pop(ctx, true)
                              : null,
                      child: const Text('Post')),
                ],
              );
            }));
    if (ok == true && partyId != null) {
      try {
        await AppDatabase.instance.postPartyAdjustment(
            partyType: partyType,
            partyId: partyId!,
            kind: kind,
            amount: double.parse(amount),
            reference: reference,
            notes: notes,
            dueDate: dueDate);
        if (mounted) {
          setState(() => refreshKey++);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Accounting adjustment posted')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Future<void> _rebuild() async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Rebuild party balances?'),
              content: const Text(
                  'RELIQ will recalculate customer receivables and supplier payables from all open invoices, bills and opening/adjustment documents. Account credits are not changed.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Rebuild'))
              ],
            ));
    if (confirm == true) {
      try {
        await AppDatabase.instance.rebuildPartyBalancesFromDocuments();
        if (mounted) {
          setState(() => refreshKey++);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Party balances rebuilt from open documents')));
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Widget _metric(String label, double value, {bool difference = false}) =>
      Expanded(
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                        const SizedBox(height: 5),
                        Text(value.toStringAsFixed(3),
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: difference && value.abs() > 0.001
                                    ? Theme.of(context).colorScheme.error
                                    : null)),
                      ]))));

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Adjustments & Opening Balances',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text(
                      'Opening balances, credit/debit notes and accounting integrity controls.'),
                ])),
            OutlinedButton.icon(
                onPressed: _rebuild,
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Rebuild balances')),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: _newAdjustment,
                icon: const Icon(Icons.add),
                label: const Text('New Adjustment')),
          ]),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, double>>(
            key: ValueKey('integrity-$refreshKey'),
            future: AppDatabase.instance.accountingIntegritySummary(),
            builder: (context, snapshot) {
              final x = snapshot.data;
              if (x == null) return const LinearProgressIndicator();
              return Column(children: [
                Row(children: [
                  _metric('Customer master balance', x['customer_master'] ?? 0),
                  _metric('Customer open documents', x['customer_open'] ?? 0),
                  _metric('Customer difference', x['customer_difference'] ?? 0,
                      difference: true)
                ]),
                Row(children: [
                  _metric('Supplier master balance', x['supplier_master'] ?? 0),
                  _metric('Supplier open documents', x['supplier_open'] ?? 0),
                  _metric('Supplier difference', x['supplier_difference'] ?? 0,
                      difference: true)
                ]),
                Row(children: [
                  _metric('Customer credits', x['customer_credit'] ?? 0),
                  _metric('Supplier advances', x['supplier_credit'] ?? 0),
                  _metric('Unapplied payments', x['unapplied_payments'] ?? 0)
                ]),
              ]);
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                  initialValue: partyFilter,
                  decoration: const InputDecoration(labelText: 'Party type'),
                  items: const ['All', 'Customer', 'Supplier']
                      .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                      .toList(),
                  onChanged: (v) => setState(() => partyFilter = v ?? 'All'))),
          const SizedBox(height: 8),
          Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
            key: ValueKey('adjustments-$refreshKey-$partyFilter'),
            future:
                AppDatabase.instance.accountAdjustments(partyType: partyFilter),
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Center(
                    child:
                        Text('Adjustments could not load: ${snapshot.error}'));
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              if (rows.isEmpty)
                return const Center(
                    child: Text(
                        'No opening balances or credit/debit notes posted yet.'));
              return Card(
                  child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        final amount = (r['amount'] as num? ?? 0).toDouble();
                        final bal = (r['balance'] as num? ?? 0).toDouble();
                        return ListTile(
                          leading: const Icon(Icons.receipt_long_outlined),
                          title: Text('${r['kind']} • ${r['party_name']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: Text(
                              '${r['no']} • ${r['created_at'].toString().split('T').first}${('${r['reference'] ?? ''}').isEmpty ? '' : ' • Ref ${r['reference']}'}${('${r['notes'] ?? ''}').isEmpty ? '' : ' • ${r['notes']}'}'),
                          trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(amount.toStringAsFixed(3),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                Text('Open ${bal.toStringAsFixed(3)}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant))
                              ]),
                        );
                      }));
            },
          )),
        ]),
      );
}

class _PaymentReconciliation extends StatefulWidget {
  const _PaymentReconciliation();
  @override
  State<_PaymentReconciliation> createState() => _PaymentReconciliationState();
}

class _PaymentReconciliationState extends State<_PaymentReconciliation> {
  String status = 'Unreconciled';
  String method = 'All';
  int refreshKey = 0;

  Future<void> _toggle(Map<String, Object?> row) async {
    final already = row['reconciliation_id'] != null;
    if (already) {
      final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('Remove reconciliation?'),
                  content: Text(
                      'Clear the reconciliation for ${row['party_name']} • ${row['amount']}?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Remove'))
                  ]));
      if (ok == true) {
        try {
          await AppDatabase.instance.setPaymentReconciled(
              paymentId: row['id'].toString(), reconciled: false);
          if (mounted) setState(() => refreshKey++);
        } catch (e) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(e.toString().replaceFirst('Exception: ', ''))));
        }
      }
      return;
    }
    String accountType =
        (row['method'] ?? '').toString() == 'Cash' ? 'Cash' : 'Bank';
    String ref = '';
    String notes = '';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: const Text('Mark Payment Reconciled'),
                  content: SizedBox(
                      width: 500,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        DropdownButtonFormField<String>(
                            initialValue: accountType,
                            decoration: const InputDecoration(
                                labelText: 'Account / source'),
                            items: const [
                              'Bank',
                              'Cash',
                              'Card Clearing',
                              'Other'
                            ]
                                .map((x) =>
                                    DropdownMenuItem(value: x, child: Text(x)))
                                .toList(),
                            onChanged: (v) =>
                                setD(() => accountType = v ?? 'Bank')),
                        const SizedBox(height: 10),
                        TextFormField(
                            onChanged: (v) => ref = v,
                            decoration: const InputDecoration(
                                labelText: 'Statement / deposit reference')),
                        const SizedBox(height: 10),
                        TextFormField(
                            onChanged: (v) => notes = v,
                            maxLines: 2,
                            decoration:
                                const InputDecoration(labelText: 'Notes')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Reconcile'))
                  ],
                )));
    if (ok == true) {
      try {
        await AppDatabase.instance.setPaymentReconciled(
            paymentId: row['id'].toString(),
            reconciled: true,
            accountType: accountType,
            statementRef: ref,
            notes: notes);
        if (mounted) setState(() => refreshKey++);
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cash / Bank Reconciliation',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(
              'Match RELIQ payment activity to bank statements, card settlements, deposits or cash controls.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, double>>(
            key: ValueKey('recon-summary-$refreshKey'),
            future: AppDatabase.instance.paymentReconciliationSummary(),
            builder: (context, s) {
              final x = s.data;
              if (x == null) return const LinearProgressIndicator();
              return Row(children: [
                Expanded(
                    child:
                        _reconCard(context, 'Total payments', x['total'] ?? 0)),
                Expanded(
                    child: _reconCard(
                        context, 'Reconciled', x['reconciled'] ?? 0)),
                Expanded(
                    child: _reconCard(
                        context, 'Unreconciled', x['unreconciled'] ?? 0)),
              ]);
            },
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 8, children: [
            SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: const ['All', 'Unreconciled', 'Reconciled']
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => status = v ?? 'Unreconciled'))),
            SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                    initialValue: method,
                    decoration: const InputDecoration(labelText: 'Method'),
                    items: const [
                      'All',
                      'Cash',
                      'Card',
                      'Bank',
                      'Cheque',
                      'Other',
                      'Supplier Credit'
                    ]
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (v) => setState(() => method = v ?? 'All'))),
          ]),
          const SizedBox(height: 10),
          Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
            key: ValueKey('recon-$refreshKey-$status-$method'),
            future: AppDatabase.instance
                .paymentReconciliationRows(status: status, method: method),
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Center(
                    child: Text(
                        'Reconciliation could not load: ${snapshot.error}'));
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              if (rows.isEmpty)
                return const Center(
                    child: Text(
                        'No payments match these reconciliation filters.'));
              return Card(
                  child: ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        final done = r['reconciliation_id'] != null;
                        final amount = (r['amount'] as num? ?? 0).toDouble();
                        return ListTile(
                          leading: Icon(
                              done
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: done
                                  ? Colors.green
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                          title: Text(
                              '${r['party_name'] ?? r['party_type']} • ${amount.toStringAsFixed(3)}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: Text(
                              '${r['method'] ?? ''} • ${r['document_type'] ?? ''}${('${r['reference'] ?? ''}').isEmpty ? '' : ' • Ref ${r['reference']}'}${done ? ' • ${r['account_type'] ?? ''}${('${r['statement_ref'] ?? ''}').isEmpty ? '' : ' / ${r['statement_ref']}'}' : ''}'),
                          trailing: OutlinedButton(
                              onPressed: () => _toggle(r),
                              child: Text(done ? 'Unreconcile' : 'Reconcile')),
                        );
                      }));
            },
          )),
        ]),
      );

  Widget _reconCard(BuildContext context, String label, double value) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value.toStringAsFixed(3),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))
          ])));
}
