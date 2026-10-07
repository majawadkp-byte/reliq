import 'package:flutter/material.dart';
import 'v3_style.dart';
import 'reliq_surface.dart';

enum V4Tone { primary, success, warning, danger, info, purple, neutral }

Color v4ToneColor(V4Tone tone) => switch (tone) {
      V4Tone.success => V3Style.success,
      V4Tone.warning => V3Style.warning,
      V4Tone.danger => V3Style.danger,
      V4Tone.info => V3Style.info,
      V4Tone.purple => V3Style.purple,
      V4Tone.neutral => V3Style.muted,
      V4Tone.primary => V3Style.blue,
    };

class V4PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  const V4PageHeader({super.key, required this.title, required this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.35)),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        );
        if (actions.isEmpty) return copy;
        if (c.maxWidth < 760) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            copy,
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: copy),
          const SizedBox(width: 16),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ]);
      });
}

class V4SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool clip;
  const V4SectionCard({super.key, required this.child, this.padding = V3Style.cardPadding, this.clip = false});

  @override
  Widget build(BuildContext context) => ReliqGlass(
        padding: padding,
        radius: V3Style.radiusLg,
        blur: 14,
        clip: clip,
        child: child,
      );
}

class V4SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const V4SectionTitle(this.title, {super.key, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ])),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ]);
}

class V4StatusPill extends StatelessWidget {
  final String label;
  final V4Tone tone;
  final IconData? icon;
  const V4StatusPill(this.label, {super.key, this.tone = V4Tone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    final accent = v4ToneColor(tone);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: V3Style.softFor(accent, dark: dark),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: dark ? .40 : .22)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: accent), const SizedBox(width: 5)],
        Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: accent)),
      ]),
    );
  }
}

class V4EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const V4EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: .09), borderRadius: BorderRadius.circular(16)),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 28),
              ),
              const SizedBox(height: 14),
              Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ]),
          ),
        ),
      );
}

class V4StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? helper;
  final IconData icon;
  final V4Tone tone;
  final VoidCallback? onTap;
  const V4StatTile({super.key, required this.label, required this.value, required this.icon, this.helper, this.tone = V4Tone.primary, this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = v4ToneColor(tone);
    final content = Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 13),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 34, height: 34, decoration: BoxDecoration(color: V3Style.softFor(accent, dark: Theme.of(context).brightness == Brightness.dark), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: accent, size: 18)),
            const Spacer(),
            if (onTap != null) Icon(Icons.chevron_right, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ]),
          const SizedBox(height: 15),
          Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -.4)),
          const SizedBox(height: 3),
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .65, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          if (helper != null) ...[const SizedBox(height: 3), Text(helper!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))],
          const SizedBox(height: 10),
          Container(height: 3, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(99))),
        ]),
      ),
    );
    return onTap == null ? content : InkWell(borderRadius: BorderRadius.circular(V3Style.radiusLg), onTap: onTap, child: content);
  }
}
