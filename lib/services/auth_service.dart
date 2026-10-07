import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/app_database.dart';
import 'permission_catalog.dart';

class AuthUser {
  final String id;
  final String username;
  final String displayName;
  final String role;
  final String email;
  final bool active;
  final Set<String> permissions;

  const AuthUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.email,
    required this.active,
    this.permissions = const <String>{},
  });

  factory AuthUser.fromRow(Map<String, Object?> row) => AuthUser(
        id: (row['id'] ?? '').toString(),
        username: (row['username'] ?? '').toString(),
        displayName: (row['display_name'] ?? '').toString(),
        role: (row['role'] ?? 'Viewer').toString(),
        email: (row['email'] ?? '').toString(),
        active: ((row['active'] as num?) ?? 0).toInt() == 1,
        permissions: (row['permissions'] ?? '').toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet(),
      );

  bool get isOwner => role == 'Owner';
  bool get isManager => role == 'Manager' || role == 'Admin';

  static Map<String, Set<String>> get roleDefaults => PermissionCatalog.defaults;

  bool can(String permission) {
    if (isOwner) return true;
    final effective = permissions.isEmpty ? PermissionCatalog.permissionsForRole(role) : permissions;
    return effective.contains(permission);
  }

}

class AuthService {
  AuthService._();
  static final instance = AuthService._();

  final _pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);
  final _random = Random.secure();

  Future<bool> needsOwnerSetup() async {
    final rows = await AppDatabase.instance.db.query(
      'users',
      columns: ['pin_hash'],
      where: "id='USR-OWNER' OR username='owner'",
      limit: 1,
    );
    if (rows.isEmpty) return true;
    return (rows.first['pin_hash'] ?? '').toString().trim().isEmpty;
  }

  Future<void> setupOwnerPassword(String password) async {
    if (password.trim().length < 4) throw Exception('Use at least 4 characters.');
    final hash = await _hash(password);
    final updated = await AppDatabase.instance.db.update(
      'users',
      {'pin_hash': hash, 'active': 1},
      where: "id='USR-OWNER' OR username='owner'",
    );
    if (updated == 0) throw Exception('Owner account is missing.');
    await AppDatabase.instance.recordAudit('Owner password setup', 'user', 'USR-OWNER', 'Owner password / PIN configured');
  }

  Future<AuthUser> login(String username, String password) async {
    final rows = await AppDatabase.instance.db.query(
      'users',
      where: 'LOWER(username)=LOWER(?)',
      whereArgs: [username.trim()],
      limit: 1,
    );
    if (rows.isEmpty) throw Exception('User not found.');
    final row = rows.first;
    if (((row['active'] as num?) ?? 0).toInt() != 1) throw Exception('This user is inactive.');
    final stored = (row['pin_hash'] ?? '').toString();
    if (stored.isEmpty) throw Exception('This user does not have a password yet. Ask an administrator to set one.');
    if (!await _verify(password, stored)) throw Exception('Incorrect password or PIN.');

    final user = AuthUser.fromRow(row);
    final now = DateTime.now().toIso8601String();
    await AppDatabase.instance.db.transaction((t) async {
      await t.update('users', {'last_login': now}, where: 'id=?', whereArgs: [user.id]);
      await t.insert('app_meta', {'k': 'current_user_id', 'v': user.id}, conflictAlgorithm: ConflictAlgorithm.replace);
      final branches = await t.query('user_branches', columns: ['branch_id'], where: 'user_id=?', whereArgs: [user.id]);
      if (branches.isNotEmpty) {
        final current = await t.query('app_meta', columns: ['v'], where: "k='current_branch_id'", limit: 1);
        final currentId = current.isEmpty ? '' : (current.first['v'] ?? '').toString();
        final allowed = branches.any((b) => b['branch_id'] == currentId);
        if (!allowed) {
          await t.insert('app_meta', {'k': 'current_branch_id', 'v': branches.first['branch_id'].toString()}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      final branchMeta = await t.query('app_meta', columns: ['v'], where: "k='current_branch_id'", limit: 1);
      final terminalMeta = await t.query('app_meta', columns: ['v'], where: "k='current_terminal_id'", limit: 1);
      if (branchMeta.isNotEmpty && terminalMeta.isNotEmpty) {
        await t.update('terminals', {
          'branch_id': branchMeta.first['v'].toString(),
          'last_seen': now,
        }, where: 'id=?', whereArgs: [terminalMeta.first['v'].toString()]);
      }
    });
    await AppDatabase.instance.recordAudit('User login', 'user', user.id, '${user.displayName} (@${user.username}) signed in');
    return user;
  }

  Future<void> setPassword(String userId, String password) async {
    await AppDatabase.instance.requirePermission('users', 'manage user passwords');
    if (password.trim().length < 4) throw Exception('Use at least 4 characters.');
    final hash = await _hash(password);
    await AppDatabase.instance.db.update('users', {'pin_hash': hash}, where: 'id=?', whereArgs: [userId]);
    await AppDatabase.instance.recordAudit('Reset user password', 'user', userId, 'Password / PIN changed');
  }

  Future<void> setActive(String userId, bool active) async {
    await AppDatabase.instance.requirePermission('users', 'activate or disable users');
    final rows = await AppDatabase.instance.db.query('users', where: 'id=?', whereArgs: [userId], limit: 1);
    if (rows.isEmpty) throw Exception('User not found.');
    if ((rows.first['username'] ?? '').toString().toLowerCase() == 'owner' && !active) {
      throw Exception('The built-in owner account cannot be disabled.');
    }
    final ctx = await AppDatabase.instance.operationalContext();
    if (!active && ctx['user_id'] == userId) throw Exception('You cannot disable the account currently signed in.');
    await AppDatabase.instance.db.update('users', {'active': active ? 1 : 0}, where: 'id=?', whereArgs: [userId]);
    await AppDatabase.instance.recordAudit(active ? 'Activate user' : 'Disable user', 'user', userId, active ? 'User activated' : 'User disabled');
  }

  Future<void> deleteUser(String userId) async {
    await AppDatabase.instance.requirePermission('users', 'delete users');
    final rows = await AppDatabase.instance.db.query('users', where: 'id=?', whereArgs: [userId], limit: 1);
    if (rows.isEmpty) return;
    if ((rows.first['username'] ?? '').toString().toLowerCase() == 'owner') {
      throw Exception('The built-in owner account cannot be deleted.');
    }
    final ctx = await AppDatabase.instance.operationalContext();
    if (ctx['user_id'] == userId) throw Exception('You cannot delete the account currently signed in.');
    final label = '${rows.first['display_name'] ?? ''} (@${rows.first['username'] ?? ''})';
    await AppDatabase.instance.db.transaction((t) async {
      await t.delete('user_branches', where: 'user_id=?', whereArgs: [userId]);
      await t.delete('users', where: 'id=?', whereArgs: [userId]);
    });
    await AppDatabase.instance.recordAudit('Delete user', 'user', userId, '$label deleted; historical transaction user IDs retained');
  }

  Future<String> _hash(String password) async {
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    final key = await _pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final bytes = await key.extractBytes();
    return 'pbkdf2\$${base64UrlEncode(salt)}\$${base64UrlEncode(bytes)}';
  }

  Future<bool> _verify(String password, String stored) async {
    final parts = stored.split(r'$');
    if (parts.length != 3 || parts.first != 'pbkdf2') return false;
    try {
      final salt = base64Url.decode(parts[1]);
      final expected = base64Url.decode(parts[2]);
      final key = await _pbkdf2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      final actual = await key.extractBytes();
      if (actual.length != expected.length) return false;
      var diff = 0;
      for (var i = 0; i < actual.length; i++) diff |= actual[i] ^ expected[i];
      return diff == 0;
    } catch (_) {
      return false;
    }
  }
}
