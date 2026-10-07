import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/reliq_loading.dart';
import '../ui/reliq_surface.dart';
import '../ui/v3_style.dart';

class PartyLedgerAction {
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool primary;
  final bool danger;

  const PartyLedgerAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });
}

class PartyLedgerDetailScreen extends StatefulWidget {
  final String partyType;
  final String partyId;
  final String initialName;
  final List<PartyLedgerAction> Function(Map<String, Object?> party) actionsBuilder;
  final VoidCallback? onBack;

  const PartyLedgerDetailScreen({
    super.key,
    required this.partyType,
    required this.partyId,
    required this.actionsBuilder,
    this.initialName = '',
    this.onBack,
  });

  @override
  State<PartyLedgerDetailScreen> createState() => _PartyLedgerDetailScreenState();
}

class _PartyLedgerDetailScreenState extends State<PartyLedgerDetailScreen> {
  late Future<_PartyLedgerData> _future;

  bool get _customer => widget.partyType == 'Customer';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PartyLedgerData> _load() async {
    final partyRows = _customer
        ? await AppDatabase.instance.customers(search: widget.partyId, limit: 5)
        : await AppDatabase.instance.suppliers(search: widget.partyId, limit: 5);
    final exact = partyRows.where((x) => (x['id'] ?? '').toString() == widget.partyId).toList();
    final party = exact.isNotEmpty
        ? exact.first
        : (partyRows.isNotEmpty ? partyRows.first : <String, Object?>{'id': widget.partyId, 'name': widget.initialName});
    final ledger = _customer
        ? await AppDatabase.instance.customerStatement(widget.partyId)
        : await AppDatabase.instance.supplierStatement(widget.partyId);
    final openItems = _customer
        ? await AppDatabase.instance.openCustomerInvoices(widget.partyId)
        : await AppDatabase.instance.openSupplierBills(widget.partyId);

    double running = 0;
    final rows = <Map<String, Object?>>[];
    for (final source in ledger) {
      final debit = (source['debit'] as num? ?? 0).toDouble();
      final credit = (source['credit'] as num? ?? 0).toDouble();
      running += debit - credit;
      rows.add({...source, 'running_balance': running});
    }
    final openTotal = openItems.fold<double>(0, (sum, row) => sum + (row['balance'] as num? ?? 0).toDouble());
    return _PartyLedgerData(party: party, rows: rows, openItems: openItems, openTotal: openTotal);
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _future = _load());
  }

  Future<void> _runAction(PartyLedgerAction action) async {
    try {
      await action.onPressed();
    } finally {
      if (mounted) _reload();
    }
  }


  String _date(Object? raw) {
    final value = raw?.toString() ?? '';
    final dt = DateTime.tryParse(value)?.toLocal();
    if (dt == null) return value;
    return DateFormat('dd MMM yyyy, HH:mm').format(dt);
  }

  Widget _summaryTile(BuildContext context, String label, String value, IconData icon, {Color? valueColor}) {
    return SizedBox(
      width: 215,
      child: ReliqGlass(
        blur: 12,
        radius: 15,
        reflectionStrength: .34,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: V3Style.labelAccent(context).withValues(alpha: .10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 20, color: V3Style.labelAccent(context)),
          ),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: valueColor)),
          ])),
        ]),
      ),
    );
  }

  Widget _ledgerHeader(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    TextStyle style = TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: V3Style.tableHeader(context),
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(children: [
        SizedBox(width: 150, child: Text('DATE', style: style)),
        SizedBox(width: 130, child: Text('TYPE', style: style)),
        Expanded(flex: 3, child: Text('REFERENCE', style: style)),
        SizedBox(width: 120, child: Text(_customer ? 'CHARGE' : 'PAYABLE +', textAlign: TextAlign.right, style: style)),
        SizedBox(width: 120, child: Text(_customer ? 'PAYMENT / CREDIT' : 'PAYMENT / CREDIT', textAlign: TextAlign.right, style: style)),
        SizedBox(width: 125, child: Text('RUNNING', textAlign: TextAlign.right, style: style)),
      ]),
    );
  }

  Widget _ledgerRow(BuildContext context, Map<String, Object?> row, int index) {
    final debit = (row['debit'] as num? ?? 0).toDouble();
    final credit = (row['credit'] as num? ?? 0).toDouble();
    final running = (row['running_balance'] as num? ?? 0).toDouble();
    final type = (row['type'] ?? '').toString();
    final ref = (row['reference'] ?? '').toString();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      color: index.isOdd ? V3Style.rowStripe(context).withValues(alpha: dark ? .42 : .48) : Colors.transparent,
      child: Row(children: [
        SizedBox(width: 150, child: Text(_date(row['date']), style: TextStyle(fontSize: 12, color: muted))),
        SizedBox(width: 130, child: Text(type, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
        Expanded(flex: 3, child: Text(ref.isEmpty ? '—' : ref, overflow: TextOverflow.ellipsis)),
        SizedBox(width: 120, child: Text(debit == 0 ? '—' : debit.toStringAsFixed(3), textAlign: TextAlign.right, style: TextStyle(fontWeight: debit > 0 ? FontWeight.w700 : FontWeight.w400))),
        SizedBox(width: 120, child: Text(credit == 0 ? '—' : credit.toStringAsFixed(3), textAlign: TextAlign.right, style: TextStyle(fontWeight: credit > 0 ? FontWeight.w700 : FontWeight.w400, color: credit > 0 ? V3Style.success : null))),
        SizedBox(width: 125, child: Text(running.toStringAsFixed(3), textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w800, color: running > 0 ? Theme.of(context).colorScheme.error : (running < 0 ? V3Style.success : null)))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ReliqWorkspaceBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: widget.onBack == null ? null : IconButton(tooltip: 'Back to ${widget.partyType.toLowerCase()} list', onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
          automaticallyImplyLeading: widget.onBack == null,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text('${widget.partyType} Ledger'),
        ),
        body: FutureBuilder<_PartyLedgerData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('Could not load ${widget.partyType.toLowerCase()} ledger: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return ReliqLoadingState(message: 'Loading ${widget.partyType.toLowerCase()} ledger…', detail: 'RELIQ is reading invoices, payments, returns and adjustments.');
            }
            final data = snapshot.data!;
            final party = data.party;
            final actions = widget.actionsBuilder(party);
            final balance = (party['balance'] as num? ?? 0).toDouble();
            final overdue = (party['overdue_balance'] as num? ?? 0).toDouble();
            final credit = (party['credit_balance'] as num? ?? 0).toDouble();
            final phone = (party['phone'] ?? '').toString();
            final whatsapp = (party['whatsapp'] ?? '').toString();
            final email = (party['email'] ?? '').toString();
            final address = (party['address'] ?? '').toString();
            final active = ((party['active'] as num?) ?? 1).toInt() == 1;

            return Padding(
              padding: V3Style.pagePadding,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ReliqGlass(
                  blur: 16,
                  strong: true,
                  radius: 18,
                  reflectionStrength: .42,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: V3Style.labelAccent(context).withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(_customer ? Icons.person_outline : Icons.local_shipping_outlined, size: 28, color: V3Style.labelAccent(context)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text((party['name'] ?? widget.initialName).toString(), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900), overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: (active ? V3Style.success : V3Style.muted).withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: (active ? V3Style.success : V3Style.muted).withValues(alpha: .28)),
                            ),
                            child: Text(active ? 'Active' : 'Inactive', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: active ? V3Style.success : Theme.of(context).colorScheme.onSurfaceVariant)),
                          ),
                        ]),
                        const SizedBox(height: 5),
                        Wrap(spacing: 14, runSpacing: 5, children: [
                          if (phone.isNotEmpty) _InlineInfo(Icons.phone_outlined, phone),
                          if (whatsapp.isNotEmpty && whatsapp != phone) _InlineInfo(Icons.chat_outlined, whatsapp),
                          if (email.isNotEmpty) _InlineInfo(Icons.mail_outline, email),
                          if (address.isNotEmpty) _InlineInfo(Icons.location_on_outlined, address),
                        ]),
                      ])),
                    ]),
                    const SizedBox(height: 16),
                    Wrap(spacing: 10, runSpacing: 10, children: actions.map((action) {
                      if (action.primary) {
                        return FilledButton.icon(onPressed: () => _runAction(action), icon: Icon(action.icon), label: Text(action.label));
                      }
                      return OutlinedButton.icon(
                        onPressed: () => _runAction(action),
                        style: action.danger ? OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error) : null,
                        icon: Icon(action.icon),
                        label: Text(action.label),
                      );
                    }).toList()),
                  ]),
                ),
                const SizedBox(height: 14),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _summaryTile(context, _customer ? 'Outstanding' : 'Payable', balance.toStringAsFixed(3), _customer ? Icons.receipt_long_outlined : Icons.account_balance_wallet_outlined, valueColor: balance > 0 ? Theme.of(context).colorScheme.error : null),
                  _summaryTile(context, 'Overdue', overdue.toStringAsFixed(3), Icons.schedule_outlined, valueColor: overdue > 0 ? V3Style.danger : null),
                  _summaryTile(context, _customer ? 'Account credit' : 'Supplier advance', credit.toStringAsFixed(3), Icons.savings_outlined, valueColor: credit > 0 ? V3Style.success : null),
                  _summaryTile(context, 'Open documents', '${data.openItems.length} • ${data.openTotal.toStringAsFixed(3)}', Icons.folder_open_outlined),
                  if (_customer)
                    _summaryTile(context, 'Credit terms', '${party['terms_days'] ?? 0} days', Icons.event_available_outlined)
                  else
                    _summaryTile(context, 'Terms / lead', '${party['terms_days'] ?? 0}d / ${party['lead_days'] ?? 0}d', Icons.local_shipping_outlined),
                ]),
                const SizedBox(height: 14),
                Expanded(
                  child: ReliqGlass(
                    blur: 10,
                    radius: 18,
                    reflectionStrength: .20,
                    padding: EdgeInsets.zero,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Row(children: [
                          const Expanded(child: Text('Full Ledger History', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
                          Text('${data.rows.length} entries', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          const SizedBox(width: 8),
                          IconButton(tooltip: 'Refresh ledger', onPressed: _reload, icon: const Icon(Icons.refresh)),
                        ]),
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      _ledgerHeader(context),
                      Expanded(
                        child: data.rows.isEmpty
                            ? Center(child: Text('No ledger activity recorded yet.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)))
                            : ListView.separated(
                                itemCount: data.rows.length,
                                separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).dividerColor.withValues(alpha: .65)),
                                itemBuilder: (context, index) => _ledgerRow(context, data.rows[index], index),
                              ),
                      ),
                    ]),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _InlineInfo extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InlineInfo(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]);
}

class _PartyLedgerData {
  final Map<String, Object?> party;
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> openItems;
  final double openTotal;

  const _PartyLedgerData({required this.party, required this.rows, required this.openItems, required this.openTotal});
}
