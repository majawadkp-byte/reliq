import 'package:flutter/material.dart';
import 'v3_style.dart';
import 'reliq_surface.dart';

class V4PaginationBar extends StatelessWidget {
  final int total;
  final int page;
  final int pageSize;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onPageSizeChanged;

  const V4PaginationBar({
    super.key,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.onPageChanged,
    required this.onPageSizeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pages = total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize);
    final safePage = page.clamp(0, pages - 1).toInt();
    final from = total == 0 ? 0 : safePage * pageSize + 1;
    final to = total == 0 ? 0 : ((safePage + 1) * pageSize).clamp(0, total).toInt();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: ReliqSurface.glassStrong(context),
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(children: [
        Text('$from–$to of $total', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const Spacer(),
        const Text('Rows', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 7),
        DropdownButton<int>(
          value: pageSize,
          underline: const SizedBox.shrink(),
          items: const [10, 25, 50, 100].map((x) => DropdownMenuItem(value: x, child: Text('$x'))).toList(),
          onChanged: (v) { if (v != null) onPageSizeChanged(v); },
        ),
        const SizedBox(width: 14),
        IconButton(tooltip: 'Previous page', onPressed: safePage > 0 ? () => onPageChanged(safePage - 1) : null, icon: const Icon(Icons.chevron_left)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 7), child: Text('${safePage + 1} / $pages', style: const TextStyle(fontWeight: FontWeight.w700))),
        IconButton(tooltip: 'Next page', onPressed: safePage + 1 < pages ? () => onPageChanged(safePage + 1) : null, icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }
}

class V4AlternateRow extends StatelessWidget {
  final int index;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double minHeight;

  const V4AlternateRow({super.key, required this.index, required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10), this.minHeight = 58});

  @override
  Widget build(BuildContext context) {
    final background = index.isOdd ? V3Style.rowStripe(context) : Colors.transparent;
    final themedMin = Theme.of(context).listTileTheme.minTileHeight ?? minHeight;
    return Container(
      constraints: BoxConstraints(minHeight: themedMin > minHeight ? themedMin : minHeight),
      padding: padding,
      color: background,
      child: child,
    );
  }
}
