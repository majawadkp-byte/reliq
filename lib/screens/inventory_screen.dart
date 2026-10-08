import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String query = '';

  Future<void> adjust(Map<String, Object?> product) async {
    final qtyCtl = TextEditingController();
    final reasonCtl = TextEditingController(text: 'Manual stock adjustment');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Adjust ${product['name']}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: qtyCtl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                decoration: const InputDecoration(
                    labelText: 'Quantity change (+ / -)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: reasonCtl,
                  decoration: const InputDecoration(
                      labelText: 'Reason', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (ok == true) {
      final change = double.tryParse(qtyCtl.text);
      if (change != null && change != 0) {
        try {
          await AppDatabase.instance.adjustStock(
              product['id'] as String, change, reasonCtl.text.trim());
          if (mounted) setState(() {});
        } catch (e) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(e.toString().replaceFirst('Exception: ', ''))));
        }
      }
    }
    qtyCtl.dispose();
    reasonCtl.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: V3Style.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Inventory',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search inventory',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
                future: AppDatabase.instance.products(search: query),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? [];
                  if (rows.isEmpty)
                    return const Center(
                        child: Text('No inventory products found.'));
                  return ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final product = rows[i];
                      final stock = (product['stock'] as num? ?? 0).toDouble();
                      final minStock =
                          (product['min_stock'] as num? ?? 0).toDouble();
                      return Card(
                        child: ListTile(
                          title: Text('${product['name']}'),
                          subtitle: Text(
                              'SKU ${product['sku'] ?? '—'} • Minimum ${minStock.toStringAsFixed(2)}'),
                          leading: Icon(stock <= minStock
                              ? Icons.warning_amber
                              : Icons.inventory_2_outlined),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(stock.toStringAsFixed(2),
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                              IconButton(
                                  onPressed: () => adjust(product),
                                  icon: const Icon(Icons.tune),
                                  tooltip: 'Adjust stock'),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
}
