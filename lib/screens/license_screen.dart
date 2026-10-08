import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../services/license_manager.dart';
import '../ui/v3_style.dart';

class LicenseScreen extends StatefulWidget {
  const LicenseScreen({super.key});

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final keyController = TextEditingController();
  LicenseState? state;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    keyController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => busy = true);
    final current = await LicenseManager.instance.current();
    if (!mounted) return;
    setState(() {
      state = current;
      busy = false;
    });
  }

  Future<void> activateLicense() async {
    if (keyController.text.trim().isEmpty) return;
    setState(() => busy = true);
    final result = await LicenseManager.instance.activate(keyController.text);
    if (!mounted) return;
    setState(() {
      state = result;
      busy = false;
      if (result.validSignature) keyController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(result.usable
              ? 'License activated successfully.'
              : result.message)),
    );
  }

  Future<void> refreshLicense() async {
    setState(() => busy = true);
    final result = await LicenseManager.instance.refresh();
    if (!mounted) return;
    setState(() {
      state = result;
      busy = false;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> removeLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove local activation?'),
        content: const Text(
            'This only removes the signed token from this computer. It does not cancel the license on the licensing server.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await LicenseManager.instance.clear();
    await load();
  }

  Widget stat(String label, String value, {IconData? icon}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: V3Style.blue),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 6),
                      Text(value,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800)),
                    ]),
              ),
            ],
          ),
        ),
      );

  String date(DateTime? value) =>
      value == null ? '—' : DateFormat.yMMMd().format(value);

  Color statusColor(LicenseState s) {
    if (s.usable && s.isTrial) return V3Style.gold;
    if (s.usable) return V3Style.success;
    if (s.expired || s.validationRequired) return V3Style.danger;
    return V3Style.muted;
  }

  @override
  Widget build(BuildContext context) {
    if (busy) return const Center(child: CircularProgressIndicator());
    final s = state ??
        const LicenseState(
            configured: false,
            activated: false,
            validSignature: false,
            expired: false);
    final remaining = s.daysRemaining;
    final statusText = s.usable
        ? s.isTrial
            ? 'Trial Active${remaining == null ? '' : ' • $remaining days remaining'}'
            : 'Active'
        : s.validationRequired
            ? 'Validation Required'
            : s.expired
                ? 'Expired'
                : 'Activation Required';

    final dark = Theme.of(context).brightness == Brightness.dark;
    final brandLogo =
        dark ? 'assets/branding/reliq_logo_white.png' : Brand.logoAsset;

    return ListView(
      padding: V3Style.pagePadding,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 300,
            height: 64,
            child: Image.asset(brandLogo,
                fit: BoxFit.contain, alignment: Alignment.centerLeft),
          ),
        ),
        const SizedBox(height: 6),
        Text('License & Activation',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(
            'Manage this installation’s RELIQ license, plan limits and activation status.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 18),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
                color: statusColor(s).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14)),
            child: Icon(
                s.usable ? Icons.verified_user_rounded : Icons.shield_outlined,
                color: statusColor(s),
                size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  s.isTrial
                      ? 'RELIQ Business Trial'
                      : s.usable
                          ? 'RELIQ ${s.plan}'
                          : 'RELIQ Licensing',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 5),
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                      color: statusColor(s).withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(statusText,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          color: statusColor(s))),
                ),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(s.message,
                        style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ]),
          ),
          if (s.activated)
            OutlinedButton.icon(
                onPressed: refreshLicense,
                icon: const Icon(Icons.sync),
                label: const Text('Refresh License')),
        ]),
        const SizedBox(height: 20),
        if (s.payload != null) ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                  width: 245,
                  child: stat('Plan', s.plan,
                      icon: Icons.workspace_premium_outlined)),
              SizedBox(
                  width: 245,
                  child: stat(
                      'Business',
                      s.businessName.isEmpty
                          ? (s.isTrial ? 'Trial installation' : '—')
                          : s.businessName,
                      icon: Icons.storefront_outlined)),
              SizedBox(
                  width: 205,
                  child: stat('Activated', date(s.activatedAt),
                      icon: Icons.event_available_outlined)),
              SizedBox(
                  width: 205,
                  child: stat('Expires',
                      s.expiresAt == null ? 'Lifetime' : date(s.expiresAt),
                      icon: Icons.event_busy_outlined)),
              SizedBox(
                  width: 180,
                  child: stat(
                      'Duration',
                      s.expiresAt == null
                          ? 'Lifetime'
                          : '${s.durationDays} days',
                      icon: Icons.timelapse_outlined)),
              SizedBox(
                  width: 180,
                  child: stat('Users',
                      s.maxUsers == 0 ? 'Unlimited' : s.maxUsers.toString(),
                      icon: Icons.people_outline)),
              SizedBox(
                  width: 180,
                  child: stat(
                      'Terminals',
                      s.maxTerminals == 0
                          ? 'Unlimited'
                          : s.maxTerminals.toString(),
                      icon: Icons.computer_outlined)),
              SizedBox(
                  width: 180,
                  child: stat(
                      'Branches',
                      s.maxBranches == 0
                          ? 'Unlimited'
                          : s.maxBranches.toString(),
                      icon: Icons.account_tree_outlined)),
              if (s.licenseId.isNotEmpty)
                SizedBox(
                    width: 245,
                    child: stat('License ID', s.licenseId,
                        icon: Icons.tag_outlined)),
              if (s.lastValidatedAt != null)
                SizedBox(
                    width: 245,
                    child: stat('Last Online Validation',
                        DateFormat.yMMMd().add_jm().format(s.lastValidatedAt!),
                        icon: Icons.cloud_done_outlined)),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Enabled Features',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in s.entitlements.toList()..sort())
                          Chip(
                            avatar: const Icon(Icons.check_circle_outline,
                                size: 16),
                            label: Text(e.replaceAll('_', ' ')),
                          ),
                      ],
                    ),
                  ]),
            ),
          ),
          const SizedBox(height: 22),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  s.isTrial
                      ? 'Activate after trial'
                      : 'Activate / Renew / Upgrade',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 5),
              const Text(
                  'Enter the short key supplied by the vendor. RELIQ will automatically fetch the plan, activation date, duration, limits and enabled features.'),
              const SizedBox(height: 15),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: keyController,
                    textCapitalization: TextCapitalization.characters,
                    onSubmitted: (_) => activate(),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]'))
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Activation key',
                      hintText: 'V4-XXXX-XXXX-XXXX-XXXX',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                    onPressed: activateLicense,
                    icon: const Icon(Icons.verified_outlined),
                    label: const Text('Activate')),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final value = data?.text?.trim();
                    if (value != null && value.isNotEmpty)
                      setState(() => keyController.text = value);
                  },
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                ),
              ]),
              const SizedBox(height: 12),
              Text(
                'A first internet connection is required to start the 14-day trial or activate a key. After activation RELIQ works offline and periodically validates the signed license.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
        ),
        if (s.activated) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: removeLocal,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove local license token')),
          ),
        ],
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.security_outlined, color: V3Style.blue),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Security model: RELIQ stores only a cryptographically signed license token and the public verification key. The private Ed25519 signing key remains on your private licensing server. Expired or overdue licenses become read-only instead of hiding the customer’s data.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
