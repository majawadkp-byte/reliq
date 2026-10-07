import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';

class AuditTrailScreen extends StatefulWidget {
  const AuditTrailScreen({super.key});

  @override
  State<AuditTrailScreen> createState() => _AuditTrailScreenState();
}

class _AuditTrailScreenState extends State<AuditTrailScreen> {
  final search = TextEditingController();
  List<Map<String, Object?>> rows = const [];
  List<String> actions = const [];
  List<String> entities = const [];
  String action = 'All';
  String entity = 'All';
  DateTime? from;
  DateTime? to;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final result = await Future.wait([
        AppDatabase.instance.auditEntries(search: search.text, action: action, entity: entity, from: from, to: to),
        AppDatabase.instance.auditFilterOptions(),
      ]);
      if (!mounted) return;
      final filters = result[1] as Map<String, List<String>>;
      setState(() {
        rows = result[0] as List<Map<String, Object?>>;
        actions = filters['actions'] ?? const [];
        entities = filters['entities'] ?? const [];
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  Future<void> _pickDate(bool start) async {
    final current = start ? from : to;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() { if (start) from = picked; else to = picked; });
    await _load();
  }

  void _details(Map<String, Object?> row) {
    final created = DateTime.tryParse('${row['created_at'] ?? ''}');
    final when = created == null ? '${row['created_at'] ?? ''}' : DateFormat('dd MMM yyyy • HH:mm:ss').format(created.toLocal());
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${row['action'] ?? 'Audit event'}'),
        content: SizedBox(
          width: 620,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _detail('Time', when),
            _detail('User', '${row['user_name'] ?? 'Unknown'}${(row['username'] ?? '').toString().isEmpty ? '' : ' (@${row['username']})'}'),
            _detail('Branch', '${row['branch_name'] ?? row['branch_id'] ?? '—'}'),
            _detail('Terminal', '${row['terminal_name'] ?? row['terminal_id'] ?? '—'}'),
            _detail('Entity', '${row['entity'] ?? '—'}'),
            _detail('Entity ID', '${row['entity_id'] ?? '—'}'),
            const SizedBox(height: 8),
            const Text('Details', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            SelectableText('${row['details'] ?? ''}'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 11, color: V3Style.muted, fontWeight: FontWeight.w700))),
      Expanded(child: SelectableText(value)),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd MMM yyyy');
    return Padding(
      padding: V3Style.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Audit Trail', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            SizedBox(height: 4),
            Text('Review sensitive activity by user, branch, terminal, entity and timestamp.', style: TextStyle(color: V3Style.muted)),
          ])),
          OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
        ]),
        const SizedBox(height: 14),
        Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(width: 300, child: TextField(
              controller: search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search user, action, entity, ID, details...', suffixIcon: IconButton(onPressed: _load, icon: const Icon(Icons.arrow_forward))),
            )),
            SizedBox(width: 210, child: DropdownButtonFormField<String>(
              initialValue: action,
              decoration: const InputDecoration(labelText: 'Action'),
              items: ['All', ...actions].map((x) => DropdownMenuItem(value: x, child: Text(x, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) { setState(() => action = v ?? 'All'); _load(); },
            )),
            SizedBox(width: 180, child: DropdownButtonFormField<String>(
              initialValue: entity,
              decoration: const InputDecoration(labelText: 'Entity'),
              items: ['All', ...entities].map((x) => DropdownMenuItem(value: x, child: Text(x, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) { setState(() => entity = v ?? 'All'); _load(); },
            )),
            OutlinedButton.icon(onPressed: () => _pickDate(true), icon: const Icon(Icons.date_range), label: Text(from == null ? 'From date' : date.format(from!))),
            OutlinedButton.icon(onPressed: () => _pickDate(false), icon: const Icon(Icons.event), label: Text(to == null ? 'To date' : date.format(to!))),
            if (from != null || to != null) TextButton(onPressed: () { setState(() { from = null; to = null; }); _load(); }, child: const Text('Clear dates')),
          ]),
        )),
        const SizedBox(height: 12),
        if (error != null) Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(14), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)))),
        if (loading) const Expanded(child: Center(child: CircularProgressIndicator())) else Expanded(
          child: rows.isEmpty
            ? const Center(child: Text('No audit events match these filters.'))
            : Card(clipBehavior: Clip.antiAlias, child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final row = rows[i];
                  final created = DateTime.tryParse('${row['created_at'] ?? ''}');
                  final when = created == null ? '${row['created_at'] ?? ''}' : DateFormat('dd MMM yyyy HH:mm').format(created.toLocal());
                  final user = '${row['user_name'] ?? 'Unknown'}';
                  final location = [row['branch_name'], row['terminal_name']].where((x) => x != null && '$x'.isNotEmpty).join(' • ');
                  return ListTile(
                    dense: false,
                    leading: CircleAvatar(child: Icon(_iconFor('${row['action'] ?? ''}'), size: 19)),
                    title: Row(children: [
                      Expanded(child: Text('${row['action'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800))),
                      Text(when, style: const TextStyle(fontSize: 11, color: V3Style.muted)),
                    ]),
                    subtitle: Text('$user • ${row['entity'] ?? ''}${(row['entity_id'] ?? '').toString().isEmpty ? '' : ' • ${row['entity_id']}'}${location.isEmpty ? '' : '\n$location'}\n${row['details'] ?? ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _details(row),
                  );
                },
              )),
        ),
      ]),
    );
  }

  IconData _iconFor(String action) {
    final x = action.toLowerCase();
    if (x.contains('delete') || x.contains('void') || x.contains('disable')) return Icons.warning_amber_outlined;
    if (x.contains('login') || x.contains('user')) return Icons.person_outline;
    if (x.contains('stock') || x.contains('product')) return Icons.inventory_2_outlined;
    if (x.contains('payment') || x.contains('sale') || x.contains('purchase')) return Icons.receipt_long_outlined;
    if (x.contains('setting') || x.contains('branch')) return Icons.settings_outlined;
    return Icons.history_outlined;
  }
}
