import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../config/brand.dart';
import '../data/app_database.dart';
import '../services/update_manager.dart';
import '../ui/v3_style.dart';

class SystemUpdatesScreen extends StatefulWidget {
  const SystemUpdatesScreen({super.key});

  @override
  State<SystemUpdatesScreen> createState() => _SystemUpdatesScreenState();
}

class _SystemUpdatesScreenState extends State<SystemUpdatesScreen> {
  final manifestUrl = TextEditingController();
  String channel = 'Stable';
  bool autoCheck = false;
  bool loading = true;
  bool busy = false;
  String message = '';
  int dbVersion = 0;
  List<Map<String, Object?>> history = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await AppDatabase.instance.settings();
    final dbv = await UpdateManager.instance.currentDatabaseVersion();
    final rows = await UpdateManager.instance.history();
    if (!mounted) return;
    setState(() {
      manifestUrl.text = settings['update_manifest_url'] ?? '';
      channel = settings['update_channel'] ?? 'Stable';
      autoCheck = settings['auto_check_updates'] == '1';
      dbVersion = dbv;
      history = rows;
      loading = false;
    });
  }

  Future<void> _savePreferences() async {
    await AppDatabase.instance.saveSettings({
      'update_manifest_url': manifestUrl.text.trim(),
      'update_channel': channel,
      'auto_check_updates': autoCheck ? '1' : '0',
    });
    if (mounted) setState(() => message = 'Update preferences saved.');
  }

  Future<void> _checkOnline() async {
    setState(() {
      busy = true;
      message = 'Checking for updates…';
    });
    try {
      await _savePreferences();
      final info = await UpdateManager.instance.checkOnline(
        manifestUrl.text.trim(),
        channel: channel.toLowerCase(),
      );
      if (!mounted) return;
      if (info == null) {
        setState(() => message =
            'RELIQ ${Brand.version} is up to date on the ${channel.toLowerCase()} channel.');
        return;
      }
      final accept = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('RELIQ ${info.version} is available'),
              content: SizedBox(
                  width: 520,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'Build ${info.build} · Database target ${info.targetDatabaseVersion}'),
                        const SizedBox(height: 12),
                        const Text('What’s new',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text(info.releaseNotes.trim().isEmpty
                            ? 'No release notes supplied.'
                            : info.releaseNotes),
                        const SizedBox(height: 12),
                        const Text(
                            'RELIQ will download the package, verify it, create a safety database backup, then ask before restarting to install.',
                            style:
                                TextStyle(color: V3Style.muted, fontSize: 12)),
                      ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Later')),
                FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Download update')),
              ],
            ),
          ) ??
          false;
      if (!accept) return;
      if (!mounted) return;
      setState(() => message = 'Downloading update package…');
      final path = await UpdateManager.instance.downloadPackage(info);
      await _stageAndConfirm(path);
    } catch (e) {
      if (mounted) setState(() => message = 'Update check failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
      await _load();
    }
  }

  Future<void> _installOffline() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose RELIQ offline update package',
      type: FileType.custom,
      allowedExtensions: const ['reliq'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() {
      busy = true;
      message = 'Validating offline update package…';
    });
    try {
      await _stageAndConfirm(path);
    } catch (e) {
      if (mounted) setState(() => message = 'Offline update rejected: $e');
    } finally {
      if (mounted) setState(() => busy = false);
      await _load();
    }
  }

  Future<void> _stageAndConfirm(String path) async {
    final staged = await UpdateManager.instance.stagePackage(path);
    if (!mounted) return;
    final install = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: Text('Install RELIQ ${staged.info.version}?'),
            content: SizedBox(
                width: 560,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fact('Current version',
                          '${Brand.version}+${Brand.buildNumber}'),
                      _fact('New version',
                          '${staged.info.version}+${staged.info.build}'),
                      _fact('Current database', 'v$dbVersion'),
                      _fact('Target database',
                          'v${staged.info.targetDatabaseVersion}'),
                      _fact('Safety backup', staged.backupPath),
                      const SizedBox(height: 12),
                      const Text(
                          'RELIQ will close, replace the application files, reopen, then run any required database migration automatically. Your live database is stored separately and is not replaced by the app update.',
                          style: TextStyle(fontSize: 12)),
                      if (Platform.isMacOS) ...[
                        const SizedBox(height: 8),
                        const Text(
                            'macOS may request an administrator password when RELIQ is installed in /Applications.',
                            style:
                                TextStyle(fontSize: 11, color: V3Style.muted)),
                      ],
                    ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now')),
              FilledButton.icon(
                  onPressed: () => Navigator.pop(c, true),
                  icon: const Icon(Icons.system_update_alt),
                  label: const Text('Restart & install')),
            ],
          ),
        ) ??
        false;
    if (!install) {
      setState(() => message =
          'Update ${staged.info.version} is staged. You can choose the package again when ready to install.');
      return;
    }
    setState(() => message = 'Starting external updater…');
    await UpdateManager.instance.launchInstallerAndExit(staged);
  }

  Widget _fact(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 145,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: SelectableText(value)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  color: const Color(0xFFEAF1FF),
                  borderRadius: BorderRadius.circular(12)),
              child:
                  const Icon(Icons.system_update_alt, color: V3Style.blueDark)),
          const SizedBox(width: 12),
          const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('System & Updates',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text(
                    'Update RELIQ online or from a local offline package without replacing customer data.',
                    style: TextStyle(color: V3Style.muted, fontSize: 12)),
              ])),
        ]),
        const SizedBox(height: 16),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Installed version',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      _fact('Application',
                          '${Brand.version}+${Brand.buildNumber}'),
                      _fact('Database schema', 'v$dbVersion'),
                      _fact('Platform', Platform.operatingSystem),
                      const SizedBox(height: 10),
                      const Text(
                          'The customer database lives in the application-support data folder, separate from the program files. An update replaces the program, not the business database.',
                          style: TextStyle(color: V3Style.muted, fontSize: 11)),
                    ]))),
        const SizedBox(height: 14),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Offline update',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 5),
                      const Text(
                          'Works without internet. Copy a RELIQ .reliq update package by USB, local network, email download, or any other method, then install it here.',
                          style: TextStyle(color: V3Style.muted, fontSize: 12)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          onPressed: busy ? null : _installOffline,
                          icon: const Icon(Icons.folder_zip_outlined),
                          label: const Text('Install update package')),
                    ]))),
        const SizedBox(height: 14),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Online updates',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      TextField(
                          controller: manifestUrl,
                          decoration: const InputDecoration(
                              labelText: 'Update manifest URL',
                              hintText:
                                  'https://updates.example.com/reliq/stable.json')),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                            child: DropdownButtonFormField<String>(
                                value: channel,
                                decoration: const InputDecoration(
                                    labelText: 'Update channel'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'Stable', child: Text('Stable')),
                                  DropdownMenuItem(
                                      value: 'Beta', child: Text('Beta'))
                                ],
                                onChanged: (v) =>
                                    setState(() => channel = v ?? 'Stable'))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Check automatically'),
                                subtitle: const Text(
                                    'Only checks when internet is available.'),
                                value: autoCheck,
                                onChanged: (v) =>
                                    setState(() => autoCheck = v))),
                      ]),
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.tonalIcon(
                            onPressed: busy ? null : _checkOnline,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Check for updates')),
                        OutlinedButton.icon(
                            onPressed: busy ? null : _savePreferences,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save update settings')),
                      ]),
                    ]))),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 14),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (busy) ...[
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10)
                        ] else ...[
                          const Icon(Icons.info_outline,
                              size: 19, color: V3Style.blue),
                          const SizedBox(width: 10)
                        ],
                        Expanded(child: Text(message)),
                      ]))),
        ],
        const SizedBox(height: 14),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Update history',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      if (history.isEmpty)
                        const Text('No update activity recorded yet.',
                            style: TextStyle(color: V3Style.muted))
                      else
                        ...history.take(10).map((r) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: Icon(
                                  (r['status'] ?? '') == 'Completed'
                                      ? Icons.check_circle_outline
                                      : Icons.history,
                                  color: V3Style.blue),
                              title: Text(
                                  '${r['status'] ?? ''} · ${r['version'] ?? ''}'),
                              subtitle: Text(
                                  '${r['created_at'] ?? ''}\n${r['details'] ?? ''}'),
                              isThreeLine: true,
                            )),
                    ]))),
      ]),
    );
  }

  @override
  void dispose() {
    manifestUrl.dispose();
    super.dispose();
  }
}
