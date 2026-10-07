import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LicenseEntitlements {
  static const corePos = 'core_pos';
  static const purchases = 'purchases';
  static const basicReports = 'basic_reports';
  static const bulkTools = 'bulk_tools';
  static const inventoryIntelligence = 'inventory_intelligence';
  static const smartBuying = 'smart_buying';
  static const advancedReports = 'advanced_reports';
  static const tabletPos = 'tablet_pos';
  static const multiBranch = 'multi_branch';
  static const advancedRoles = 'advanced_roles';
  static const restaurantModule = 'restaurant_module';
  static const cloudSync = 'cloud_sync';
}

class LicenseState {
  const LicenseState({
    required this.configured,
    required this.activated,
    required this.validSignature,
    required this.expired,
    this.validationRequired = false,
    this.offlineCached = false,
    this.message = '',
    this.payload,
    this.lastValidatedAt,
  });

  final bool configured;
  final bool activated;
  final bool validSignature;
  final bool expired;
  final bool validationRequired;
  final bool offlineCached;
  final String message;
  final Map<String, dynamic>? payload;
  final DateTime? lastValidatedAt;

  bool get usable =>
      configured &&
      activated &&
      validSignature &&
      !expired &&
      !validationRequired &&
      status != 'revoked' &&
      status != 'suspended';

  bool get readOnly => activated && validSignature && !usable;
  bool get isTrial => licenseType == 'trial';
  String get status => (payload?['status'] ?? 'active').toString().toLowerCase();
  String get plan => (payload?['plan'] ?? (isTrial ? 'Business Trial' : 'Unlicensed')).toString();
  String get businessName => (payload?['business_name'] ?? '').toString();
  String get licenseId => (payload?['license_id'] ?? '').toString();
  String get licenseType => (payload?['license_type'] ?? 'subscription').toString().toLowerCase();
  int get maxUsers => (payload?['max_users'] as num?)?.toInt() ?? 0;
  int get maxTerminals => (payload?['max_terminals'] as num?)?.toInt() ?? 0;
  int get maxBranches => (payload?['max_branches'] as num?)?.toInt() ?? 0;
  int get durationDays => (payload?['duration_days'] as num?)?.toInt() ?? 0;

  DateTime? get activatedAt => _date(payload?['activated_at']);
  DateTime? get expiresAt => _date(payload?['expires_at']);
  DateTime? get issuedAt => _date(payload?['issued_at']);

  int? get daysRemaining {
    final expiry = expiresAt;
    if (expiry == null) return null;
    final diff = expiry.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff + 1;
  }

  Set<String> get entitlements {
    final raw = payload?['entitlements'];
    if (raw is! List) return <String>{};
    return raw.map((e) => e.toString()).toSet();
  }

  bool has(String entitlement) => usable && entitlements.contains(entitlement);

  LicenseState copyWith({
    bool? configured,
    bool? activated,
    bool? validSignature,
    bool? expired,
    bool? validationRequired,
    bool? offlineCached,
    String? message,
    Map<String, dynamic>? payload,
    DateTime? lastValidatedAt,
  }) =>
      LicenseState(
        configured: configured ?? this.configured,
        activated: activated ?? this.activated,
        validSignature: validSignature ?? this.validSignature,
        expired: expired ?? this.expired,
        validationRequired: validationRequired ?? this.validationRequired,
        offlineCached: offlineCached ?? this.offlineCached,
        message: message ?? this.message,
        payload: payload ?? this.payload,
        lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
      );

  static DateTime? _date(dynamic raw) {
    if (raw == null || raw.toString().trim().isEmpty) return null;
    return DateTime.tryParse(raw.toString())?.toLocal();
  }
}

class LicenseManager {
  LicenseManager._();
  static final LicenseManager instance = LicenseManager._();

  static const _tokenKey = 'v4_license_token';
  static const _legacyTokenKey = 'v4_activation_code';
  static const _installationKey = 'v4_installation_id';
  static const _lastValidationKey = 'v4_license_last_validation_utc';
  static const _lastSeenKey = 'v4_license_last_seen_utc';
  static const _legacyPrefix = 'V4L1';
  static const _serverPrefix = 'V4L2';

  // RELEASE BUILD CONFIGURATION
  // flutter build macos \
  //   --dart-define=V4_LICENSE_PUBLIC_KEY=<PUBLIC_KEY> \
  //   --dart-define=V4_LICENSE_SERVER_URL=https://license.example.com
  static const vendorPublicKey = String.fromEnvironment('V4_LICENSE_PUBLIC_KEY');
  static const licenseServerUrl = String.fromEnvironment('V4_LICENSE_SERVER_URL');
  static const appVersion = String.fromEnvironment('V4_APP_VERSION', defaultValue: '4.0');
  static const validationIntervalDays = int.fromEnvironment('V4_LICENSE_CHECK_DAYS', defaultValue: 7);
  static const offlineGraceDays = int.fromEnvironment('V4_LICENSE_OFFLINE_GRACE_DAYS', defaultValue: 14);

  final Ed25519 _algorithm = Ed25519();
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  bool get developmentBypass => vendorPublicKey.isEmpty;
  bool get serverConfigured => licenseServerUrl.trim().isNotEmpty;

  String _b64NoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  List<int> _decodeNoPad(String value) {
    final mod = value.length % 4;
    final padded = value + (mod == 0 ? '' : '=' * (4 - mod));
    return base64Url.decode(padded);
  }

  String _url(String path) => '${licenseServerUrl.replaceAll(RegExp(r'/+$'), '')}$path';

  Future<String?> savedCode() => savedToken();

  Future<String?> savedToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey) ?? prefs.getString(_legacyTokenKey);
  }

  Future<String> installationId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installationKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final bytes = List<int>.generate(18, (_) => rnd.nextInt(256));
    final value = _b64NoPad(bytes);
    await prefs.setString(_installationKey, value);
    return value;
  }

  Future<String> deviceHash() async {
    try {
      final info = await _deviceInfo.deviceInfo;
      final data = Map<String, dynamic>.from(info.data);
      const preferred = [
        'deviceId',
        'systemGUID',
        'identifierForVendor',
        'id',
        'computerName',
        'hostName',
        'model',
        'machine',
        'arch',
      ];
      final stable = <String, dynamic>{};
      for (final key in preferred) {
        final value = data[key];
        if (value != null && value.toString().trim().isNotEmpty) stable[key] = value.toString();
      }
      if (stable.isEmpty) stable.addAll(data.map((k, v) => MapEntry(k, v?.toString())));
      final raw = '${Platform.operatingSystem}|${jsonEncode(stable)}';
      return hash.sha256.convert(utf8.encode(raw)).toString();
    } catch (_) {
      // Fallback is less reinstall-resistant but keeps activation usable.
      final raw = '${Platform.operatingSystem}|${await installationId()}';
      return hash.sha256.convert(utf8.encode(raw)).toString();
    }
  }

  Future<Map<String, String>> _devicePayload() async => {
        'installation_id': await installationId(),
        'device_hash': await deviceHash(),
        'platform': Platform.operatingSystem,
        'app_version': appVersion,
      };

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_legacyTokenKey);
    await prefs.remove(_lastValidationKey);
  }

  Future<LicenseState> current({bool allowNetwork = true}) async {
    if (developmentBypass) {
      return const LicenseState(
        configured: false,
        activated: false,
        validSignature: false,
        expired: false,
        message: 'Development build — licensing bypass is active.',
      );
    }

    var token = await savedToken();
    if ((token == null || token.trim().isEmpty) && allowNetwork && serverConfigured) {
      final trial = await startOrRestoreTrial();
      if (trial.validSignature) return trial;
    }

    token = await savedToken();
    if (token == null || token.trim().isEmpty) {
      return LicenseState(
        configured: true,
        activated: false,
        validSignature: false,
        expired: false,
        message: serverConfigured
            ? 'Connect to the internet once to start the 14-day trial, or enter an activation key.'
            : 'No license has been activated.',
      );
    }

    var state = await verify(token);
    if (!state.validSignature) return state;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    final lastSeen = DateTime.tryParse(prefs.getString(_lastSeenKey) ?? '');
    final clockRollback = lastSeen != null && now.isBefore(lastSeen.subtract(const Duration(minutes: 5)));
    if (!clockRollback) await prefs.setString(_lastSeenKey, now.toIso8601String());

    if (state.expired || state.status == 'revoked' || state.status == 'suspended') return state;
    if (!token.startsWith('$_serverPrefix.')) return state;

    final lastValidation = DateTime.tryParse(prefs.getString(_lastValidationKey) ?? '') ?? state.issuedAt?.toUtc();
    state = state.copyWith(lastValidatedAt: lastValidation?.toLocal());
    final age = lastValidation == null ? const Duration(days: 9999) : now.difference(lastValidation);
    final due = clockRollback || age >= Duration(days: validationIntervalDays);

    if (allowNetwork && serverConfigured && due) {
      final refreshed = await refresh(silent: true);
      if (refreshed.validSignature && !refreshed.offlineCached && !refreshed.validationRequired) return refreshed;
    }

    if (clockRollback) {
      return state.copyWith(
        validationRequired: true,
        message: 'System clock changed backwards. Connect to the internet to validate the license.',
      );
    }

    if (age > Duration(days: offlineGraceDays)) {
      return state.copyWith(
        validationRequired: true,
        message: 'License validation is overdue. Connect to the internet to continue transactions.',
      );
    }

    if (due) {
      return state.copyWith(
        offlineCached: true,
        message: 'Offline — using the cached signed license during the grace period.',
      );
    }
    return state;
  }

  Future<LicenseState> startOrRestoreTrial() async {
    if (developmentBypass) {
      return const LicenseState(configured: false, activated: false, validSignature: false, expired: false, message: 'Development build');
    }
    if (!serverConfigured) {
      return const LicenseState(configured: true, activated: false, validSignature: false, expired: false, message: 'License server is not configured.');
    }
    try {
      final response = await http
          .post(
            Uri.parse(_url('/api/v1/trials/register')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(await _devicePayload()),
          )
          .timeout(const Duration(seconds: 6));
      return await _acceptServerResponse(response, successMessage: '14-day Business trial is active.');
    } catch (e) {
      return LicenseState(
        configured: true,
        activated: false,
        validSignature: false,
        expired: false,
        message: 'Could not start the trial: ${_cleanError(e)}',
      );
    }
  }

  Future<LicenseState> activate(String code) async {
    final clean = code.trim().toUpperCase();
    if (clean.isEmpty) {
      return const LicenseState(configured: true, activated: false, validSignature: false, expired: false, message: 'Enter an activation key.');
    }

    // Backward compatibility with the original offline V4L1 signed codes.
    if (code.trim().startsWith('$_legacyPrefix.') || code.trim().startsWith('$_serverPrefix.')) {
      final state = await verify(code.trim());
      if (!state.validSignature) return state;
      await _storeToken(code.trim(), validatedNow: code.trim().startsWith('$_serverPrefix.'));
      return state;
    }

    if (!serverConfigured) {
      return const LicenseState(configured: true, activated: false, validSignature: false, expired: false, message: 'This build has no license server URL.');
    }

    try {
      final payload = <String, dynamic>{...await _devicePayload(), 'activation_key': clean};
      final response = await http
          .post(
            Uri.parse(_url('/api/v1/licenses/activate')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
      return await _acceptServerResponse(response, successMessage: 'License activated.');
    } catch (e) {
      return LicenseState(
        configured: true,
        activated: false,
        validSignature: false,
        expired: false,
        message: 'Activation failed: ${_cleanError(e)}',
      );
    }
  }

  Future<LicenseState> refresh({bool silent = false}) async {
    final token = await savedToken();
    if (token == null) {
      return const LicenseState(configured: true, activated: false, validSignature: false, expired: false, message: 'No server license to refresh.');
    }
    if (!token.startsWith('$_serverPrefix.')) {
      return verify(token);
    }
    if (!serverConfigured) return verify(token);

    try {
      final payload = <String, dynamic>{...await _devicePayload(), 'token': token};
      final response = await http
          .post(
            Uri.parse(_url('/api/v1/licenses/refresh')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 7));
      return await _acceptServerResponse(response, successMessage: 'License refreshed.');
    } catch (e) {
      final local = await verify(token);
      if (silent && local.validSignature) return local.copyWith(offlineCached: true, message: 'Offline — cached license retained.');
      return local.copyWith(message: 'Could not refresh license: ${_cleanError(e)}');
    }
  }

  Future<LicenseState> _acceptServerResponse(http.Response response, {required String successMessage}) async {
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return LicenseState(
        configured: true,
        activated: false,
        validSignature: false,
        expired: false,
        message: (body['detail'] ?? body['message'] ?? 'License server returned ${response.statusCode}.').toString(),
      );
    }

    final token = (body['token'] ?? '').toString();
    if (token.isEmpty) {
      return const LicenseState(configured: true, activated: false, validSignature: false, expired: false, message: 'License server response did not contain a signed token.');
    }

    final verified = await verify(token);
    if (!verified.validSignature) return verified;
    await _storeToken(token, validatedNow: true);
    return verified.copyWith(message: successMessage, lastValidatedAt: DateTime.now());
  }

  Future<void> _storeToken(String token, {required bool validatedNow}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token.trim());
    await prefs.remove(_legacyTokenKey);
    if (validatedNow) await prefs.setString(_lastValidationKey, DateTime.now().toUtc().toIso8601String());
  }

  Future<LicenseState> verify(String code) async {
    if (vendorPublicKey.isEmpty) {
      return const LicenseState(
        configured: false,
        activated: false,
        validSignature: false,
        expired: false,
        message: 'This V4 build has no vendor public key.',
      );
    }

    try {
      final parts = code.trim().split('.');
      if (parts.length != 3 || (parts.first != _legacyPrefix && parts.first != _serverPrefix)) {
        throw const FormatException('This is not a supported V4 signed license token.');
      }

      final payloadBytes = _decodeNoPad(parts[1]);
      final signatureBytes = _decodeNoPad(parts[2]);
      final publicKey = SimplePublicKey(_decodeNoPad(vendorPublicKey), type: KeyPairType.ed25519);
      final ok = await _algorithm.verify(
        payloadBytes,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
      if (!ok) throw const FormatException('License signature is invalid.');

      final decoded = jsonDecode(utf8.decode(payloadBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('License payload is invalid.');
      final version = (decoded['version'] as num?)?.toInt() ?? 1;
      if (version != 1 && version != 2) throw const FormatException('Unsupported license version.');

      DateTime? expires;
      final rawExpiry = decoded['expires_at'];
      if (rawExpiry != null && rawExpiry.toString().isNotEmpty) expires = DateTime.tryParse(rawExpiry.toString())?.toUtc();
      final expired = expires != null && DateTime.now().toUtc().isAfter(expires);
      final status = (decoded['status'] ?? 'active').toString().toLowerCase();
      final blocked = status == 'revoked' || status == 'suspended';

      return LicenseState(
        configured: true,
        activated: true,
        validSignature: true,
        expired: expired,
        payload: decoded,
        message: blocked
            ? 'License is $status.'
            : expired
                ? 'License expired on ${expires.toLocal()}.'
                : decoded['license_type'] == 'trial'
                    ? '14-day Business trial is active.'
                    : 'License verified.',
      );
    } catch (e) {
      return LicenseState(
        configured: true,
        activated: true,
        validSignature: false,
        expired: false,
        message: e.toString().replaceFirst('FormatException: ', ''),
      );
    }
  }

  Future<LicenseState> requireUsable({String? entitlement}) async {
    if (developmentBypass) {
      return const LicenseState(configured: false, activated: false, validSignature: false, expired: false, message: 'Development build');
    }
    final state = await current();
    if (!state.usable) {
      if (state.validationRequired) throw Exception('License validation is required. Connect to the internet and refresh the license.');
      if (state.expired) throw Exception('License or trial expired. V4 is read-only until activated or renewed.');
      throw Exception('A valid license is required for this operation.');
    }
    if (entitlement != null && !state.entitlements.contains(entitlement)) {
      throw Exception('This plan does not include ${entitlement.replaceAll('_', ' ')}.');
    }
    return state;
  }

  String fingerprint(String code) {
    final digest = hash.sha256.convert(utf8.encode(code.trim())).bytes.take(6).toList();
    return _b64NoPad(digest);
  }

  String _cleanError(Object error) {
    final text = error.toString();
    return text.replaceFirst('Exception: ', '').replaceFirst('ClientException: ', '');
  }
}
