import 'package:flutter/material.dart';

class SearchableMapSelect extends StatefulWidget {
  final List<Map<String, Object?>> options;
  final String? value;
  final String labelText;
  final String hintText;
  final bool enabled;
  final bool allowClear;
  final FocusNode? focusNode;
  final ValueChanged<String?> onChanged;
  final String Function(Map<String, Object?>) display;
  final String Function(Map<String, Object?>)? subtitle;

  const SearchableMapSelect({
    super.key,
    required this.options,
    required this.value,
    required this.labelText,
    required this.onChanged,
    required this.display,
    this.subtitle,
    this.hintText = 'Type to search...',
    this.enabled = true,
    this.allowClear = false,
    this.focusNode,
  });

  @override
  State<SearchableMapSelect> createState() => _SearchableMapSelectState();
}

class _SearchableMapSelectState extends State<SearchableMapSelect> {
  final controller = TextEditingController();
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  double _fieldWidth = 420;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _syncText();
  }

  @override
  void didUpdateWidget(covariant SearchableMapSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      if (_ownsFocusNode) _focusNode.dispose();
      _ownsFocusNode = widget.focusNode == null;
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.value != widget.value ||
        oldWidget.options.length != widget.options.length) {
      _syncText();
    }
  }

  void _syncText() {
    if (widget.value == null || widget.value!.isEmpty) {
      controller.text = '';
      return;
    }
    final matches =
        widget.options.where((x) => '${x['id']}' == widget.value).toList();
    controller.text = matches.isEmpty ? '' : widget.display(matches.first);
  }

  Iterable<Map<String, Object?>> _options(TextEditingValue value) {
    if (!widget.enabled) return const <Map<String, Object?>>[];
    final query = value.text.trim().toLowerCase();
    return widget.options.where((row) {
      if (query.isEmpty) return true;
      final text = '${widget.display(row)} ${widget.subtitle?.call(row) ?? ''}'
          .toLowerCase();
      final terms =
          query.split(RegExp(r'\s+')).where((term) => term.isNotEmpty);
      return terms.every(text.contains);
    }).take(8);
  }

  void _choose(Map<String, Object?> row) {
    controller.text = widget.display(row);
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);
    widget.onChanged('${row['id']}');
  }

  @override
  void dispose() {
    controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Map<String, Object?>>(
      textEditingController: controller,
      focusNode: _focusNode,
      optionsViewOpenDirection: OptionsViewOpenDirection.down,
      optionsBuilder: _options,
      displayStringForOption: widget.display,
      onSelected: _choose,
      fieldViewBuilder:
          (context, fieldController, fieldFocusNode, onFieldSubmitted) {
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
              _fieldWidth = constraints.maxWidth;
            }
            return TextField(
              controller: fieldController,
              focusNode: fieldFocusNode,
              enabled: widget.enabled,
              onTap: () {
                if (widget.value != null &&
                    widget.value!.isNotEmpty &&
                    fieldController.text.isNotEmpty) {
                  fieldController.selection = TextSelection(
                      baseOffset: 0, extentOffset: fieldController.text.length);
                }
              },
              onSubmitted: (_) => onFieldSubmitted(),
              decoration: InputDecoration(
                labelText: widget.labelText,
                hintText: widget.hintText,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: widget.allowClear &&
                        widget.value != null &&
                        widget.value!.isNotEmpty
                    ? IconButton(
                        tooltip: 'Clear ${widget.labelText.toLowerCase()}',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          fieldController.clear();
                          widget.onChanged(null);
                          fieldFocusNode.requestFocus();
                        },
                      )
                    : null,
              ),
            );
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final rows = options.toList(growable: false);
        final width = _fieldWidth.clamp(280.0, 560.0).toDouble();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 10,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Container(
              width: width,
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                itemCount: rows.length,
                separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: .55)),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final secondary = widget.subtitle?.call(row) ?? '';
                  return InkWell(
                    onTap: widget.enabled ? () => onSelected(row) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.display(row),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (secondary.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              secondary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
