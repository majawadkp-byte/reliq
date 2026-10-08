import 'package:flutter/material.dart';

import '../data/app_database.dart';
import 'v3_style.dart';

class V4ProductSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<Map<String, Object?>> onSelected;
  final bool activeOnly;
  final String hintText;
  final int maxResults;
  final Set<String>? allowedProductTypes;
  final String? excludeProductId;
  final bool sellableOnly;
  final bool purchasableOnly;

  const V4ProductSearchField({
    super.key,
    required this.controller,
    required this.onSelected,
    this.focusNode,
    this.activeOnly = false,
    this.hintText = 'Scan barcode / type SKU / product name...',
    this.maxResults = 8,
    this.allowedProductTypes,
    this.excludeProductId,
    this.sellableOnly = false,
    this.purchasableOnly = false,
  });

  @override
  State<V4ProductSearchField> createState() => _V4ProductSearchFieldState();
}

class _V4ProductSearchFieldState extends State<V4ProductSearchField> {
  final MenuController menu = MenuController();
  List<Map<String, Object?>> results = const [];
  int requestId = 0;

  Future<void> _search(String value) async {
    final q = value.trim();
    final id = ++requestId;
    if (q.isEmpty) {
      if (mounted) setState(() => results = const []);
      if (menu.isOpen) menu.close();
      return;
    }
    final rows = await AppDatabase.instance.products(
        search: q, activeOnly: widget.activeOnly, limit: widget.maxResults * 4);
    final filtered = rows
        .where((p) {
          if (widget.excludeProductId != null &&
              '${p['id']}' == widget.excludeProductId) return false;
          final type = (p['product_type'] ?? 'Stocked').toString();
          if (widget.allowedProductTypes != null &&
              !widget.allowedProductTypes!.contains(type)) return false;
          if (widget.sellableOnly &&
              ((p['sellable'] as num?) ?? 1).toInt() != 1) return false;
          if (widget.purchasableOnly &&
              ((p['purchasable'] as num?) ?? 1).toInt() != 1) return false;
          return true;
        })
        .take(widget.maxResults)
        .toList();
    if (!mounted || id != requestId) return;
    setState(() => results = filtered);
    if (rows.isNotEmpty && !menu.isOpen) menu.open();
    if (rows.isEmpty && menu.isOpen) menu.close();
  }

  void _choose(Map<String, Object?> product) {
    if (menu.isOpen) menu.close();
    widget.onSelected(product);
  }

  void _submit(String value) {
    if (results.isNotEmpty) {
      _choose(results.first);
      return;
    }
    _search(value).then((_) {
      if (mounted && results.isNotEmpty) _choose(results.first);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: menu,
      crossAxisUnconstrained: false,
      menuChildren: [
        for (var i = 0; i < results.length; i++)
          MenuItemButton(
            onPressed: () => _choose(results[i]),
            child: SizedBox(
              width: 520,
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                      color: i == 0
                          ? Theme.of(context).colorScheme.primary.withValues(
                              alpha: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? .14
                                  : .08)
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(
                      i == 0
                          ? Icons.keyboard_return
                          : Icons.inventory_2_outlined,
                      size: 17,
                      color: i == 0 ? V3Style.blue : null),
                ),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('${results[i]['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                          '${results[i]['sku'] ?? '—'} • ${results[i]['external_barcode'] ?? results[i]['internal_barcode'] ?? 'No barcode'} • Stock ${(results[i]['stock'] as num? ?? 0).toStringAsFixed(2)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10, color: V3Style.muted)),
                    ])),
                const SizedBox(width: 8),
                Text((results[i]['cost'] as num? ?? 0).toStringAsFixed(3),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ],
      builder: (context, controller, child) => TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        autofocus: true,
        onChanged: _search,
        onSubmitted: _submit,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: widget.hintText,
          suffixIcon: widget.controller.text.isEmpty
              ? const Icon(Icons.keyboard_return, size: 18)
              : IconButton(
                  tooltip: 'Clear',
                  onPressed: () {
                    widget.controller.clear();
                    _search('');
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
    );
  }
}
