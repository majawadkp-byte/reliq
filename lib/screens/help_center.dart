import 'package:flutter/material.dart';

import '../ui/v3_style.dart';

class ReliqHelp {
  static Future<void> showHelpCenter(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _HelpCenterDialog(),
    );
  }

  static Future<void> showKeyboardShortcuts(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _KeyboardShortcutsDialog(),
    );
  }
}

class _HelpCenterDialog extends StatelessWidget {
  const _HelpCenterDialog();

  static const topics = <_HelpTopic>[
    _HelpTopic('Create a sale', Icons.point_of_sale_outlined, [
      'Open Sales / POS.',
      'Scan a barcode or search for a product. Confirm quantity and price.',
      'Select a customer when required; leave it as walk-in for a normal counter sale.',
      'Apply discount, delivery or other charges when applicable.',
      'Open Payment, choose the payment method and amount received.',
      'Complete the sale. Print or preview the receipt when required.',
    ]),
    _HelpTopic('Receive a purchase', Icons.download_outlined, [
      'Open Receive Purchase.',
      'Choose the supplier and enter the supplier invoice/reference if available.',
      'Add products and received quantities; enter cost, tax, discount and lot/expiry details when applicable.',
      'Add freight or other purchase charges if required.',
      'Choose the payment status or record the supplier balance.',
      'Save/post the purchase. Stock and supplier balances update from the posted document.',
    ]),
    _HelpTopic('Products & barcodes', Icons.inventory_2_outlined, [
      'Open Products & Barcodes to create or edit a product.',
      'Set the product as sellable only when it should appear in Sales / POS.',
      'Enter SKU/barcode or allow RELIQ to generate them when those options are enabled.',
      'Maintain selling price, cost, tax, category and stock-planning fields.',
      'Use RELIQ Lookup (Ctrl/Cmd + F) to search products, customers and suppliers from anywhere.',
    ]),
    _HelpTopic('Customer receipts & supplier payments', Icons.payments_outlined, [
      'Open Payments & Ledgers.',
      'Choose Customers for money received or Suppliers for money paid.',
      'Select the party and enter the receipt/payment amount and method.',
      'Allocate the amount against open invoices/bills; partial allocation is allowed.',
      'Review the party ledger afterward to confirm outstanding balances.',
    ]),
    _HelpTopic('Accounting integrity & reconciliation', Icons.account_balance_outlined, [
      'Open Payments & Ledgers → Unapplied Credits to find customer receipts or supplier advances that still have an unused amount.',
      'Choose Allocate to apply the original payment to one or more open invoices, supplier bills or opening-balance documents without creating a second payment.',
      'Open Adjustments & Opening to post opening receivables/payables, opening credits/advances, customer credit/debit notes and supplier debit/credit notes.',
      'Customer Credit Notes and Supplier Debit Notes reduce existing outstanding balances oldest-first; any excess becomes account credit/advance.',
      'Use the accounting integrity cards to compare master balances with open documents. Rebuild balances is a controlled repair action and does not change account credits.',
      'Open Reconciliation to match RELIQ payments to bank statements, card settlements, cash deposits or other reconciliation references.',
    ]),
    _HelpTopic('Stock adjustment', Icons.tune_outlined, [
      'Open Stock Adjustment.',
      'Search/select the product and branch.',
      'Enter the corrected quantity or adjustment amount and a clear reason.',
      'Post the adjustment. RELIQ keeps the movement in the audit trail.',
    ]),
    _HelpTopic('Stock transfer', Icons.swap_horiz_outlined, [
      'Open Stock Transfers.',
      'Choose source and destination branches.',
      'Add the products and quantities to move.',
      'Post the transfer and review transfer history to verify the movement.',
    ]),
    _HelpTopic('Returns', Icons.keyboard_return_outlined, [
      'Open Sales & Purchase Returns.',
      'Choose whether the return is from a customer or back to a supplier.',
      'Select the original transaction where available and enter returned quantities.',
      'Review refund/credit impact and stock restoration before posting.',
    ]),
    _HelpTopic('Reports & history', Icons.query_stats_outlined, [
      'Open Reports, Sales History, Purchase History or Day Book.',
      'Set the date range and filters required for the question you are answering.',
      'Use Ctrl/Cmd + F anywhere to open the universal RELIQ Lookup.',
      'Open a row to inspect the underlying transaction and print/export where available.',
    ]),
    _HelpTopic('Bulk product upload', Icons.upload_file_outlined, [
      'Open Products & Barcodes and choose Bulk Upload.',
      'Download the current template so the column names match RELIQ.',
      'Fill product name, SKU/barcode, purchase price, selling price, current/opening stock and optional planning/tax fields.',
      'Preview the file before importing and correct duplicate SKU/barcode or invalid number warnings.',
      'Selling price is imported from selling_price; common alternatives such as sell_price, retail_price and sale_price are also recognised.',
    ]),
    _HelpTopic('Users, permissions & audit trail', Icons.admin_panel_settings_outlined, [
      'Open Users & Roles to create accounts and assign Admin, Accountant, Cashier, Storekeeper or Viewer access.',
      'The Owner can fine-tune sensitive permissions including price overrides, posted-transaction editing, voiding, product deletion, profit visibility, migration and backup/restore.',
      'Open Audit Trail to review who performed an action, when it happened, the branch/terminal used, the affected entity/reference and the recorded details.',
      'RELIQ records operational events such as user administration, product lifecycle changes, stock adjustments, payments, posted-transaction corrections, voids and branch changes.',
      'Use controlled correction, return and void workflows instead of deleting posted accounting history.',
    ]),
    _HelpTopic('Migration Center', Icons.move_up_outlined, [
      'Open Settings → Data & Security → Migration Center, or open Migration Center from the Admin sidebar.',
      'For a simple new setup, import Products, Customers and Suppliers separately using Quick Imports.',
      'For historical takeover, import Sales/Purchases before their item files, then receipts/payments and allocation files.',
      'For a complete migration, download the Migration Template Pack, fill the CSV files your old software can export, keep them in one ZIP and choose Full Business Migration.',
      'RELIQ validates the package first and creates a safety database backup before a full migration.',
      'Use the reconciliation summary afterward to compare products, stock, sales, purchases, receivables and payables with the old system.',
    ]),
    _HelpTopic('Demand forecasting & automatic stock levels', Icons.auto_graph_outlined, [
      'Open Inventory Intelligence to expand any product and review its 7, 30, 60 and 90-day demand forecasts.',
      'RELIQ combines recent 7/30/90-day demand, short-term trend, weekday patterns, intermittent-demand behavior, demand variability and product-lifecycle history transfer.',
      'When roughly a year of history is available, the model also blends the equivalent period from last year so seasonal peaks and dips influence the forecast.',
      'Supplier lead time and calculated safety stock are used to calculate the automatic Minimum Stock / reorder point and Target Stock.',
      'Open Settings → Inventory to control the target coverage period, automatic Min/Target updates and use of last-year seasonality.',
      'Automatic stock-level updates only apply when forecast confidence is Medium or High. RELIQ never changes MOQ, order multiple or case pack.',
      'Smart Buying uses the resulting forecast target, incoming purchase orders and existing MOQ rules to calculate the suggested purchase quantity.',
    ]),
    _HelpTopic('Product lifecycle, services & replacements', Icons.change_circle_outlined, [
      'Products can be Stocked, Non-stocked, Service, Recipe or Combo. Only Stocked products maintain on-hand quantity and participate in stock valuation/reorder forecasting.',
      'Use Sellable and Purchasable independently. A service can be sellable without being purchasable; a purchase-only material can be hidden from Sales POS.',
      'If a supplier stops a product, set Lifecycle Status to Discontinued or Replaced instead of deleting transaction history.',
      'For Replaced products, choose the replacement item and optionally enter a Demand Family / Equivalent Group.',
      'The replacement forecast can inherit predecessor history while the new SKU builds its own sales history. The inherited weight reduces as the replacement gains transactions.',
      'Delete is only permanent for unused products with no stock/history. Used products are archived automatically to protect invoices, ledgers, stock movements and reports.',
      'Recipe/Combo component pickers are searchable by name, SKU or barcode instead of long dropdown lists.',
    ]),
    _HelpTopic('Printing & document behavior', Icons.print_outlined, [
      'Open Settings → Printing & Documents.',
      'Configure Sales Invoice, Customer Cash Receipt, Purchase Invoice / Goods Receipt and Supplier Payment Voucher separately.',
      'Choose None to save without opening a document, Preview to review the PDF before printing, or Print directly to send it to the selected printer.',
      'A sales invoice can auto-print while customer receipts and purchase documents remain manual. Each document type has its own setting.',
      'Choose a printer for direct printing or leave System default. Use Refresh printers after adding or changing a printer in Windows/macOS.',
      'Paper size for sales and purchase documents can be configured independently. Thermal 58mm, Thermal 80mm and A4 are supported by the current templates.',
      'If automatic output is disabled, the sale-completion dialog still offers Preview and Print Directly, and historical documents can be printed later.',
    ]),
    _HelpTopic('Backups & restore', Icons.backup_outlined, [
      'Open Settings → Data & Security.',
      'Use Backup now before major imports, upgrades or risky changes.',
      'Keep copies on a separate drive or backup location.',
      'Use Restore backup only when you intend to replace the current live database.',
    ]),
    _HelpTopic('Application updates - online or offline', Icons.system_update_alt_outlined, [
      'Open Settings → System & Updates, or choose Help → Check for Updates.',
      'For an offline business, copy the .reliq update package to the computer using USB, a local network folder or any other transfer method and choose Install update package.',
      'RELIQ validates the package and creates a pre-update database backup before it can restart and install.',
      'The program files are replaced separately from the customer database. On first launch, any required database schema migration runs automatically.',
      'If the new version cannot open/migrate the database, RELIQ restores the pre-update database and rolls the application files back to the previous version.',
      'Online checks are optional. If enabled, an internet failure is ignored and normal offline operation continues.',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 12, 12),
            child: Row(children: [
              const Icon(Icons.help_outline, color: V3Style.blue),
              const SizedBox(width: 10),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('RELIQ Help Center', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                Text('Quick operating guides for everyday sales, purchasing, stock and accounting workflows.', style: TextStyle(color: V3Style.muted)),
              ])),
              TextButton.icon(
                onPressed: () => ReliqHelp.showKeyboardShortcuts(context),
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('Keyboard Shortcuts'),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(18),
              itemCount: topics.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _TopicCard(topic: topics[i]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _HelpTopic {
  final String title;
  final IconData icon;
  final List<String> steps;
  const _HelpTopic(this.title, this.icon, this.steps);
}

class _TopicCard extends StatelessWidget {
  final _HelpTopic topic;
  const _TopicCard({required this.topic});

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ExpansionTile(
      leading: Icon(topic.icon, color: V3Style.blue),
      title: Text(topic.title, style: const TextStyle(fontWeight: FontWeight.w800)),
      childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
      children: [
        for (var i = 0; i < topic.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22, height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: V3Style.blue.withValues(alpha: .10), borderRadius: BorderRadius.circular(99)),
                child: Text('${i + 1}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: V3Style.blue)),
              ),
              const SizedBox(width: 9),
              Expanded(child: Text(topic.steps[i])),
            ]),
          ),
      ],
    ),
  );
}

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog();

  static const groups = <(String, List<(String, String)>)>[
    ('Global', [
      ('Ctrl/Cmd + K', 'Command Palette'),
      ('Ctrl/Cmd + F', 'Universal RELIQ Lookup: products, customers and suppliers'),
      ('Ctrl/Cmd + N', 'New sale, purchase, product, customer or supplier (contextual)'),
      ('Ctrl/Cmd + S', 'Complete/save Sales and Purchases'),
      ('Ctrl/Cmd + R', 'Refresh current screen'),
      ('Ctrl/Cmd + ,', 'Settings'),
      ('Esc', 'Close / cancel / go back'),
      ('Shift + ?', 'Keyboard Shortcuts'),
    ]),
    ('Navigation', [
      ('Alt + 1', 'Morning Brief'),
      ('Alt + 2', 'Sales / POS'),
      ('Alt + 3', 'Receive Purchase'),
      ('Alt + 4', 'Products & Barcodes'),
      ('Alt + 5', 'Customer Ledgers'),
      ('Alt + 6', 'Supplier Ledgers'),
      ('Alt + 7', 'Payment Activity'),
      ('Alt + 8', 'Reports'),
      ('Alt + 9', 'Business Action Center'),
    ]),
    ('POS / Sales — active', [
      ('F2', 'Product / barcode search'),
      ('F4', 'Focus customer selection'),
      ('F5', 'Refresh POS view'),
      ('F6', 'Focus bill discount'),
      ('F7', 'Focus delivery / charges'),
      ('F8', 'Hold / park current sale'),
      ('F9', 'Focus payment amount'),
      ('F10', 'Complete sale'),
      ('Ctrl/Cmd + N', 'Start a new sale (confirms before clearing)'),
      ('Ctrl/Cmd + S', 'Complete sale'),
    ]),
    ('Purchases — active', [
      ('F2', 'Focus supplier selection'),
      ('F3', 'Product lookup'),
      ('F7', 'Focus freight / delivery'),
      ('F9', 'Focus payment amount'),
      ('F10', 'Receive / save purchase'),
      ('Ctrl/Cmd + N', 'Start a new purchase (confirms before clearing)'),
      ('Ctrl/Cmd + S', 'Receive / save purchase'),
    ]),
    ('Products / Stock — active', [
      ('F2', 'Product lookup / search'),
      ('F4', 'Open stock adjustment (Stock Adjustment screen)'),
      ('F5', 'Refresh products / stock adjustment history'),
      ('Ctrl/Cmd + N', 'New product (Products screen)'),
      ('Ctrl/Cmd + F', 'Open universal RELIQ Lookup'),
    ]),
    ('Customers / Suppliers — active', [
      ('Ctrl/Cmd + F', 'Open universal RELIQ Lookup'),
      ('Ctrl/Cmd + N', 'Add a customer or supplier'),
    ]),
  ];

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 12, 12),
          child: Row(children: [
            const Icon(Icons.keyboard_alt_outlined, color: V3Style.blue),
            const SizedBox(width: 10),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Keyboard Shortcuts', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              Text('Ctrl on Windows · Cmd on macOS. Shortcut helper labels can be hidden from Settings without disabling the shortcuts.', style: TextStyle(color: V3Style.muted)),
            ])),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(padding: const EdgeInsets.all(18), children: [
          for (final group in groups) ...[
            Text(group.$1, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (var i = 0; i < group.$2.length; i++) ...[
                  ListTile(
                    dense: true,
                    title: Text(group.$2[i].$2),
                    trailing: _KeyBadge(group.$2[i].$1),
                  ),
                  if (i != group.$2.length - 1) const Divider(height: 1),
                ],
              ]),
            ),
            const SizedBox(height: 16),
          ],
        ])),
      ]),
    ),
  );
}

class _KeyBadge extends StatelessWidget {
  final String text;
  const _KeyBadge(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800)),
  );
}
