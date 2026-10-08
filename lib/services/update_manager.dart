import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/brand.dart';
import '../data/app_database.dart';

class UpdateInfo {
  final String version;
  final int build;
  final int minimumDatabaseVersion;
  final int targetDatabaseVersion;
  final String releaseNotes;
  final String? packageUrl;
  final String? packageSha256;
  final String channel;

  const UpdateInfo({
    required this.version,
    required this.build,
    required this.minimumDatabaseVersion,
    required this.targetDatabaseVersion,
    required this.releaseNotes,
    required this.channel,
    this.packageUrl,
    this.packageSha256,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        version: (json['version'] ?? '').toString(),
        build: int.tryParse('${json['build'] ?? 0}') ?? 0,
        minimumDatabaseVersion:
            int.tryParse('${json['minimum_database_version'] ?? 0}') ?? 0,
        targetDatabaseVersion:
            int.tryParse('${json['target_database_version'] ?? 0}') ?? 0,
        releaseNotes: (json['release_notes'] ?? '').toString(),
        packageUrl: (json['package_url'] ?? '').toString().trim().isEmpty
            ? null
            : json['package_url'].toString(),
        packageSha256: (json['package_sha256'] ?? '').toString().trim().isEmpty
            ? null
            : json['package_sha256'].toString(),
        channel: (json['channel'] ?? 'stable').toString(),
      );
}

class StagedUpdate {
  final UpdateInfo info;
  final String sourcePackage;
  final String stagingDirectory;
  final String payloadPath;
  final String payloadKind;
  final String backupPath;

  const StagedUpdate({
    required this.info,
    required this.sourcePackage,
    required this.stagingDirectory,
    required this.payloadPath,
    required this.payloadKind,
    required this.backupPath,
  });
}

class UpdateManager {
  UpdateManager._();
  static final instance = UpdateManager._();

  static const packageFormat = 'reliq-update-v1';

  String get currentVersion => Brand.version;
  int get currentBuild => Brand.buildNumber;
  int get targetDatabaseVersion => Brand.databaseVersion;

  String get platformKey {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unsupported';
  }

  Future<int> currentDatabaseVersion() async {
    final rows = await AppDatabase.instance.db.rawQuery('PRAGMA user_version');
    if (rows.isEmpty || rows.first.isEmpty) return 0;
    final value = rows.first.values.first;
    return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  }

  Future<List<Map<String, Object?>>> history({int limit = 25}) async =>
      AppDatabase.instance.db
          .query('update_history', orderBy: 'created_at DESC', limit: limit);

  Future<UpdateInfo?> checkOnline(String manifestUrl,
      {String channel = 'stable'}) async {
    final url = manifestUrl.trim();
    if (url.isEmpty) throw Exception('Update manifest URL is not configured.');
    final response =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200)
      throw Exception('Update server returned HTTP ${response.statusCode}.');
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('Update manifest is not valid JSON.');
    final map = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
    if ((map['product'] ?? '').toString() != Brand.name)
      throw Exception('Update manifest is for a different product.');
    final info = UpdateInfo.fromJson(map);
    if (info.channel.toLowerCase() != channel.toLowerCase() &&
        channel.toLowerCase() == 'stable') return null;
    await _record('Checked', info.version, 'Online update check succeeded.');
    return _isNewer(info.version, info.build) ? info : null;
  }

  Future<String> downloadPackage(UpdateInfo info) async {
    final url = info.packageUrl;
    if (url == null || url.isEmpty)
      throw Exception('This update does not include a package download URL.');
    final response =
        await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
    if (response.statusCode != 200)
      throw Exception(
          'Update download failed with HTTP ${response.statusCode}.');
    final dir = Directory(
        p.join(await AppDatabase.instance.dataDir, 'updates', 'downloads'));
    await dir.create(recursive: true);
    final path =
        p.join(dir.path, 'RELIQ_Update_${info.version}_${info.build}.reliq');
    final file = File(path);
    await file.writeAsBytes(response.bodyBytes, flush: true);
    if (info.packageSha256 != null) {
      final actual = sha256.convert(response.bodyBytes).toString();
      if (actual.toLowerCase() != info.packageSha256!.toLowerCase()) {
        await file.delete();
        throw Exception('Downloaded update failed SHA-256 verification.');
      }
    }
    return path;
  }

  Future<StagedUpdate> stagePackage(String packagePath) async {
    await AppDatabase.instance
        .requirePermission('backup_restore', 'install application updates');
    final source = File(packagePath);
    if (!await source.exists()) throw Exception('Update package not found.');
    final bytes = await source.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final manifestEntry =
        archive.files.where((f) => f.name == 'manifest.json').firstOrNull;
    if (manifestEntry == null || !manifestEntry.isFile)
      throw Exception('Update package is missing manifest.json.');
    final manifestBytes =
        Uint8List.fromList(manifestEntry.content as List<int>);
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map) throw Exception('Update manifest is invalid.');
    final manifest = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
    if ((manifest['format'] ?? '').toString() != packageFormat)
      throw Exception('Unsupported RELIQ update package format.');
    if ((manifest['product'] ?? '').toString() != Brand.name)
      throw Exception('This update package belongs to a different product.');

    final info = UpdateInfo.fromJson(manifest);
    if (!_isNewer(info.version, info.build)) {
      throw Exception(
          'This package (${info.version}+${info.build}) is not newer than the installed version ($currentVersion+$currentBuild).');
    }

    final dbVersion = await currentDatabaseVersion();
    if (info.minimumDatabaseVersion > 0 &&
        dbVersion < info.minimumDatabaseVersion) {
      throw Exception(
          'Database version $dbVersion is too old for this update. Minimum required: ${info.minimumDatabaseVersion}.');
    }
    if (info.targetDatabaseVersion > 0 &&
        info.targetDatabaseVersion < dbVersion) {
      throw Exception(
          'This update targets database version ${info.targetDatabaseVersion}, but this installation already uses version $dbVersion. Downgrade is blocked.');
    }

    final platforms = manifest['platforms'];
    if (platforms is! Map)
      throw Exception('Update package has no platform payloads.');
    final platformEntryRaw = platforms[platformKey];
    if (platformEntryRaw is! Map)
      throw Exception('This package has no $platformKey build.');
    final platformEntry =
        Map<String, dynamic>.from(platformEntryRaw.cast<String, dynamic>());
    final payloadFile = (platformEntry['file'] ?? '').toString();
    final payloadKind = (platformEntry['kind'] ?? '').toString();
    final expectedSha = (platformEntry['sha256'] ?? '').toString();
    if (payloadFile.isEmpty || payloadKind.isEmpty || expectedSha.isEmpty)
      throw Exception('Platform payload metadata is incomplete.');

    final entry = archive.files.where((f) => f.name == payloadFile).firstOrNull;
    if (entry == null || !entry.isFile)
      throw Exception('Update payload $payloadFile is missing.');
    final payloadBytes = Uint8List.fromList(entry.content as List<int>);
    final actualSha = sha256.convert(payloadBytes).toString();
    if (actualSha.toLowerCase() != expectedSha.toLowerCase())
      throw Exception('Update payload failed SHA-256 verification.');

    // Always create a verified safety copy before staging an application update.
    final backupDir = Directory(
        p.join(await AppDatabase.instance.dataDir, 'backups', 'pre_update'));
    await backupDir.create(recursive: true);
    final backupPath = await AppDatabase.instance
        .backupTo(backupDir.path, enforcePermission: false);

    final staging = Directory(p.join(await AppDatabase.instance.dataDir,
        'updates', 'staged', '${info.version}_${info.build}_$platformKey'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final payloadPath = p.join(staging.path, p.basename(payloadFile));
    await File(payloadPath).writeAsBytes(payloadBytes, flush: true);

    await AppDatabase.instance.db.insert(
        'app_meta', {'k': 'pending_update_version', 'v': info.version},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await AppDatabase.instance.db.insert(
        'app_meta', {'k': 'pending_update_build', 'v': '${info.build}'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await AppDatabase.instance.db.insert(
        'app_meta', {'k': 'pending_update_backup', 'v': backupPath},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _record('Staged', info.version,
        'Offline/online package staged for $platformKey. Safety backup: $backupPath');
    final pendingFile = File(p.join(
        await AppDatabase.instance.dataDir, 'updates', 'pending_update.json'));
    await pendingFile.parent.create(recursive: true);
    await pendingFile.writeAsString(
        jsonEncode({
          'version': info.version,
          'build': info.build,
          'backup_path': backupPath,
          'staging_directory': staging.path,
          'platform': platformKey,
          'staged_at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true);

    return StagedUpdate(
      info: info,
      sourcePackage: source.path,
      stagingDirectory: staging.path,
      payloadPath: payloadPath,
      payloadKind: payloadKind,
      backupPath: backupPath,
    );
  }

  Future<void> launchInstallerAndExit(StagedUpdate staged) async {
    if (Platform.isWindows) {
      await _launchWindowsUpdater(staged);
    } else if (Platform.isMacOS) {
      await _launchMacUpdater(staged);
    } else {
      throw Exception(
          'Automatic replacement is currently supported on Windows and macOS only.');
    }
    // Give the detached helper a moment to start before this process exits.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    exit(0);
  }

  Future<void> _launchWindowsUpdater(StagedUpdate staged) async {
    if (staged.payloadKind != 'windows_zip')
      throw Exception('Windows update payload must use kind windows_zip.');
    final payloadBytes = await File(staged.payloadPath).readAsBytes();
    final payloadArchive = ZipDecoder().decodeBytes(payloadBytes, verify: true);
    final extracted = Directory(p.join(staged.stagingDirectory, 'app'));
    await extracted.create(recursive: true);
    for (final f in payloadArchive.files) {
      final safe = _safeRelative(f.name);
      if (safe == null)
        throw Exception('Unsafe path in Windows update payload.');
      final out = p.join(extracted.path, safe);
      if (f.isFile) {
        await File(out).parent.create(recursive: true);
        await File(out).writeAsBytes(f.content as List<int>, flush: true);
      } else {
        await Directory(out).create(recursive: true);
      }
    }
    final installDir = p.dirname(Platform.resolvedExecutable);
    final executableName = p.basename(Platform.resolvedExecutable);
    final statusFile = p.join(staged.stagingDirectory, 'update_status.txt');
    final script = File(p.join(staged.stagingDirectory, 'apply_update.ps1'));
    final qExtracted = _psQuote(extracted.path);
    final qInstall = _psQuote(installDir);
    final qExe = _psQuote(p.join(installDir, executableName));
    final previous = p.join(staged.stagingDirectory, 'previous_app');
    final qPrevious = _psQuote(previous);
    final qStatus = _psQuote(statusFile);
    await script.writeAsString('''
\$ErrorActionPreference = "Stop"
try {
  while (Get-Process -Id $pid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 400 }
  if (Test-Path "$qPrevious") { Remove-Item "$qPrevious" -Recurse -Force }
  New-Item -ItemType Directory -Force -Path "$qPrevious" | Out-Null
  Copy-Item -Path "$qInstall\\*" -Destination "$qPrevious" -Recurse -Force
  Remove-Item -Path "$qInstall\\*" -Recurse -Force
  Copy-Item -Path "$qExtracted\\*" -Destination "$qInstall" -Recurse -Force
  "OK" | Set-Content -Path "$qStatus"
  Start-Process "$qExe"
} catch {
  ("ERROR: " + \$_.Exception.Message) | Set-Content -Path "$qStatus"
}
'''
        .replaceFirst(r'$pid', '${pid}'));
    await Process.start('powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        mode: ProcessStartMode.detached);
  }

  Future<void> _launchMacUpdater(StagedUpdate staged) async {
    if (staged.payloadKind != 'macos_app_tgz')
      throw Exception('macOS update payload must use kind macos_app_tgz.');
    final extracted = Directory(p.join(staged.stagingDirectory, 'app_payload'));
    await extracted.create(recursive: true);
    final stagedApp = p.join(extracted.path, 'RELIQ Solutions.app');
    final bundle = _currentMacBundlePath();
    if (bundle == null)
      throw Exception(
          'Could not determine the installed RELIQ .app bundle path.');
    final statusFile = p.join(staged.stagingDirectory, 'update_status.txt');
    final previousApp =
        p.join(staged.stagingDirectory, 'previous_app', 'RELIQ Solutions.app');
    final script = File(p.join(staged.stagingDirectory, 'apply_update.sh'));
    final reopen = p.basename(bundle);
    await script.writeAsString('''#!/bin/zsh
set -e
rm -rf ${_shQuote(extracted.path)}
mkdir -p ${_shQuote(extracted.path)}
/usr/bin/tar -xzf ${_shQuote(staged.payloadPath)} -C ${_shQuote(extracted.path)}
if [ ! -d ${_shQuote(stagedApp)} ]; then echo 'ERROR: payload missing RELIQ Solutions.app' > ${_shQuote(statusFile)}; exit 1; fi
while kill -0 $pid 2>/dev/null; do sleep 0.4; done
rm -rf ${_shQuote(p.dirname(previousApp))}
mkdir -p ${_shQuote(p.dirname(previousApp))}
/usr/bin/ditto ${_shQuote(bundle)} ${_shQuote(previousApp)}
rm -rf ${_shQuote(bundle)}
/usr/bin/ditto ${_shQuote(stagedApp)} ${_shQuote(bundle)}
echo OK > ${_shQuote(statusFile)}
/usr/bin/open ${_shQuote(bundle)}
''');
    await Process.run('chmod', ['+x', script.path]);

    // If installed under /Applications, macOS may require administrator approval.
    final command = _shQuote(script.path);
    final appleScript =
        'do shell script ${_appleScriptQuote(command)} with administrator privileges';
    await Process.start('osascript', ['-e', appleScript],
        mode: ProcessStartMode.detached);
    // Keep variable referenced for easier diagnostics in generated packages.
    if (reopen.isEmpty) throw Exception('Invalid application bundle name.');
  }

  Future<void> markStartupComplete() async {
    try {
      final rows = await AppDatabase.instance.db.query('app_meta',
          where: "k IN ('pending_update_version','pending_update_build')");
      final values = <String, String>{
        for (final r in rows) '${r['k']}': '${r['v'] ?? ''}'
      };
      final pendingVersion = values['pending_update_version'];
      final pendingBuild = int.tryParse(values['pending_update_build'] ?? '');
      if (pendingVersion == currentVersion && pendingBuild == currentBuild) {
        await _record('Completed', currentVersion,
            'Application update completed and database opened successfully.');
        await AppDatabase.instance.db.delete('app_meta',
            where: "k IN ('pending_update_version','pending_update_build')");
        await AppDatabase.instance.db.insert(
            'app_meta',
            {
              'k': 'last_successful_app_version',
              'v': '$currentVersion+$currentBuild'
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        final pendingFile = File(p.join(await AppDatabase.instance.dataDir,
            'updates', 'pending_update.json'));
        if (await pendingFile.exists()) await pendingFile.delete();
      }
    } catch (_) {
      // Startup must never fail solely because update bookkeeping failed.
    }
  }

  Future<bool> launchRollbackAfterFailedUpdate(String error) async {
    try {
      final data = await AppDatabase.instance.dataDir;
      final pendingFile = File(p.join(data, 'updates', 'pending_update.json'));
      if (!await pendingFile.exists()) return false;
      final raw = jsonDecode(await pendingFile.readAsString());
      if (raw is! Map) return false;
      final backup = (raw['backup_path'] ?? '').toString();
      final staging = (raw['staging_directory'] ?? '').toString();
      if (backup.isEmpty || staging.isEmpty || !await File(backup).exists())
        return false;

      final live = File(p.join(data, 'reliq_solutions.db'));
      final failedCopy = File(p.join(data,
          'failed_update_db_${DateTime.now().millisecondsSinceEpoch}.db'));
      if (await live.exists()) {
        try {
          await live.copy(failedCopy.path);
        } catch (_) {}
      }
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File('${live.path}$suffix');
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      await File(backup).copy(live.path);

      final recoveryLog = File(p.join(data, 'updates', 'last_recovery.txt'));
      await recoveryLog.parent.create(recursive: true);
      await recoveryLog.writeAsString(
          'Database migration/startup failed after update. RELIQ restored the pre-update database and requested application rollback.\n$error\nBackup: $backup\n',
          flush: true);

      if (Platform.isWindows) {
        final previous = p.join(staging, 'previous_app');
        if (!await Directory(previous).exists()) return false;
        final installDir = p.dirname(Platform.resolvedExecutable);
        final exe = p.join(installDir, p.basename(Platform.resolvedExecutable));
        final script = File(p.join(staging, 'rollback_update.ps1'));
        await script.writeAsString('''
\$ErrorActionPreference = "Stop"
while (Get-Process -Id $pid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 400 }
Remove-Item -Path "${_psQuote(installDir)}\\*" -Recurse -Force
Copy-Item -Path "${_psQuote(previous)}\\*" -Destination "${_psQuote(installDir)}" -Recurse -Force
"ROLLED BACK" | Set-Content -Path "${_psQuote(p.join(staging, 'update_status.txt'))}"
Start-Process "${_psQuote(exe)}"
''');
        await Process.start('powershell',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
            mode: ProcessStartMode.detached);
        return true;
      }

      if (Platform.isMacOS) {
        final previous = p.join(staging, 'previous_app', 'RELIQ Solutions.app');
        final bundle = _currentMacBundlePath();
        if (bundle == null || !await Directory(previous).exists()) return false;
        final script = File(p.join(staging, 'rollback_update.sh'));
        await script.writeAsString('''#!/bin/zsh
set -e
while kill -0 $pid 2>/dev/null; do sleep 0.4; done
rm -rf ${_shQuote(bundle)}
/usr/bin/ditto ${_shQuote(previous)} ${_shQuote(bundle)}
echo 'ROLLED BACK' > ${_shQuote(p.join(staging, 'update_status.txt'))}
/usr/bin/open ${_shQuote(bundle)}
''');
        await Process.run('chmod', ['+x', script.path]);
        final appleScript =
            'do shell script ${_appleScriptQuote(_shQuote(script.path))} with administrator privileges';
        await Process.start('osascript', ['-e', appleScript],
            mode: ProcessStartMode.detached);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _record(String status, String version, String details) async {
    try {
      await AppDatabase.instance.db.insert('update_history', {
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'version': version,
        'status': status,
        'details': details,
      });
    } catch (_) {}
  }

  bool _isNewer(String version, int build) {
    final cmp = _compareVersions(version, currentVersion);
    return cmp > 0 || (cmp == 0 && build > currentBuild);
  }

  int _compareVersions(String a, String b) {
    final aa = a
        .split(RegExp(r'[^0-9]+'))
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final bb = b
        .split(RegExp(r'[^0-9]+'))
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final length = aa.length > bb.length ? aa.length : bb.length;
    for (var i = 0; i < length; i++) {
      final av = i < aa.length ? aa[i] : 0;
      final bv = i < bb.length ? bb[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  String? _safeRelative(String input) {
    final normalized = p.normalize(input.replaceAll('\\', '/'));
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../')) return null;
    return normalized;
  }

  String _psQuote(String value) => value.replaceAll("'", "''");
  String _shQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
  String _appleScriptQuote(String value) =>
      '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  String? _currentMacBundlePath() {
    var dir = Directory(p.dirname(Platform.resolvedExecutable));
    for (var i = 0; i < 6; i++) {
      if (dir.path.endsWith('.app')) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }
}

extension _FirstOrNullUpdate<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
