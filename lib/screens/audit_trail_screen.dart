import 'package:file_picker/file_picker.dart';
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
  List<Map<String, Object?>> users = const [];
  List<Map<String, Object?>> branches = const [];

  String action = 'All';
  String entity = 'All';
  String userId = 'All';
  String branchId = 'All';
  DateTime? from;
  DateTime? to;

  int page = 0;
  int pageSize = 50;
  int total = 0;
  bool loading = true;
  bool busy = false;
  bool filtersLoaded = false;
  String? error;
  Map<String, Object?> stats = const {};

  @override
  void initState() {
    super.initState();
    _load(refreshFilters: true, refreshStats: true);
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load(
      {bool refreshFilters = false, bool refreshStats = false}) async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final futures = <Future<Object?>>[
        AppDatabase.instance.auditPage(
          search: search.text,
          action: action,
          entity: entity,
          userId: userId,
          branchId: branchId,
          from: from,
          to: to,
          limit: pageSize,
          offset: page * pageSize,
        ),
      ];
      final loadFilters = refreshFilters || !filtersLoaded;
      if (loadFilters) futures.add(AppDatabase.instance.auditFilterData());
      if (refreshStats || stats.isEmpty)
        futures.add(AppDatabase.instance.auditStats());

      final result = await Future.wait(futures);
      if (!mounted) return;

      final pageResult = result.first as Map<String, Object?>;
      var cursor = 1;
      Map<String, Object?>? filterResult;
      Map<String, Object?>? statsResult;
      if (loadFilters) filterResult = result[cursor++] as Map<String, Object?>;
      if (refreshStats || stats.isEmpty)
        statsResult = result[cursor] as Map<String, Object?>;

      final newTotal = (pageResult['total'] as num?)?.toInt() ?? 0;
      final maxPageIndex = newTotal == 0 ? 0 : (newTotal - 1) ~/ pageSize;
      if (page > maxPageIndex) {
        page = maxPageIndex;
        return _load(refreshFilters: false, refreshStats: refreshStats);
      }

      setState(() {
        rows = (pageResult['rows'] as List).cast<Map<String, Object?>>();
        total = newTotal;
        if (filterResult != null) {
          actions =
              (filterResult['actions'] as List?)?.map((e) => '$e').toList() ??
                  const [];
          entities =
              (filterResult['entities'] as List?)?.map((e) => '$e').toList() ??
                  const [];
          users =
              (filterResult['users'] as List?)?.cast<Map<String, Object?>>() ??
                  const [];
          branches = (filterResult['branches'] as List?)
                  ?.cast<Map<String, Object?>>() ??
              const [];
          filtersLoaded = true;
        }
        if (statsResult != null) stats = statsResult;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _pickDate(bool start) async {
    final current = start ? from : to;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        from = picked;
      } else {
        to = picked;
      }
      page = 0;
    });
    await _load();
  }

  void _clearFilters() {
    search.clear();
    setState(() {
      action = 'All';
      entity = 'All';
      userId = 'All';
      branchId = 'All';
      from = null;
      to = null;
      page = 0;
    });
    _load();
  }

  Future<void> _export() async {
    try {
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      var path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Audit Trail',
        fileName: 'RELIQ_Audit_$stamp.csv',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (path == null) return;
      if (!path.toLowerCase().endsWith('.csv')) path = '$path.csv';
      if (mounted) setState(() => busy = true);
      final count = await AppDatabase.instance.exportAuditCsvTo(
        path,
        search: search.text,
        action: action,
        entity: entity,
        userId: userId,
        branchId: branchId,
        from: from,
        to: to,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported $count audit events to $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Audit export failed: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _showArchives() async {
    try {
      setState(() => busy = true);
      final archives = await AppDatabase.instance.auditArchives();
      if (!mounted) return;
      setState(() => busy = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Archived audit history'),
          content: SizedBox(
            width: 760,
            height: 430,
            child: archives.isEmpty
                ? const Center(
                    child: Text('No audit archives have been created yet.'))
                : ListView.separated(
                    itemCount: archives.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final archive = archives[i];
                      final cutoff =
                          DateTime.tryParse('${archive['cutoff'] ?? ''}');
                      final cutoffText = cutoff == null
                          ? 'Unknown cutoff'
                          : 'Before ${DateFormat('dd MMM yyyy').format(cutoff)}';
                      return ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.archive_outlined, size: 18)),
                        title: Text('${archive['name'] ?? 'Audit archive'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${archive['rows'] ?? 0} events • $cutoffText • ${_bytes(archive['bytes'])}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.pop(ctx);
                          showDialog<void>(
                            context: context,
                            builder: (_) =>
                                _AuditArchiveDialog(archive: archive),
                          );
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Close'))
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Could not open audit archives: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      if (mounted && busy) setState(() => busy = false);
    }
  }

  Future<void> _archive() async {
    final initial = DateTime.now().subtract(const Duration(days: 365));
    final cutoff = await showDatePicker(
      context: context,
      helpText: 'Archive audit events older than',
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().subtract(const Duration(days: 30)),
    );
    if (cutoff == null || !mounted) return;
    final label = DateFormat('dd MMM yyyy').format(cutoff);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archive old audit history?'),
        content: SizedBox(
          width: 520,
          child: Text(
            'RELIQ will first create and verify a separate SQLite audit archive. '
            'Only after verification will events older than $label be removed from the live database.\n\n'
            'The archive is kept inside the RELIQ application-data folder and is not automatically deleted.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Create archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      setState(() => busy = true);
      final result = await AppDatabase.instance.archiveAuditOlderThan(cutoff);
      if (!mounted) return;
      final count = (result['rows'] as num?)?.toInt() ?? 0;
      final path = '${result['path'] ?? ''}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Archived $count audit events. Archive: $path')),
      );
      page = 0;
      await _load(refreshFilters: true, refreshStats: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Audit archive failed: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _details(Map<String, Object?> row) {
    final created = DateTime.tryParse('${row['created_at'] ?? ''}');
    final when = created == null
        ? '${row['created_at'] ?? ''}'
        : DateFormat('dd MMM yyyy • HH:mm:ss').format(created.toLocal());
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${row['action'] ?? 'Audit event'}'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detail('Time', when),
                _detail(
                  'User',
                  '${row['user_name'] ?? 'Unknown'}${(row['username'] ?? '').toString().isEmpty ? '' : ' (@${row['username']})'}',
                ),
                _detail('Branch',
                    '${row['branch_name'] ?? row['branch_id'] ?? '—'}'),
                _detail('Terminal',
                    '${row['terminal_name'] ?? row['terminal_id'] ?? '—'}'),
                _detail('Module', '${row['entity'] ?? '—'}'),
                _detail('Record ID', '${row['entity_id'] ?? '—'}'),
                const SizedBox(height: 8),
                const Text('Details',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                SelectableText('${row['details'] ?? ''}'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close'))
        ],
      ),
    );
  }

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 11,
                    color: V3Style.muted,
                    fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );

  String _bytes(Object? raw) {
    var value = (raw as num?)?.toDouble() ?? 0;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
  }

  String _dateText(Object? raw) {
    final value = DateTime.tryParse('${raw ?? ''}');
    return value == null
        ? '—'
        : DateFormat('dd MMM yyyy').format(value.toLocal());
  }

  Widget _metric(IconData icon, String label, String value) => Container(
        width: 195,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: V3Style.blue, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 10,
                          color: V3Style.muted,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd MMM yyyy');
    final pages = total == 0 ? 1 : ((total - 1) ~/ pageSize) + 1;
    final start = total == 0 ? 0 : (page * pageSize) + 1;
    final end = total == 0 ? 0 : ((page + 1) * pageSize).clamp(0, total);
    final anyFilter = search.text.trim().isNotEmpty ||
        action != 'All' ||
        entity != 'All' ||
        userId != 'All' ||
        branchId != 'All' ||
        from != null ||
        to != null;

    return Stack(
      children: [
        Padding(
          padding: V3Style.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Audit Trail',
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w800)),
                        SizedBox(height: 4),
                        Text(
                          'Indexed, paginated history of important business and security changes.',
                          style: TextStyle(color: V3Style.muted),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                      onPressed: busy ? null : _export,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Export CSV')),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                      onPressed: busy ? null : _showArchives,
                      icon: const Icon(Icons.folder_copy_outlined),
                      label: const Text('Archives')),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                      onPressed: busy ? null : _archive,
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Archive old history')),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _load(refreshFilters: true, refreshStats: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _metric(Icons.history_outlined, 'Live audit events',
                      '${stats['total'] ?? total}'),
                  _metric(Icons.calendar_month_outlined, 'Last 30 days',
                      '${stats['last_30_days'] ?? '—'}'),
                  _metric(Icons.storage_outlined, 'Estimated audit size',
                      _bytes(stats['estimated_bytes'])),
                  _metric(Icons.dns_outlined, 'Live database',
                      _bytes(stats['database_bytes'])),
                  _metric(Icons.archive_outlined, 'Archives',
                      '${stats['archive_count'] ?? 0} • ${_bytes(stats['archive_bytes'])}'),
                  _metric(Icons.first_page_outlined, 'Oldest live event',
                      _dateText(stats['oldest'])),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: search,
                          onSubmitted: (_) {
                            setState(() => page = 0);
                            _load();
                          },
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search action, user, record, details...',
                            suffixIcon: IconButton(
                              tooltip: 'Search',
                              onPressed: () {
                                setState(() => page = 0);
                                _load();
                              },
                              icon: const Icon(Icons.arrow_forward),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          value: action,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Action'),
                          items: ['All', ...actions]
                              .map((x) => DropdownMenuItem(
                                  value: x,
                                  child:
                                      Text(x, overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              action = v ?? 'All';
                              page = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 175,
                        child: DropdownButtonFormField<String>(
                          value: entity,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Module'),
                          items: ['All', ...entities]
                              .map((x) => DropdownMenuItem(
                                  value: x,
                                  child:
                                      Text(x, overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              entity = v ?? 'All';
                              page = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          value: userId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'User'),
                          items: [
                            const DropdownMenuItem(
                                value: 'All', child: Text('All users')),
                            ...users.map((u) {
                              final id = '${u['id'] ?? ''}';
                              final username = '${u['username'] ?? ''}';
                              final label =
                                  '${u['name'] ?? id}${username.isEmpty ? '' : ' (@$username)'}';
                              return DropdownMenuItem(
                                  value: id,
                                  child: Text(label,
                                      overflow: TextOverflow.ellipsis));
                            }),
                          ],
                          onChanged: (v) {
                            setState(() {
                              userId = v ?? 'All';
                              page = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 175,
                        child: DropdownButtonFormField<String>(
                          value: branchId,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Branch'),
                          items: [
                            const DropdownMenuItem(
                                value: 'All', child: Text('All branches')),
                            ...branches.map((b) => DropdownMenuItem(
                                  value: '${b['id'] ?? ''}',
                                  child: Text('${b['name'] ?? b['id'] ?? ''}',
                                      overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) {
                            setState(() {
                              branchId = v ?? 'All';
                              page = 0;
                            });
                            _load();
                          },
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _pickDate(true),
                        icon: const Icon(Icons.date_range),
                        label: Text(
                            from == null ? 'From date' : date.format(from!)),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _pickDate(false),
                        icon: const Icon(Icons.event),
                        label: Text(to == null ? 'To date' : date.format(to!)),
                      ),
                      if (anyFilter)
                        TextButton.icon(
                            onPressed: _clearFilters,
                            icon: const Icon(Icons.filter_alt_off),
                            label: const Text('Clear filters')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer)),
                  ),
                ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : rows.isEmpty
                        ? const Center(
                            child: Text('No audit events match these filters.'))
                        : Card(
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: [
                                Expanded(
                                  child: ListView.separated(
                                    itemCount: rows.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (_, i) {
                                      final row = rows[i];
                                      final created = DateTime.tryParse(
                                          '${row['created_at'] ?? ''}');
                                      final when = created == null
                                          ? '${row['created_at'] ?? ''}'
                                          : DateFormat('dd MMM yyyy HH:mm')
                                              .format(created.toLocal());
                                      final user =
                                          '${row['user_name'] ?? 'Unknown'}';
                                      final location = [
                                        row['branch_name'],
                                        row['terminal_name']
                                      ]
                                          .where((x) =>
                                              x != null && '$x'.isNotEmpty)
                                          .join(' • ');
                                      return ListTile(
                                        dense: true,
                                        leading: CircleAvatar(
                                            child: Icon(
                                                _iconFor(
                                                    '${row['action'] ?? ''}'),
                                                size: 18)),
                                        title: Row(
                                          children: [
                                            Expanded(
                                                child: Text(
                                                    '${row['action'] ?? ''}',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w800))),
                                            Text(when,
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: V3Style.muted)),
                                          ],
                                        ),
                                        subtitle: Text(
                                          '$user • ${row['entity'] ?? ''}${(row['entity_id'] ?? '').toString().isEmpty ? '' : ' • ${row['entity_id']}'}'
                                          '${location.isEmpty ? '' : '\n$location'}\n${row['details'] ?? ''}',
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        isThreeLine: true,
                                        trailing:
                                            const Icon(Icons.chevron_right),
                                        onTap: () => _details(row),
                                      );
                                    },
                                  ),
                                ),
                                const Divider(height: 1),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 9),
                                  child: Row(
                                    children: [
                                      Expanded(
                                          child: Text(
                                              'Showing $start–$end of $total',
                                              style: const TextStyle(
                                                  color: V3Style.muted))),
                                      const Text('Rows:'),
                                      const SizedBox(width: 6),
                                      DropdownButton<int>(
                                        value: pageSize,
                                        items: const [25, 50, 100]
                                            .map((n) => DropdownMenuItem(
                                                value: n, child: Text('$n')))
                                            .toList(),
                                        onChanged: (value) {
                                          if (value == null) return;
                                          setState(() {
                                            pageSize = value;
                                            page = 0;
                                          });
                                          _load();
                                        },
                                      ),
                                      const SizedBox(width: 18),
                                      Text('Page ${page + 1} of $pages',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      IconButton(
                                        tooltip: 'Previous page',
                                        onPressed: page > 0
                                            ? () {
                                                setState(() => page--);
                                                _load();
                                              }
                                            : null,
                                        icon: const Icon(Icons.chevron_left),
                                      ),
                                      IconButton(
                                        tooltip: 'Next page',
                                        onPressed: page + 1 < pages
                                            ? () {
                                                setState(() => page++);
                                                _load();
                                              }
                                            : null,
                                        icon: const Icon(Icons.chevron_right),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
              ),
            ],
          ),
        ),
        if (busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black26,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 18),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5)),
                        SizedBox(width: 12),
                        Text('Working on audit history…',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  IconData _iconFor(String action) {
    final x = action.toLowerCase();
    if (x.contains('delete') || x.contains('void') || x.contains('disable'))
      return Icons.warning_amber_outlined;
    if (x.contains('login') || x.contains('user')) return Icons.person_outline;
    if (x.contains('stock') || x.contains('product'))
      return Icons.inventory_2_outlined;
    if (x.contains('payment') || x.contains('sale') || x.contains('purchase'))
      return Icons.receipt_long_outlined;
    if (x.contains('setting') || x.contains('branch'))
      return Icons.settings_outlined;
    if (x.contains('archive')) return Icons.archive_outlined;
    return Icons.history_outlined;
  }
}

class _AuditArchiveDialog extends StatefulWidget {
  final Map<String, Object?> archive;
  const _AuditArchiveDialog({required this.archive});

  @override
  State<_AuditArchiveDialog> createState() => _AuditArchiveDialogState();
}

class _AuditArchiveDialogState extends State<_AuditArchiveDialog> {
  final search = TextEditingController();
  List<Map<String, Object?>> rows = const [];
  int total = 0;
  int page = 0;
  int pageSize = 50;
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
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await AppDatabase.instance.auditArchivePage(
        '${widget.archive['path'] ?? ''}',
        search: search.text,
        limit: pageSize,
        offset: page * pageSize,
      );
      if (!mounted) return;
      final newTotal = (result['total'] as num?)?.toInt() ?? 0;
      final maxPage = newTotal == 0 ? 0 : (newTotal - 1) ~/ pageSize;
      if (page > maxPage) {
        page = maxPage;
        return _load();
      }
      setState(() {
        rows = (result['rows'] as List).cast<Map<String, Object?>>();
        total = newTotal;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = total == 0 ? 1 : ((total - 1) ~/ pageSize) + 1;
    final start = total == 0 ? 0 : page * pageSize + 1;
    final end = total == 0 ? 0 : ((page + 1) * pageSize).clamp(0, total);
    return Dialog(
      child: SizedBox(
        width: 980,
        height: 720,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.archive_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Archived Audit History',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w800)),
                        Text('${widget.archive['name'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: V3Style.muted)),
                      ],
                    ),
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: search,
                onSubmitted: (_) {
                  setState(() => page = 0);
                  _load();
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText:
                      'Search archived action, user, record or details...',
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() => page = 0);
                      _load();
                    },
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                      ? const Center(
                          child: Text('No archived events match this search.'))
                      : ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final row = rows[i];
                            final created =
                                DateTime.tryParse('${row['created_at'] ?? ''}');
                            final when = created == null
                                ? '${row['created_at'] ?? ''}'
                                : DateFormat('dd MMM yyyy HH:mm')
                                    .format(created.toLocal());
                            return ListTile(
                              dense: true,
                              title: Row(children: [
                                Expanded(
                                    child: Text('${row['action'] ?? ''}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800))),
                                Text(when,
                                    style: const TextStyle(
                                        fontSize: 11, color: V3Style.muted)),
                              ]),
                              subtitle: Text(
                                '${row['user_name'] ?? row['user_id'] ?? row['user'] ?? 'Unknown'} • ${row['entity'] ?? ''}${(row['entity_id'] ?? '').toString().isEmpty ? '' : ' • ${row['entity_id']}'}\n${row['details'] ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                      child: Text('Showing $start–$end of $total',
                          style: const TextStyle(color: V3Style.muted))),
                  const Text('Rows:'),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    value: pageSize,
                    items: const [25, 50, 100]
                        .map((n) =>
                            DropdownMenuItem(value: n, child: Text('$n')))
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        pageSize = value;
                        page = 0;
                      });
                      _load();
                    },
                  ),
                  const SizedBox(width: 14),
                  Text('Page ${page + 1} of $pages',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  IconButton(
                    onPressed: page > 0
                        ? () {
                            setState(() => page--);
                            _load();
                          }
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    onPressed: page + 1 < pages
                        ? () {
                            setState(() => page++);
                            _load();
                          }
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
