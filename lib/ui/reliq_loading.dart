import 'package:flutter/material.dart';

import 'v3_style.dart';

/// Shared RELIQ loading state. Use this instead of rendering an empty dataset
/// while a database or analytics Future is still running.
class ReliqLoadingState extends StatelessWidget {
  final String message;
  final String? detail;
  final bool compact;

  const ReliqLoadingState({
    super.key,
    required this.message,
    this.detail,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: compact ? 18 : 24,
          child: const CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: const TextStyle(fontWeight: FontWeight.w800)),
              if (detail != null && detail!.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(detail!, style: const TextStyle(color: V3Style.muted, fontSize: 12)),
              ],
            ],
          ),
        ),
      ],
    );
    if (compact) return body;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(child: Padding(padding: const EdgeInsets.all(20), child: body)),
      ),
    );
  }
}

void showReliqWorkingSnack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    duration: const Duration(days: 1),
    content: Row(children: [
      const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      const SizedBox(width: 12),
      Expanded(child: Text(message)),
    ]),
  ));
}

void hideReliqWorkingSnack(BuildContext context) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
}
