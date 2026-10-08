import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';

class DayBookScreen extends StatefulWidget {
  const DayBookScreen({super.key});
  @override
  State<DayBookScreen> createState() => _DayBookScreenState();
}

class _DayBookScreenState extends State<DayBookScreen> {
  DateTime day = DateTime.now();
  int refreshKey = 0;
  final openingCtrl = TextEditingController();
  final closingCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  final referenceCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  String movementKind = 'Bank Withdrawal';

  @override
  void dispose() {
    openingCtrl.dispose();
    closingCtrl.dispose();
    amountCtrl.dispose();
    referenceCtrl.dispose();
    noteCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, Object?>> _load() async {
    final values = await Future.wait([
      AppDatabase.instance.cashSummary(day),
      AppDatabase.instance.dayBook(day),
      AppDatabase.instance.cashMovements(day),
    ]);
    return {'cash': values[0], 'activity': values[1], 'moves': values[2]};
  }

  Future<void> pickDay() async {
    final v = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDate: day);
    if (v != null)
      setState(() {
        day = v;
        refreshKey++;
        openingCtrl.clear();
        closingCtrl.clear();
      });
  }

  Future<void> _saveOpening(Map<String, Object?> cash) async {
    final value = double.tryParse(openingCtrl.text.trim()) ??
        ((cash['opening_cash'] as num?) ?? 0).toDouble();
    await AppDatabase.instance
        .openCashDay(day, value, notes: noteCtrl.text.trim());
    if (mounted)
      setState(() {
        refreshKey++;
        openingCtrl.clear();
        noteCtrl.clear();
      });
  }

  Future<void> _saveMovement() async {
    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a cash amount greater than zero.')));
      return;
    }
    try {
      await AppDatabase.instance.addCashMovement(
          day: day,
          kind: movementKind,
          amount: amount,
          reference: referenceCtrl.text.trim(),
          notes: noteCtrl.text.trim());
      if (mounted)
        setState(() {
          refreshKey++;
          amountCtrl.clear();
          referenceCtrl.clear();
          noteCtrl.clear();
        });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _closeDay(Map<String, Object?> cash) async {
    final expected = ((cash['expected_cash'] as num?) ?? 0).toDouble();
    final actual = double.tryParse(closingCtrl.text.trim()) ?? expected;
    try {
      await AppDatabase.instance
          .closeCashDay(day, actual, notes: noteCtrl.text.trim());
      if (mounted)
        setState(() {
          refreshKey++;
          closingCtrl.clear();
          noteCtrl.clear();
        });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, Object?>>(
        key: ValueKey(refreshKey),
        future: _load(),
        builder: (context, snap) {
          if (!snap.hasData)
            return const Center(child: CircularProgressIndicator());
          final cash = (snap.data!['cash'] as Map).cast<String, Object?>();
          final rows =
              (snap.data!['activity'] as List).cast<Map<String, Object?>>();
          final moves =
              (snap.data!['moves'] as List).cast<Map<String, Object?>>();
          final expected = ((cash['expected_cash'] as num?) ?? 0).toDouble();
          final actual = cash['closing_cash'] as num?;
          final variance = ((cash['variance'] as num?) ?? 0).toDouble();

          return ListView(padding: V3Style.pagePadding, children: [
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Day Book & Cash Counter',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                        'Run the counter, record cash movements and review the full day history on one page.',
                        style: TextStyle(color: V3Style.mutedFor(context))),
                  ])),
              OutlinedButton.icon(
                  onPressed: pickDay,
                  icon: const Icon(Icons.calendar_month_outlined, size: 17),
                  label: Text(DateFormat('dd MMM yyyy').format(day))),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _metric('Opening', cash['opening_cash'], Icons.lock_open_outlined,
                  V3Style.blue),
              _metric('Cash Sales', cash['cash_sales'],
                  Icons.point_of_sale_outlined, V3Style.success),
              _metric('Receipts', cash['customer_cash'],
                  Icons.call_received_outlined, V3Style.teal),
              _metric('Cash Added', cash['cash_added'], Icons.add_card_outlined,
                  V3Style.purple),
              _metric('Supplier Paid', cash['supplier_cash'],
                  Icons.call_made_outlined, V3Style.warning),
              _metric('Expenses', cash['cash_expenses'],
                  Icons.receipt_long_outlined, const Color(0xFFE8590C)),
              _metric('Cash Removed', cash['cash_removed'],
                  Icons.account_balance_outlined, const Color(0xFF8B5CF6)),
              _metric(
                  'Expected', expected, Icons.calculate_outlined, V3Style.blue),
              _metric(
                  'Actual', actual, Icons.fact_check_outlined, V3Style.success),
              _metric('Variance', variance, Icons.balance_outlined,
                  variance.abs() < .001 ? V3Style.success : V3Style.danger),
            ]),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 1050;
              final children = [
                Expanded(
                    child: _actionCard(
                  'Opening Cash',
                  'Enter or correct the cash physically present when the counter opens.',
                  Icons.playlist_add,
                  [
                    TextField(
                        controller: openingCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                            labelText: 'Opening amount',
                            hintText: ((cash['opening_cash'] as num?) ?? 0)
                                .toStringAsFixed(3))),
                    const SizedBox(height: 9),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                            onPressed: () => _saveOpening(cash),
                            icon: const Icon(Icons.save_outlined),
                            label: Text(cash['id'] == null
                                ? 'Set Opening Cash'
                                : 'Update Opening Cash'))),
                  ],
                )),
                Expanded(
                    child: _actionCard(
                  'Add / Remove Cash',
                  'Record money introduced to or removed from the counter, including bank withdrawals and deposits.',
                  Icons.swap_vert,
                  [
                    DropdownButtonFormField<String>(
                        value: movementKind,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Movement'),
                        items: const [
                          'Bank Withdrawal',
                          'Cash Added',
                          'Bank Deposit',
                          'Cash Removed'
                        ]
                            .map((x) =>
                                DropdownMenuItem(value: x, child: Text(x)))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => movementKind = v ?? movementKind)),
                    const SizedBox(height: 9),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: amountCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration:
                                  const InputDecoration(labelText: 'Amount'))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: TextField(
                              controller: referenceCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'Reference'))),
                    ]),
                    const SizedBox(height: 9),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                            onPressed: _saveMovement,
                            icon: const Icon(Icons.add_card_outlined),
                            label: const Text('Record Cash Movement'))),
                  ],
                )),
                Expanded(
                    child: _actionCard(
                  'Close / Count Cash',
                  'Count the drawer. RELIQ compares actual cash with the expected closing balance.',
                  Icons.fact_check_outlined,
                  [
                    Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: V3Style.blue.withValues(alpha: .06),
                            borderRadius: BorderRadius.circular(9)),
                        child: Text(
                            'Expected closing: ${expected.toStringAsFixed(3)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800))),
                    const SizedBox(height: 9),
                    TextField(
                        controller: closingCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: 'Actual cash counted')),
                    const SizedBox(height: 9),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                            onPressed: () => _closeDay(cash),
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Close / Save Count'))),
                  ],
                )),
              ];
              if (narrow) {
                return Column(children: [
                  for (final c in children)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SizedBox(width: double.infinity, child: c.child))
                ]);
              }
              return IntrinsicHeight(
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    children[0],
                    const SizedBox(width: 10),
                    children[1],
                    const SizedBox(width: 10),
                    children[2]
                  ]));
            }),
            const SizedBox(height: 14),
            const Text('Day History',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                'Everything that changed cash on the selected date is shown below.',
                style: TextStyle(color: V3Style.mutedFor(context))),
            const SizedBox(height: 10),
            LayoutBuilder(
                builder: (context, c) => c.maxWidth < 900
                    ? Column(children: [
                        _activity(rows),
                        const SizedBox(height: 12),
                        _cashMoves(moves)
                      ])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Expanded(flex: 2, child: _activity(rows)),
                            const SizedBox(width: 12),
                            Expanded(child: _cashMoves(moves))
                          ])),
          ]);
        },
      );

  Widget _actionCard(
      String title, String subtitle, IconData icon, List<Widget> children) {
    final beforeAction = children.length > 1
        ? children.sublist(0, children.length - 1)
        : const <Widget>[];
    final action =
        children.isNotEmpty ? children.last : const SizedBox.shrink();
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: V3Style.blue),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))
        ]),
        const SizedBox(height: 4),
        Text(subtitle,
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        SizedBox(
          // Keep enough vertical room for the action button at larger text/touch
          // densities. The previous fixed height could push the bottom button beyond
          // the card boundary on smaller desktop windows.
          height: Theme.of(context).materialTapTargetSize ==
                  MaterialTapTargetSize.padded
              ? 302
              : 248,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ...beforeAction,
            const Spacer(),
            action,
          ]),
        ),
      ]),
    ));
  }

  Widget _metric(String label, Object? value, IconData icon, Color color) =>
      SizedBox(
          width: 165,
          height: 92,
          child: Card(
              clipBehavior: Clip.antiAlias,
              child: Container(
                decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: color, width: 3))),
                padding: const EdgeInsets.all(11),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(icon, size: 17, color: color),
                        const Spacer(),
                        Text(label.toUpperCase(),
                            style: const TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                color: V3Style.muted))
                      ]),
                      const Spacer(),
                      Text(
                          value == null
                              ? '—'
                              : ((value as num?) ?? 0).toStringAsFixed(3),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ]),
              )));

  Widget _activity(List<Map<String, Object?>> rows) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Transactions',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(25),
                  child: Center(child: Text('No activity on this date.'))),
            for (var i = 0; i < rows.take(100).length; i++)
              Container(
                color:
                    i.isOdd ? V3Style.rowStripe(context) : Colors.transparent,
                child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    leading: CircleAvatar(
                        radius: 16,
                        child: Icon(
                            _positive(rows[i]['type'].toString())
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                            size: 15)),
                    title: Text(
                        '${rows[i]['type']} • ${rows[i]['title'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${rows[i]['detail'] ?? ''}${DateTime.tryParse('${rows[i]['created_at'] ?? ''}') == null ? '' : ' • ${DateFormat('HH:mm').format(DateTime.parse('${rows[i]['created_at']}').toLocal())}'}'),
                    trailing: Text(
                        '${_positive(rows[i]['type'].toString()) ? '+' : '-'}${((rows[i]['amount'] as num?) ?? 0).abs().toStringAsFixed(3)}',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _positive(rows[i]['type'].toString())
                                ? V3Style.success
                                : V3Style.danger))),
              ),
          ])));

  bool _positive(String type) => type == 'Sale' || type == 'Customer Payment';

  Widget _cashMoves(List<Map<String, Object?>> rows) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Manual Cash Movements',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(22),
                  child: Center(child: Text('No manual cash movements.'))),
            for (var i = 0; i < rows.take(30).length; i++)
              Container(
                color:
                    i.isOdd ? V3Style.rowStripe(context) : Colors.transparent,
                child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    leading: const Icon(Icons.swap_vert, size: 18),
                    title: Text('${rows[i]['kind']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${rows[i]['reference'] ?? ''}${(rows[i]['notes'] ?? '').toString().isEmpty ? '' : ' • ${rows[i]['notes']}'}'),
                    trailing: Text(
                        ((rows[i]['amount'] as num?) ?? 0).toStringAsFixed(3),
                        style: const TextStyle(fontWeight: FontWeight.w800))),
              ),
          ])));
}
