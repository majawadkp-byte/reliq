import 'package:flutter/material.dart';

import 'v3_style.dart';

class ShortcutHelperBar extends StatelessWidget {
  final List<(String, String)> items;
  final EdgeInsetsGeometry margin;

  const ShortcutHelperBar({
    super.key,
    required this.items,
    this.margin = const EdgeInsets.only(top: 10),
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.keyboard_alt_outlined,
              size: 16, color: V3Style.muted),
          for (final item in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Text(item.$1,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 4),
              Text(item.$2,
                  style: const TextStyle(fontSize: 10.5, color: V3Style.muted)),
            ]),
        ],
      ),
    );
  }
}
