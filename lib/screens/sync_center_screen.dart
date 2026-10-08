import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/sync_service.dart';
import '../ui/v3_style.dart';

class SyncCenterScreen extends StatefulWidget {
  const SyncCenterScreen({super.key});

  @override
  State<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends State<SyncCenterScreen> {
  final _server = TextEditingController();
  final _company = TextEditingController();
  final _token = TextEditingController();
  final _enrollment = TextEditingController();
  bool _enabled = false;
  bool _busy = false;
  bool _hideToken = true;
  Map<String, String> _identity = const {};
  Map<String, int> _summary = const {};
  List<Map<String, Object?>> _activity = const [];
  List<Map<String, Object?>> _incoming = const [];
  List<Map<String, Object?>> _conflicts = const [];
  String _lastSuccess = '';
  String _lastError = '';
  String _status = 'Not connected';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _server.dispose();
    _company.dispose();
    _token.dispose();
    _enrollment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      AppDatabase.instance.settings(),
      AppDatabase.instance.syncIdentity(),
      AppDatabase.instance.syncQueueSummary(),
      AppDatabase.instance.recentSyncActivity(limit: 50),
      AppDatabase.instance.stagedIncoming(limit: 50),
      AppDatabase.instance.syncRuntimeState(),
      AppDatabase.instance.openSyncConflicts(limit: 50),
    ]);
    if (!mounted) return;
    final settings = values[0] as Map<String, String>;
    final identity = values[1] as Map<String, String>;
    setState(() {
      _server.text = settings['sync_server_url'] ?? '';
      _company.text =
          settings['sync_company_key'] ?? identity['company_id'] ?? '';
      _token.text = settings['sync_api_token'] ?? '';
      _enrollment.text = settings['sync_enrollment_key'] ?? '';
      _enabled = settings['sync_enabled'] == '1';
      final runtime = values[5] as Map<String, String>;
      _lastSuccess = runtime['last_success_at'] ?? '';
      _lastError = runtime['last_error'] ?? '';
      _identity = identity;
      _summary = values[2] as Map<String, int>;
      _activity = values[3] as List<Map<String, Object?>>;
      _incoming = values[4] as List<Map<String, Object?>>;
      _status = (identity['server_device_id'] ?? '').isNotEmpty
          ? 'Registered'
          : 'Local only';
      _conflicts = values[6] as List<Map<String, Object?>>;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await AppDatabase.instance.saveSettings({
        'sync_enabled': _enabled ? '1' : '0',
        'sync_server_url': _server.text.trim(),
        'sync_company_key': _company.text.trim(),
        'sync_api_token': _token.text.trim(),
        'sync_enrollment_key': _enrollment.text.trim(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Sync settings saved.')));
      await _load();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _health() async {
    setState(() {
      _busy = true;
      _status = 'Checking…';
    });
    try {
      await _persistConnectionFields();
      final response = await SyncService.instance.health();
      if (!mounted) return;
      setState(() => _status = response['version'] == null
          ? 'Server reachable'
          : 'Server ${response['version']} reachable');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync server is reachable.')));
    } catch (e) {
      if (mounted) setState(() => _status = 'Connection failed');
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() async {
    setState(() => _busy = true);
    try {
      await _persistConnectionFields();
      final id = await SyncService.instance.registerDevice();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Device registered: $id')));
      await _load();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await _persistConnectionFields();
      final result = await SyncService.instance.syncNow();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Sync complete: ${result.pushed} pushed, ${result.pulled} pulled, ${result.applied} applied, ${result.conflicts} conflict(s), ${result.failed} failed.')));
      await _load();
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      await AppDatabase.instance.setSyncRuntime({
        'last_attempt_at': DateTime.now().toUtc().toIso8601String(),
        'last_error': message
      });
      _showError(e);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    setState(() => _busy = true);
    try {
      final event = await SyncService.instance.queueTransportTest();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transport probe queued: $event')));
      await _load();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    await AppDatabase.instance.resetFailedSyncEvents();
    await _load();
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed sync events moved back to Pending.')));
  }

  Future<void> _applyIncoming() async {
    setState(() => _busy = true);
    try {
      final result =
          await AppDatabase.instance.applyPendingIncomingEvents(limit: 500);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Incoming applied: ${result['applied'] ?? 0}; conflicts: ${result['conflicts'] ?? 0}; failed: ${result['failed'] ?? 0}.'),
      ));
      await _load();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bootstrapMasters() async {
    setState(() => _busy = true);
    try {
      await AppDatabase.instance.queueInitialMasterSnapshot();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Current branches, customer groups, products, customers, suppliers and inventory baseline queued for initial sync.')));
      await _load();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _persistConnectionFields() => AppDatabase.instance.saveSettings({
        'sync_enabled': _enabled ? '1' : '0',
        'sync_server_url': _server.text.trim(),
        'sync_company_key': _company.text.trim(),
        'sync_api_token': _token.text.trim(),
        'sync_enrollment_key': _enrollment.text.trim(),
      });

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString().replaceFirst('Exception: ', ''))));
  }

  String _when(String raw) {
    final dt = DateTime.tryParse(raw);
    return dt == null
        ? 'Never'
        : DateFormat('dd MMM yyyy, HH:mm:ss').format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: V3Style.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Sync Center',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                    '8.0D production sync — secure device enrollment, per-device credentials, tenant isolation and deployment health.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ])),
          if (_busy)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          FilledButton.icon(
              onPressed: _busy || !_enabled ? null : _sync,
              icon: const Icon(Icons.sync),
              label: const Text('Sync Now')),
        ]),
        const SizedBox(height: 16),
        Expanded(child: LayoutBuilder(builder: (context, c) {
          final compact = c.maxWidth < 1050;
          final setup = _connectionCard(dark);
          final health = _healthCard();
          final queues = _queueCard();
          final feed = _activityCard();
          if (compact) {
            return ListView(children: [
              setup,
              const SizedBox(height: 12),
              health,
              const SizedBox(height: 12),
              queues,
              const SizedBox(height: 12),
              if (_conflicts.isNotEmpty) ...[
                _conflictCard(),
                const SizedBox(height: 12)
              ],
              feed
            ]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 390,
                child: ListView(
                    children: [setup, const SizedBox(height: 12), health])),
            const SizedBox(width: 14),
            Expanded(
                child: ListView(children: [
              queues,
              const SizedBox(height: 12),
              if (_conflicts.isNotEmpty) ...[
                _conflictCard(),
                const SizedBox(height: 12)
              ],
              feed
            ])),
          ]);
        })),
      ]),
    );
  }

  Widget _connectionCard(bool dark) => Card(
          child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Connection',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(
              'Configure the production sync API. Devices enroll once, receive their own token, and can be revoked independently.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12)),
          const SizedBox(height: 14),
          SwitchListTile.adaptive(
            value: _enabled,
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable cloud sync',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle:
                const Text('When disabled, RELIQ remains fully local/offline.'),
            onChanged: _busy ? null : (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          TextField(
              controller: _server,
              decoration: const InputDecoration(
                  labelText: 'Sync server URL',
                  hintText: 'https://sync.example.com')),
          const SizedBox(height: 10),
          TextField(
              controller: _company,
              decoration: const InputDecoration(labelText: 'Company sync key')),
          const SizedBox(height: 10),
          TextField(
              controller: _enrollment,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Enrollment key',
                  helperText:
                      'Used once to enroll this device. Cleared after the server issues a device token.')),
          const SizedBox(height: 10),
          TextField(
            controller: _token,
            obscureText: _hideToken,
            decoration: InputDecoration(
              labelText: 'Device token',
              suffixIcon: IconButton(
                  onPressed: () => setState(() => _hideToken = !_hideToken),
                  icon: Icon(_hideToken
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined)),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save')),
            OutlinedButton.icon(
                onPressed: _busy ? null : _health,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const Text('Test Server')),
            OutlinedButton.icon(
                onPressed: _busy ? null : _register,
                icon: const Icon(Icons.devices_outlined),
                label: const Text('Register Device')),
            OutlinedButton.icon(
                onPressed: _busy ? null : _bootstrapMasters,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Queue Initial Masters')),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: V3Style.softFor(V3Style.info, dark: dark),
                borderRadius: BorderRadius.circular(10)),
            child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          '8.0D requires HTTPS for production endpoints. Plain HTTP is accepted only for localhost/.local development. Enrollment secrets are one-time bootstrap credentials; everyday sync uses a separate per-device token.',
                          style: TextStyle(fontSize: 11.5))),
                ]),
          ),
        ]),
      ));

  Widget _healthCard() => Card(
          child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Text('This Device',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            _statusChip(_status)
          ]),
          const SizedBox(height: 12),
          _kv('Device', _identity['device_name'] ?? ''),
          _kv('Device ID', _identity['device_id'] ?? ''),
          _kv('Company ID', _identity['company_id'] ?? ''),
          _kv('Branch', _identity['branch_id'] ?? ''),
          _kv('Terminal', _identity['terminal_id'] ?? ''),
          _kv(
              'Server device',
              (_identity['server_device_id'] ?? '').isEmpty
                  ? 'Not registered'
                  : _identity['server_device_id']!),
          _kv('Last success', _when(_lastSuccess)),
          if (_lastError.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_lastError,
                style: const TextStyle(color: V3Style.danger, fontSize: 11.5)),
          ],
        ]),
      ));

  Widget _queueCard() {
    Widget metric(String title, int value, IconData icon, Color tone) =>
        Expanded(
            child: Container(
          constraints: const BoxConstraints(minWidth: 115),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: tone, size: 20),
            const SizedBox(height: 9),
            Text('$value',
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text(title,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11))
          ]),
        ));
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Transport Queues',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                SizedBox(height: 3),
                Text(
                    'Durable events survive app restarts and use retry backoff.',
                    style: TextStyle(fontSize: 11.5, color: V3Style.muted))
              ])),
          OutlinedButton.icon(
              onPressed: _busy ? null : _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry Failed')),
          const SizedBox(width: 8),
          OutlinedButton.icon(
              onPressed: _busy ? null : _applyIncoming,
              icon: const Icon(Icons.playlist_add_check_circle_outlined),
              label: const Text('Apply Incoming')),
          const SizedBox(width: 8),
          OutlinedButton.icon(
              onPressed: _busy ? null : _probe,
              icon: const Icon(Icons.science_outlined),
              label: const Text('Queue Probe')),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          metric(
              'Pending',
              (_summary['Pending'] ?? 0) + (_summary['Sending'] ?? 0),
              Icons.schedule_outlined,
              V3Style.info),
          const SizedBox(width: 9),
          metric(
              'Failed',
              (_summary['Failed'] ?? 0) + (_summary['Blocked'] ?? 0),
              Icons.error_outline,
              V3Style.danger),
          const SizedBox(width: 9),
          metric('Synced', _summary['Synced'] ?? 0, Icons.cloud_done_outlined,
              V3Style.success),
          const SizedBox(width: 9),
          metric('Incoming staged', _summary['Incoming'] ?? 0,
              Icons.move_to_inbox_outlined, V3Style.purple),
          const SizedBox(width: 9),
          metric('Conflicts', _summary['Conflicts'] ?? 0,
              Icons.compare_arrows_outlined, V3Style.gold),
        ]),
      ]),
    ));
  }

  Widget _conflictCard() => Card(
          child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Sync Conflicts',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text(
                      'RELIQ paused these changes instead of guessing. Resolve the business situation, then retry remote when appropriate.',
                      style: TextStyle(fontSize: 11.5, color: V3Style.muted))
                ])),
            _statusChip('${_conflicts.length} open')
          ]),
          const SizedBox(height: 10),
          for (final c in _conflicts.take(8))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  border: Border(
                      bottom:
                          BorderSide(color: Theme.of(context).dividerColor))),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          '${c['entity_type'] ?? 'record'} • ${c['entity_id'] ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                          (c['local_payload'] ?? 'Conflict requires review')
                              .toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ])),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await AppDatabase.instance.resolveSyncConflict(
                                (c['id'] ?? '').toString(),
                                resolution: 'Keep Local');
                            await _load();
                          },
                    child: const Text('Keep local')),
                TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await AppDatabase.instance.resolveSyncConflict(
                                (c['id'] ?? '').toString(),
                                resolution: 'Accept Remote');
                            await AppDatabase.instance
                                .applyPendingIncomingEvents(limit: 50);
                            await _load();
                          },
                    child: const Text('Retry remote')),
              ]),
            ),
        ]),
      ));

  Widget _activityCard() => Card(
          child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Recent Sync Activity',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              'Outbound events plus inbound business events and their apply state.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11.5)),
          const SizedBox(height: 12),
          if (_activity.isEmpty && _incoming.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: Text(
                        'No sync activity yet. Register this device or queue a transport probe.')))
          else ...[
            for (final row in _activity.take(12))
              _activityRow(row, inbound: false),
            for (final row in _incoming.take(8))
              _activityRow(row, inbound: true),
          ],
        ]),
      ));

  Widget _activityRow(Map<String, Object?> row, {required bool inbound}) {
    final status = (row['status'] ?? 'Pending').toString();
    final time = inbound
        ? (row['received_at'] ?? '').toString()
        : (row['created_at'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        Icon(inbound ? Icons.south_west : Icons.north_east,
            size: 17, color: inbound ? V3Style.purple : V3Style.info),
        const SizedBox(width: 10),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${row['entity_type'] ?? 'event'} · ${row['operation'] ?? ''}',
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          Text(
              '${row['entity_id'] ?? ''} • ${_when(time)}${(!inbound && (row['last_error'] ?? '').toString().isNotEmpty) ? ' • ${row['last_error']}' : ''}${(inbound && (row['error'] ?? '').toString().isNotEmpty) ? ' • ${row['error']}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        const SizedBox(width: 8),
        _statusChip(status),
      ]),
    );
  }

  Widget _statusChip(String text) {
    final value = text.toLowerCase();
    final color = value.contains('fail') || value.contains('block')
        ? V3Style.danger
        : value.contains('conflict')
            ? V3Style.gold
            : value.contains('sync') ||
                    value.contains('register') ||
                    value.contains('reach') ||
                    value.contains('applied')
                ? V3Style.success
                : value.contains('pending') || value.contains('stag')
                    ? V3Style.purple
                    : V3Style.info;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
            color: V3Style.softFor(color, dark: dark),
            borderRadius: BorderRadius.circular(999)),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 10.5, fontWeight: FontWeight.w800)));
  }

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 105,
              child: Text(label,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11))),
          Expanded(
              child: SelectableText(value.isEmpty ? '—' : value,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w600)))
        ]),
      );
}
