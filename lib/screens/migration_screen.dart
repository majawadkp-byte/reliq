import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/v3_migration.dart';
import '../ui/v3_style.dart';

class MigrationScreen extends StatefulWidget {
  const MigrationScreen({super.key});

  @override
  State<MigrationScreen> createState() => _MigrationScreenState();
}

class _MigrationScreenState extends State<MigrationScreen> {
  bool busy = false;
  String message =
      'Choose a COPY of your V3 SQLite database. RELIQ creates another backup before importing.';

  Future<void> runMigration() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select V3 database copy',
      type: FileType.any,
      allowMultiple: false,
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    setState(() {
      busy = true;
      message = 'Backing up and importing…';
    });
    try {
      final result = await V3Migration().importDatabase(path);
      if (!mounted) return;
      setState(() {
        message =
            'Imported ${result.rows} rows from ${result.tables} tables. Backup: ${result.backupPath}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => message =
          'Migration failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: ListView(
          children: [
            const Text('V3 Migration',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            const Text(
                'This tool never writes to the selected V3 database. It first creates a byte-for-byte backup and then imports compatible tables into the V4 database inside a transaction.'),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: busy ? null : runMigration,
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: Text(busy ? 'Importing…' : 'Choose V3 Database Copy')),
            const SizedBox(height: 20),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(message))),
          ],
        ),
      );
}
