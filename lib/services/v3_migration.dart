import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../data/app_database.dart';

class MigrationResult {
  final int tables;
  final int rows;
  final String backupPath;
  const MigrationResult(this.tables, this.rows, this.backupPath);
}

class V3Migration {
  static const tables = [
    'settings',
    'users',
    'products',
    'customers',
    'suppliers',
    'sales',
    'sale_items',
    'purchases',
    'purchase_items',
    'stock_movements',
    'payments',
    'expenses',
    'audit'
  ];
  Future<MigrationResult> importDatabase(String source) async {
    final src = File(source);
    if (!await src.exists()) throw Exception('V3 database not found.');
    final dir = await AppDatabase.instance.dataDir;
    final backups = Directory(p.join(dir, 'migration_backups'));
    await backups.create(recursive: true);
    final backup =
        p.join(backups.path, 'v3_${DateTime.now().millisecondsSinceEpoch}.db');
    await src.copy(backup);
    final old = await databaseFactory.openDatabase(source,
        options: OpenDatabaseOptions(readOnly: true));
    int rows = 0, done = 0;
    try {
      await AppDatabase.instance.db.transaction((txn) async {
        for (final table in tables) {
          final exists = await old.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
              [table]);
          if (exists.isEmpty) continue;
          final oldCols = (await old.rawQuery('PRAGMA table_info($table)'))
              .map((e) => e['name'] as String)
              .toSet();
          final newCols = (await txn.rawQuery('PRAGMA table_info($table)'))
              .map((e) => e['name'] as String)
              .toSet();
          final cols = oldCols.intersection(newCols).toList();
          if (cols.isEmpty) continue;
          final data = await old.query(table, columns: cols);
          await txn.delete(table);
          for (final row in data) {
            await txn.insert(table, row,
                conflictAlgorithm: ConflictAlgorithm.replace);
            rows++;
          }
          done++;
        }
        await txn.insert('app_meta', {'k': 'migrated_from', 'v': 'V3.7.1'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      });
    } finally {
      await old.close();
    }
    await AppDatabase.instance.repairIdentity();
    return MigrationResult(done, rows, backup);
  }
}
