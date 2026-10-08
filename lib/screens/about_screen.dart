import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/brand.dart';
import '../ui/v3_style.dart';

class AboutScreen extends StatelessWidget {
  final VoidCallback onOpenHelp;
  final VoidCallback onOpenShortcuts;
  final VoidCallback onOpenLicense;

  const AboutScreen({
    super.key,
    required this.onOpenHelp,
    required this.onOpenShortcuts,
    required this.onOpenLicense,
  });

  Future<void> _openExternal(BuildContext context, String value) async {
    try {
      ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('/usr/bin/open', [value]);
      } else if (Platform.isWindows) {
        result = await Process.run(
          'cmd',
          ['/c', 'start', '', value],
          runInShell: true,
        );
      } else if (Platform.isLinux) {
        result = await Process.run('xdg-open', [value]);
      } else {
        throw UnsupportedError('Opening links is not supported on this platform.');
      }
      if (result.exitCode != 0) {
        throw Exception('The link could not be opened.');
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the link. You can copy it instead.')),
      );
    }
  }

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final logo = dark ? 'assets/branding/reliq_logo_white.png' : Brand.logoAsset;
    final muted = V3Style.mutedFor(context);

    return SingleChildScrollView(
      padding: V3Style.pagePadding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    children: [
                      Image.asset(logo, height: 72, fit: BoxFit.contain),
                      const SizedBox(height: 18),
                      Text(
                        Brand.tagline,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'RELIQ brings POS, inventory, purchasing, accounting and practical business intelligence into one dependable local-first workspace.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted, height: 1.45),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          _InfoChip(label: Brand.versionLabel, icon: Icons.apps_outlined),
                          _InfoChip(label: 'Build ${Brand.buildNumber}', icon: Icons.build_outlined),
                          _InfoChip(label: 'Database schema ${Brand.databaseVersion}', icon: Icons.storage_outlined),
                          const _InfoChip(label: 'Local / Offline ready', icon: Icons.cloud_off_outlined),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final cardWidth = width >= 900 ? (width - 24) / 3 : width >= 620 ? (width - 12) / 2 : width;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: cardWidth,
                        child: const _AboutFeature(
                          icon: Icons.point_of_sale_outlined,
                          title: 'Run the business',
                          body: 'Fast sales, purchasing, stock movement, customer and supplier accounts in one connected workflow.',
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: const _AboutFeature(
                          icon: Icons.auto_graph_outlined,
                          title: 'Understand the business',
                          body: 'Morning Brief, inventory intelligence, trends and Smart Buying turn operational data into useful decisions.',
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: const _AboutFeature(
                          icon: Icons.verified_user_outlined,
                          title: 'Keep it accountable',
                          body: 'Ledgers, document history, permissions, backups and the audit trail protect traceability as the business grows.',
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: V3Style.blue.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.support_agent_outlined, color: V3Style.blue),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Contact RELIQ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                                const SizedBox(height: 3),
                                Text('Product help, implementation questions and support.', style: TextStyle(color: muted)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final narrow = constraints.maxWidth < 650;
                          final phone = _ContactItem(
                            icon: Icons.phone_outlined,
                            label: 'Contact number',
                            value: Brand.supportPhone,
                            onTap: () => _copy(context, 'Contact number', Brand.supportPhone),
                            actionLabel: 'Copy',
                          );
                          final website = _ContactItem(
                            icon: Icons.language_outlined,
                            label: 'Website',
                            value: Brand.websiteLabel,
                            onTap: () => _openExternal(context, Brand.websiteUrl),
                            actionLabel: 'Open',
                          );
                          if (narrow) {
                            return Column(children: [phone, const SizedBox(height: 10), website]);
                          }
                          return Row(
                            children: [
                              Expanded(child: phone),
                              const SizedBox(width: 12),
                              Expanded(child: website),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 700;
                      final intro = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('RELIQ resources', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text('Open product help, review every keyboard shortcut, or check license information.', style: TextStyle(color: muted)),
                        ],
                      );
                      final actions = Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(onPressed: onOpenHelp, icon: const Icon(Icons.help_outline), label: const Text('Help Center')),
                          OutlinedButton.icon(onPressed: onOpenShortcuts, icon: const Icon(Icons.keyboard_alt_outlined), label: const Text('Keyboard Shortcuts')),
                          FilledButton.icon(onPressed: onOpenLicense, icon: const Icon(Icons.verified_user_outlined), label: const Text('License')),
                        ],
                      );
                      if (narrow) {
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [intro, const SizedBox(height: 14), actions]);
                      }
                      return Row(children: [Expanded(child: intro), const SizedBox(width: 16), actions]);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(Brand.copyright, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: muted)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final String actionLabel;

  const _ContactItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: V3Style.blue),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 11, color: V3Style.mutedFor(context))),
                  const SizedBox(height: 2),
                  SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            TextButton(onPressed: onTap, child: Text(actionLabel)),
          ],
        ),
      );
}

class _InfoChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _InfoChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .55),
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: V3Style.blue),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _AboutFeature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _AboutFeature({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: V3Style.blue.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: V3Style.blue),
              ),
              const SizedBox(height: 14),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(body, style: TextStyle(color: V3Style.mutedFor(context), height: 1.4)),
            ],
          ),
        ),
      );
}
