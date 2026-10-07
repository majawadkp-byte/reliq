import 'package:flutter/material.dart';

class LockedFeatureScreen extends StatelessWidget {
  const LockedFeatureScreen({super.key, required this.title, required this.entitlement});
  final String title;
  final String entitlement;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline_rounded, size: 48),
                const SizedBox(height: 16),
                Text('$title is locked', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(
                  'Your current license does not include “${entitlement.replaceAll('_', ' ')}”. Activate a Business license or add-on from the License page.',
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),
        ),
      );
}
