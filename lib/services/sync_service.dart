import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/app_database.dart';

class SyncRunResult {
  final int pushed;
  final int pulled;
  final int applied;
  final int conflicts;
  final int failed;
  final String message;
  final DateTime completedAt;

  const SyncRunResult({
    required this.pushed,
    required this.pulled,
    required this.applied,
    required this.conflicts,
    required this.failed,
    required this.message,
    required this.completedAt,
  });
}

class SyncService {
  SyncService._();
  static final instance = SyncService._();
  Timer? _timer;
  bool _running = false;

  void startPeriodic() {
    _timer ??=
        Timer.periodic(const Duration(minutes: 1), (_) => _periodicTick());
    Future.delayed(const Duration(seconds: 12), _periodicTick);
  }

  Future<void> _periodicTick() async {
    if (_running) return;
    final settings = await AppDatabase.instance.settings();
    if (settings['sync_enabled'] != '1' ||
        (settings['sync_server_url'] ?? '').trim().isEmpty) return;
    _running = true;
    try {
      await syncNow();
    } catch (e) {
      await AppDatabase.instance.setSyncRuntime({
        'last_attempt_at': DateTime.now().toUtc().toIso8601String(),
        'last_error': e.toString().replaceFirst('Exception: ', ''),
      });
    } finally {
      _running = false;
    }
  }

  Uri _uri(String base, String path, [Map<String, String>? query]) {
    final cleanBase = base.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$cleanBase$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  void _validateServerUrl(String base) {
    final uri = Uri.tryParse(base.trim());
    if (uri == null || uri.host.isEmpty)
      throw Exception('Enter a valid sync server URL.');
    final host = uri.host.toLowerCase();
    final local = host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.local');
    if (uri.scheme != 'https' && !(local && uri.scheme == 'http')) {
      throw Exception(
          'Production sync requires HTTPS. Plain HTTP is allowed only for localhost/.local development servers.');
    }
  }

  Map<String, String> _headers(Map<String, String> settings) {
    final token = (settings['sync_api_token'] ?? '').trim();
    return {
      'content-type': 'application/json',
      'accept': 'application/json',
      if (token.isNotEmpty) 'authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> health() async {
    final settings = await AppDatabase.instance.settings();
    final base = (settings['sync_server_url'] ?? '').trim();
    if (base.isEmpty) throw Exception('Enter a sync server URL first.');
    _validateServerUrl(base);
    final response = await http
        .get(_uri(base, '/v1/health'), headers: _headers(settings))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Sync server returned HTTP ${response.statusCode}.');
    }
    if (response.body.trim().isEmpty) return {'ok': true};
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic>
        ? decoded
        : {'ok': true, 'response': decoded};
  }

  Future<String> registerDevice() async {
    final settings = await AppDatabase.instance.settings();
    final base = (settings['sync_server_url'] ?? '').trim();
    if (base.isEmpty) throw Exception('Enter a sync server URL first.');
    _validateServerUrl(base);
    final identity = await AppDatabase.instance.syncIdentity();
    final companyKey =
        (settings['sync_company_key'] ?? identity['company_id'] ?? '').trim();
    if (companyKey.isEmpty) throw Exception('Company sync key is required.');
    final existingToken = (settings['sync_api_token'] ?? '').trim();
    final enrollmentKey = (settings['sync_enrollment_key'] ?? '').trim();
    final enrolling = existingToken.isEmpty && enrollmentKey.isNotEmpty;
    final body = {
      'company_id': companyKey,
      'device_id': identity['device_id'],
      'device_name': identity['device_name'],
      'platform': identity['platform'],
      'branch_id': identity['branch_id'],
      'terminal_id': identity['terminal_id'],
      'app_version': '4.0.0-m8.0d',
      if (enrolling) 'enrollment_key': enrollmentKey,
    };
    final endpoint = enrolling ? '/v1/devices/enroll' : '/v1/devices/register';
    final headers = _headers(settings);
    final response = await http
        .post(_uri(base, endpoint), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_serverError(
          response,
          enrolling
              ? 'Device enrollment failed'
              : 'Device registration failed'));
    }
    final decoded = response.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    final serverDeviceId = (decoded['server_device_id'] ??
            decoded['device_id'] ??
            identity['device_id'])
        .toString();
    final deviceToken = (decoded['device_token'] ?? '').toString();
    if (deviceToken.isNotEmpty) {
      await AppDatabase.instance.saveSettings(
          {'sync_api_token': deviceToken, 'sync_enrollment_key': ''});
    }
    await AppDatabase.instance
        .updateDeviceRegistration(serverDeviceId: serverDeviceId);
    await AppDatabase.instance.logSyncSecurityEvent(
        enrolling ? 'DeviceEnrolled' : 'DeviceRegistered',
        'Server device: $serverDeviceId');
    return serverDeviceId;
  }

  Future<SyncRunResult> syncNow() async {
    final db = AppDatabase.instance;
    var settings = await db.settings();
    if (settings['sync_enabled'] != '1')
      throw Exception(
          'Cloud sync is disabled. Enable it in Sync Center first.');
    final base = (settings['sync_server_url'] ?? '').trim();
    if (base.isEmpty) throw Exception('Sync server URL is missing.');
    _validateServerUrl(base);
    var identity = await db.syncIdentity();
    final needsEnrollment = (settings['sync_api_token'] ?? '').trim().isEmpty &&
        (settings['sync_enrollment_key'] ?? '').trim().isNotEmpty;
    if ((identity['server_device_id'] ?? '').isEmpty || needsEnrollment) {
      await registerDevice();
      identity = await db.syncIdentity();
      settings = await db.settings();
    }

    var pushed = 0;
    final pending = await db.pendingSyncEvents(limit: 100);
    if (pending.isNotEmpty) {
      final ids = pending
          .map((e) => (e['event_id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
      await db.markSyncSending(ids);
      try {
        final body = {
          'company_id':
              (settings['sync_company_key'] ?? identity['company_id'] ?? '')
                  .trim(),
          'device_id': identity['device_id'],
          'server_device_id': identity['server_device_id'],
          'events': pending
              .map((e) => {
                    'event_id': e['event_id'],
                    'entity_type': e['entity_type'],
                    'entity_id': e['entity_id'],
                    'operation': e['operation'],
                    'payload': _decodePayload(e['payload']),
                    'created_at': e['created_at'],
                    'branch_id': e['branch_id'],
                    'sequence': e['sequence'],
                    'checksum': e['checksum'],
                  })
              .toList(),
        };
        final response = await http
            .post(_uri(base, '/v1/sync/push'),
                headers: _headers(settings), body: jsonEncode(body))
            .timeout(const Duration(seconds: 18));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(_serverError(response, 'Push failed'));
        }
        final decoded = response.body.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(response.body) as Map<String, dynamic>;
        final acceptedRaw = decoded['accepted'];
        final accepted = acceptedRaw is List
            ? acceptedRaw
                .map((e) =>
                    e is Map ? (e['event_id'] ?? '').toString() : e.toString())
                .where((e) => e.isNotEmpty)
                .toList()
            : ids;
        await db.markSyncAccepted(accepted);
        pushed = accepted.length;
        final rejectedRaw = decoded['rejected'];
        if (rejectedRaw is List) {
          for (final item in rejectedRaw.whereType<Map>()) {
            final eventId = (item['event_id'] ?? '').toString();
            if (eventId.isEmpty) continue;
            final retryable = item['retryable'] != false;
            await db.markSyncFailed(eventId,
                (item['error'] ?? 'Server rejected the event').toString(),
                retryable: retryable);
          }
        }
        final acceptedSet = accepted.toSet();
        for (final id in ids.where((id) => !acceptedSet.contains(id))) {
          final explicitlyRejected = rejectedRaw is List &&
              rejectedRaw
                  .whereType<Map>()
                  .any((e) => (e['event_id'] ?? '').toString() == id);
          if (!explicitlyRejected)
            await db.markSyncFailed(
                id, 'Server did not acknowledge this event.');
        }
      } catch (e) {
        for (final id in ids) {
          await db.markSyncFailed(
              id, e.toString().replaceFirst('Exception: ', ''));
        }
        rethrow;
      }
    }

    final cursor = await db.syncCursor();
    final pullResponse = await http
        .get(
          _uri(base, '/v1/sync/pull', {
            'company_id':
                (settings['sync_company_key'] ?? identity['company_id'] ?? '')
                    .trim(),
            'device_id': identity['device_id'] ?? '',
            if (cursor.isNotEmpty) 'cursor': cursor,
            'limit': '200',
          }),
          headers: _headers(settings),
        )
        .timeout(const Duration(seconds: 18));
    if (pullResponse.statusCode < 200 || pullResponse.statusCode >= 300) {
      throw Exception(_serverError(pullResponse, 'Pull failed'));
    }
    final pull = pullResponse.body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(pullResponse.body) as Map<String, dynamic>;
    final eventsRaw = pull['events'];
    final events = eventsRaw is List
        ? eventsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    await db.stageIncomingEvents(events);
    final applyResult = await db.applyPendingIncomingEvents(limit: 500);
    final nextCursor = (pull['next_cursor'] ?? pull['cursor'] ?? '').toString();
    if (nextCursor.isNotEmpty) await db.saveSyncCursor(nextCursor);
    final applied = applyResult['applied'] ?? 0;
    final conflicts = applyResult['conflicts'] ?? 0;
    final failed = applyResult['failed'] ?? 0;
    await db.setSyncRuntime({
      'last_attempt_at': DateTime.now().toUtc().toIso8601String(),
      'last_success_at': DateTime.now().toUtc().toIso8601String(),
      'last_error':
          failed > 0 ? '$failed incoming event(s) could not be applied.' : '',
    });
    return SyncRunResult(
      pushed: pushed,
      pulled: events.length,
      applied: applied,
      conflicts: conflicts,
      failed: failed,
      message: 'Business sync completed.',
      completedAt: DateTime.now(),
    );
  }

  Future<String> queueTransportTest() async {
    final identity = await AppDatabase.instance.syncIdentity();
    return AppDatabase.instance.enqueueSyncEvent(
      entityType: 'sync_probe',
      entityId: 'probe-${DateTime.now().toUtc().millisecondsSinceEpoch}',
      operation: 'probe',
      payload: {
        'device_id': identity['device_id'],
        'branch_id': identity['branch_id'],
        'sent_at': DateTime.now().toUtc().toIso8601String(),
        'message': 'V4 8.0D transport probe',
      },
    );
  }

  dynamic _decodePayload(Object? raw) {
    if (raw == null) return const <String, dynamic>{};
    try {
      return jsonDecode(raw.toString());
    } catch (_) {
      return {'raw': raw.toString()};
    }
  }

  String _serverError(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] != null)
        return decoded['error'].toString();
      if (decoded is Map && decoded['message'] != null)
        return decoded['message'].toString();
    } catch (_) {}
    return '$fallback (HTTP ${response.statusCode})';
  }
}
