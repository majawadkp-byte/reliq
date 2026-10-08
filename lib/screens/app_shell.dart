import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/brand.dart';
import '../data/app_database.dart';
import '../services/license_manager.dart';
import '../services/auth_service.dart';
import '../services/update_manager.dart';
import '../ui/v3_style.dart';
import '../ui/reliq_surface.dart';
import 'dashboard_screen.dart';
import 'action_center_screen.dart';
import 'about_screen.dart';
import 'audit_trail_screen.dart';
import 'day_book_screen.dart';
import 'expenses_screen.dart';
import 'intelligence_screen.dart';
import 'license_screen.dart';
import 'migration_center_screen.dart';
import 'locked_feature_screen.dart';
import 'payments_ledgers_screen.dart';
import 'products_screen.dart';
import 'purchase_history_screen.dart';
import 'purchase_orders_screen.dart';
import 'quotations_screen.dart';
import 'purchases_screen.dart';
import 'reports_screen.dart';
import 'returns_screen.dart';
import 'sales_history_screen.dart';
import 'sales_pos_screen.dart';
import 'settings_screen.dart';
import 'help_center.dart';
import 'smart_buying_screen.dart';
import 'stock_adjustment_screen.dart';
import 'stock_counts_screen.dart';
import 'stock_movements_screen.dart';
import 'sync_center_screen.dart';
import 'team_locations_screen.dart';

class AppShell extends StatefulWidget {
  final bool darkMode;
  final VoidCallback onToggleTheme;
  final AuthUser currentUser;
  final VoidCallback onLogout;

  const AppShell({
    super.key,
    required this.darkMode,
    required this.onToggleTheme,
    required this.currentUser,
    required this.onLogout,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _NavItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final String? entitlement;
  final String permission;

  const _NavItem(this.title, this.subtitle, this.icon, this.permission, {this.entitlement});
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  bool collapsed = false;
  bool touchMode = false;
  bool touchInitialized = false;
  bool shortcutHelpersEnabled = true;
  int pageRevision = 0;
  int reportsRevision = 0;
  final Set<int> _retainedVisited = <int>{};
  final Map<int,int> _retainedRevisions = <int,int>{};
  static const Set<int> _retainedPageIndexes = <int>{2, 6, 9, 11, 15, 23};
  int paymentTab = 0;
  String paymentPartyId = '';
  String paymentPartyName = '';
  int paymentLookupRevision = 0;
  int settingsInitialSection = 0;
  final GlobalKey<PaymentsLedgersScreenState> _paymentsLedgersKey = GlobalKey<PaymentsLedgersScreenState>();
  bool _autoUpdateChecked = false;
  LicenseState? license;
  Map<String, String> settings = const {};
  final Map<String, bool> _navGroups = <String, bool>{
    'sales': true,
    'inventory': false,
    'purchasing': false,
    'finance': false,
    'admin': false,
  };

  final items = const <_NavItem>[
    _NavItem('Morning Brief', 'Know what needs attention today. • LOCAL / OFFLINE', Icons.speed_outlined, 'dashboard'),
    _NavItem('Sales / POS', 'Fast barcode-ready checkout.', Icons.shopping_cart_outlined, 'sales'),
    _NavItem('Products & Barcodes', 'Manage products, barcodes and selling status.', Icons.inventory_2_outlined, 'products'),
    _NavItem('Stock Adjustment', 'Correct stock with a complete audit trail.', Icons.tune_outlined, 'stock_adjust'),
    _NavItem('Stock Transfers', 'Move stock between branches and review transfer history.', Icons.swap_horiz_outlined, 'stock_transfer'),
    _NavItem('Receive Purchase', 'Receive stock and supplier invoices.', Icons.download_outlined, 'purchases'),
    _NavItem('Purchase History', 'Review received purchases and supplier documents.', Icons.calendar_month_outlined, 'purchase_history'),
    _NavItem('Smart Buying', 'Demand-aware purchasing recommendations.', Icons.monetization_on_outlined, 'smart_buying', entitlement: LicenseEntitlements.smartBuying),
    _NavItem('Inventory Intelligence', 'Stock coverage, velocity and movement risk.', Icons.auto_graph_outlined, 'inventory_intelligence', entitlement: LicenseEntitlements.inventoryIntelligence),
    _NavItem('Sales History', 'Invoices, payments and balances.', Icons.receipt_long_outlined, 'sales_history'),
    _NavItem('Quotations', 'Create, WhatsApp, follow up and convert quotes to sales.', Icons.request_quote_outlined, 'sales'),
    _NavItem('Payments & Ledgers', 'Customer receipts, supplier payments and account ledgers.', Icons.credit_card_outlined, 'payments'),
    _NavItem('Sales & Purchase Returns', 'Customer returns, supplier returns and stock restoration.', Icons.keyboard_return_outlined, 'returns'),
    _NavItem('Expenses', 'Record and review operating expenses.', Icons.attach_money_outlined, 'expenses'),
    _NavItem('Day Book', 'Daily sales, purchases, receipts, payments and expenses.', Icons.menu_book_outlined, 'day_book'),
    _NavItem('Reports', 'Sales, purchases, inventory and account reporting.', Icons.query_stats_outlined, 'reports'),
    _NavItem('Users & Roles', 'Users, roles, branches and terminal identity.', Icons.people_outline, 'users'),
    _NavItem('Settings', 'Company branding, backups and business defaults.', Icons.settings_outlined, 'settings'),
    _NavItem('License', 'Activation, plan, expiry and entitlements.', Icons.verified_user_outlined, 'license'),
    _NavItem('Purchase Orders', 'Plan supplier orders, incoming stock and partial receipts.', Icons.assignment_outlined, 'purchases'),
    _NavItem('Physical Stock Counts', 'Cycle counts, variance review and audited posting.', Icons.fact_check_outlined, 'stock_adjust'),
    _NavItem('Business Action Center', 'Prioritized decisions across stock, sales, margin, customers and branches.', Icons.bolt_outlined, 'dashboard', entitlement: LicenseEntitlements.inventoryIntelligence),
    _NavItem('Sync Center', 'Multi-device business sync, queue health, incoming application and conflict diagnostics.', Icons.cloud_sync_outlined, 'settings'),
    _NavItem('Migration Center', 'Import masters, history, payments and balances from CSV exports.', Icons.move_up_outlined, 'migration'),
    _NavItem('Audit Trail', 'Who changed what, when and from which branch or terminal.', Icons.manage_search_outlined, 'audit_trail'),
    _NavItem('About RELIQ', 'Version, product purpose, support and contact details.', Icons.info_outline, 'about'),
  ];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareShortcut);
    _loadShell();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareShortcut);
    super.dispose();
  }

  Future<void> _loadShell() async {
    final result = await Future.wait([
      LicenseManager.instance.current(),
      AppDatabase.instance.settings(),
    ]);
    if (!mounted) return;
    setState(() {
      license = result[0] as LicenseState;
      settings = result[1] as Map<String, String>;
      if (!touchInitialized) {
        touchMode = settings['touch_mode_default'] == '1';
        touchInitialized = true;
      }
      shortcutHelpersEnabled = settings['shortcut_helpers_enabled'] != '0';
    });
    if (!_autoUpdateChecked && settings['auto_check_updates'] == '1' && (settings['update_manifest_url'] ?? '').trim().isNotEmpty) {
      _autoUpdateChecked = true;
      Future<void>.delayed(const Duration(milliseconds: 700), _maybeAutoCheckUpdates);
    }
  }

  Future<void> _maybeAutoCheckUpdates() async {
    try {
      final info = await UpdateManager.instance.checkOnline(
        settings['update_manifest_url'] ?? '',
        channel: (settings['update_channel'] ?? 'Stable').toLowerCase(),
      );
      if (!mounted || info == null) return;
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('RELIQ ${info.version} is available'),
          content: Text(info.releaseNotes.trim().isEmpty ? 'A newer RELIQ version is available.' : info.releaseNotes),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open Updates')),
          ],
        ),
      ) ?? false;
      if (open && mounted) _openSettingsSection(10);
    } catch (_) {
      // Offline operation is normal. Silent auto-check failures never interrupt RELIQ.
    }
  }

  bool _entitled(String? value) =>
      value == null ||
      LicenseManager.instance.developmentBypass ||
      license?.has(value) == true;


  bool _canAccess(int itemIndex) {
    if (itemIndex == 25) return true;
    final item = items[itemIndex];
    if (widget.currentUser.isOwner) return true;
    if (item.permission == 'license') return false;
    return widget.currentUser.can(item.permission);
  }

  String _dedupeUserLabel(String value) {
    final cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return '';
    final parts = cleaned
        .split(RegExp(r'\s*[·•|]\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length > 1 && parts.every((part) => part.toLowerCase() == parts.first.toLowerCase())) {
      return parts.first;
    }
    return cleaned;
  }

  String get _currentUserLabel {
    final name = _dedupeUserLabel(widget.currentUser.displayName);
    final role = _dedupeUserLabel(widget.currentUser.role);
    if (widget.currentUser.isOwner) {
      if (name.isEmpty || name.toLowerCase() == 'owner') return 'Owner';
      return name;
    }
    if (name.isEmpty) return role;
    if (role.isEmpty || name.toLowerCase() == role.toLowerCase()) return name;
    return '$name · $role';
  }

  ThemeData _touchTheme(ThemeData base) {
    return base.copyWith(
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: base.textTheme.apply(fontSizeFactor: 1.06),
      iconTheme: base.iconTheme.copyWith(size: 23),
      listTileTheme: base.listTileTheme.copyWith(
        minTileHeight: 60,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
        iconColor: base.colorScheme.primary,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: base.outlinedButtonTheme.style?.copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48), iconSize: 23),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 50)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14.5)),
        ),
      ),
      dataTableTheme: base.dataTableTheme.copyWith(
        headingRowHeight: 58,
        dataRowMinHeight: 58,
        dataRowMaxHeight: 72,
      ),
    );
  }

  Widget _page({int? overrideIndex}) {
    final pageIndex = overrideIndex ?? index;
    final item = items[pageIndex];
    if (!_canAccess(pageIndex)) {
      return Center(child: Card(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline, size: 38),
        const SizedBox(height: 12),
        Text('Access restricted', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('${widget.currentUser.role} does not have access to ${item.title}.', textAlign: TextAlign.center),
      ]))));
    }
    if (!_entitled(item.entitlement)) {
      return LockedFeatureScreen(title: item.title, entitlement: item.entitlement!);
    }
    switch (pageIndex) {
      case 0:
        return DashboardScreen(onNavigate: _select, onInventory: _openInventory);
      case 1:
        return SalesPosScreen(
          touchMode: touchMode,
          defaultTileView: (settings['pos_default_view'] ?? 'Tiles') != 'Normal',
          defaultPaymentMethod: settings['default_payment_method'] ?? 'Cash',
          showShortcutHelpers: shortcutHelpersEnabled,
        );
      case 2:
        return ProductsScreen(showShortcutHelpers: shortcutHelpersEnabled);
      case 3:
        return StockAdjustmentScreen(showShortcutHelpers: shortcutHelpersEnabled);
      case 4:
        return const StockMovementsScreen();
      case 5:
        return PurchasesScreen(showShortcutHelpers: shortcutHelpersEnabled);
      case 6:
        return const PurchaseHistoryScreen();
      case 7:
        return const SmartBuyingScreen();
      case 8:
        return IntelligenceScreen(key: ValueKey('intelligence-$inventoryFilter'), initialFilter: inventoryFilter);
      case 9:
        return const SalesHistoryScreen();
      case 10:
        return QuotationsScreen(onNavigate: _select);
      case 11:
        return PaymentsLedgersScreen(
          key: _paymentsLedgersKey,
          initialTab: paymentTab,
          initialPartyId: paymentPartyId,
          initialPartyName: paymentPartyName,
          lookupRevision: paymentLookupRevision,
          showShortcutHelpers: shortcutHelpersEnabled,
        );
      case 12:
        return const ReturnsScreen();
      case 13:
        return const ExpensesScreen();
      case 14:
        return const DayBookScreen();
      case 15:
        return const ReportsScreen();
      case 16:
        return const TeamLocationsScreen();
      case 17:
        return SettingsScreen(key: ValueKey('settings-$settingsInitialSection'), onNavigate:_select, onSettingsChanged: _loadShell, initialSection: settingsInitialSection);
      case 18:
        return const LicenseScreen();
      case 19:
        return const PurchaseOrdersScreen();
      case 20:
        return const StockCountsScreen();
      case 21:
        return ActionCenterScreen(onNavigate: _select, onInventory: _openInventory);
      case 22:
        return const SyncCenterScreen();
      case 23:
        return const MigrationCenterScreen();
      case 24:
        return const AuditTrailScreen();
      case 25:
        return AboutScreen(
          onOpenHelp: () => ReliqHelp.showHelpCenter(context),
          onOpenShortcuts: () => ReliqHelp.showKeyboardShortcuts(context),
          onOpenLicense: () => _select(18),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  String inventoryFilter = 'All';
  void _openInventory(String filter) {
    setState(() {
      inventoryFilter = filter;
      index = 8;
      _navGroups['inventory'] = true;
    });
  }

  void _select(int value) {
    if (value == 8) inventoryFilter = 'All';
    if (_retainedPageIndexes.contains(value)) _retainedVisited.add(value);
    // Sales History must always reflect invoices created since the last visit.
    // Rebuild it on navigation instead of keeping a stale retained Future alive.
    if (value == 9) _retainedRevisions[9] = (_retainedRevisions[9] ?? 0) + 1;
    if (value == 17 && index != 17) settingsInitialSection = 0;
    final group = _navGroupForIndex(value);
    setState(() {
      index = value;
      if (group != null) _navGroups[group] = true;
    });
    if (value == 17 || value == 18 || value == 23 || value == 24) _loadShell();
  }


  void _openSettingsSection(int section) {
    setState(() { settingsInitialSection = section; index = 17; });
    _loadShell();
  }

  void _openPayments(int tab) {
    setState(() {
      paymentTab = tab;
      paymentPartyId = '';
      paymentPartyName = '';
      paymentLookupRevision++;
      _retainedVisited.add(11);
      index = 11;
      _navGroups['finance'] = true;
    });
  }

  void _openPartyLedger(String kind, Map<String, Object?> row) {
    final isCustomer = kind == 'customer';
    setState(() {
      paymentTab = isCustomer ? 0 : 1;
      paymentPartyId = (row['id'] ?? '').toString();
      paymentPartyName = (row['name'] ?? '').toString();
      paymentLookupRevision++;
      _retainedVisited.add(11);
      index = 11;
      _navGroups['finance'] = true;
    });
  }

  bool get _isMac => Platform.isMacOS;

  void _contextualFind() => _universalLookup();

  SingleActivator _cmd(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, control: !_isMac, meta: _isMac, shift: shift);

  bool _handleHardwareShortcut(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final alt = keyboard.isAltPressed;
    final findPressed = (_isMac ? keyboard.isMetaPressed : keyboard.isControlPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyF;
    if (findPressed) {
      _universalLookup();
      return true;
    }
    if (!alt) return false;

    // Physical number-row keys are intentional here. On macOS Option+1/2/etc
    // can produce alternate characters, while the physical key still reliably
    // identifies the shortcut the user pressed. Numpad digits are supported too.
    final physical = event.physicalKey;
    if (physical == PhysicalKeyboardKey.digit1 || event.logicalKey == LogicalKeyboardKey.numpad1) { _select(0); return true; }
    if (physical == PhysicalKeyboardKey.digit2 || event.logicalKey == LogicalKeyboardKey.numpad2) { _select(1); return true; }
    if (physical == PhysicalKeyboardKey.digit3 || event.logicalKey == LogicalKeyboardKey.numpad3) { _select(5); return true; }
    if (physical == PhysicalKeyboardKey.digit4 || event.logicalKey == LogicalKeyboardKey.numpad4) { _select(2); return true; }
    if (physical == PhysicalKeyboardKey.digit5 || event.logicalKey == LogicalKeyboardKey.numpad5) { _openPayments(0); return true; }
    if (physical == PhysicalKeyboardKey.digit6 || event.logicalKey == LogicalKeyboardKey.numpad6) { _openPayments(1); return true; }
    if (physical == PhysicalKeyboardKey.digit7 || event.logicalKey == LogicalKeyboardKey.numpad7) { _openPayments(4); return true; }
    if (physical == PhysicalKeyboardKey.digit8 || event.logicalKey == LogicalKeyboardKey.numpad8) { _select(15); return true; }
    if (physical == PhysicalKeyboardKey.digit9 || event.logicalKey == LogicalKeyboardKey.numpad9) { _select(21); return true; }
    return false;
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
    _cmd(LogicalKeyboardKey.keyK): _showCommandPalette,
    _cmd(LogicalKeyboardKey.keyR): () => setState(() { if (index == 15) { reportsRevision++; } else if (_retainedPageIndexes.contains(index)) { _retainedRevisions[index]=(_retainedRevisions[index]??0)+1; } else { pageRevision++; } }),
    _cmd(LogicalKeyboardKey.comma): () => _select(17),
    const SingleActivator(LogicalKeyboardKey.slash, shift: true): () => ReliqHelp.showKeyboardShortcuts(context),
  };

  String? _navShortcut(int itemIndex) => switch (itemIndex) {
    0 => 'Alt+1',
    1 => 'Alt+2',
    5 => 'Alt+3',
    2 => 'Alt+4',
    11 => 'Alt+7',
    15 => 'Alt+8',
    21 => 'Alt+9',
    _ => null,
  };

  Future<void> _showCommandPalette() async {
    final commands = <(String, String, IconData, VoidCallback)>[
      ('Morning Brief', 'Alt+1', Icons.speed_outlined, () => _select(0)),
      ('Sales / POS', 'Alt+2', Icons.shopping_cart_outlined, () => _select(1)),
      ('Receive Purchase', 'Alt+3', Icons.download_outlined, () => _select(5)),
      ('Products & Barcodes', 'Alt+4', Icons.inventory_2_outlined, () => _select(2)),
      ('Customers', 'Alt+5', Icons.people_outline, () => _openPayments(0)),
      ('Suppliers', 'Alt+6', Icons.local_shipping_outlined, () => _openPayments(1)),
      ('Payment Activity', 'Alt+7', Icons.credit_card_outlined, () => _openPayments(4)),
      ('Reports', 'Alt+8', Icons.query_stats_outlined, () => _select(15)),
      ('Business Action Center', 'Alt+9', Icons.bolt_outlined, () => _select(21)),
      ('Inventory Intelligence', '', Icons.auto_graph_outlined, () => _select(8)),
      ('Settings', _isMac ? 'Cmd+,' : 'Ctrl+,', Icons.settings_outlined, () => _openSettingsSection(0)),
      ('Check for Updates', '', Icons.system_update_alt_outlined, () => _openSettingsSection(10)),
      ('Migration Center', '', Icons.move_up_outlined, () => _select(23)),
      ('Audit Trail', '', Icons.manage_search_outlined, () => _select(24)),
      ('Universal Lookup', _isMac ? 'Cmd+F' : 'Ctrl+F', Icons.search, _universalLookup),
      ('Help Center', '', Icons.help_outline, () => ReliqHelp.showHelpCenter(context)),
      ('Keyboard Shortcuts', 'Shift+?', Icons.keyboard_alt_outlined, () => ReliqHelp.showKeyboardShortcuts(context)),
      ('About RELIQ', '', Icons.info_outline, () => _select(25)),
    ];
    String query = '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) {
          final q = query.trim().toLowerCase();
          final visible = q.isEmpty ? commands : commands.where((c) => c.$1.toLowerCase().contains(q)).toList();
          return AlertDialog(
            title: const Text('Command Palette'),
            content: SizedBox(
              width: 620,
              height: 520,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  onChanged: (v) => setDialog(() => query = v),
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Type a page or action...'),
                ),
                const SizedBox(height: 10),
                Expanded(child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (_, i) {
                    final c = visible[i];
                    return ListTile(
                      leading: Icon(c.$3),
                      title: Text(c.$1),
                      trailing: c.$2.isEmpty ? null : _ShortcutBadge(c.$2),
                      onTap: () { Navigator.pop(dialogContext); c.$4(); },
                    );
                  },
                )),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
          );
        },
      ),
    );
  }

  Future<void> _universalLookup() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _UniversalLookupDialog(
        onOpenCustomer: (row) {
          Navigator.pop(dialogContext);
          _openPartyLedger('customer', row);
        },
        onOpenSupplier: (row) {
          Navigator.pop(dialogContext);
          _openPartyLedger('supplier', row);
        },
      ),
    );
  }

  Widget _brandLogo() {
    final path = settings['logo_path'] ?? '';
    if (path.isNotEmpty && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(File(path), width: 42, height: 42, fit: BoxFit.cover),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Image.asset(Brand.iconAsset, width: 42, height: 42, fit: BoxFit.cover),
    );
  }

  Widget _sidebar({required bool mobile, VoidCallback? closeDrawer}) {
    final width = collapsed && !mobile ? (touchMode ? 86.0 : 76.0) : (touchMode ? 292.0 : 264.0);
    final company = (settings['business_name'] ?? '').trim().isEmpty ? Brand.name : settings['business_name']!.trim();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 190),
      width: mobile ? (touchMode ? 304 : 280) : width,
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xF20B2024), Color(0xED10292C)]),
        border: Border(right: BorderSide(color: V3Style.lime.withValues(alpha: .12))),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 28, offset: Offset(10, 0))],
      ),
      child: SafeArea(
        right: false,
        child: Column(children: [
          SizedBox(
            height: touchMode ? 100 : 88,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed && !mobile ? 17 : 18),
              child: Row(children: [
                _brandLogo(),
                if (!collapsed || mobile) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(company, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        const Text('${Brand.name} · ${Brand.versionLabel}', style: TextStyle(color: V3Style.sidebarMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                  if (!mobile)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => collapsed = true),
                      icon: const Icon(Icons.chevron_left, size: 18),
                      color: const Color(0xFFD7E4EF),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0x12FFFFFF),
                        side: const BorderSide(color: Color(0x20FFFFFF)),
                      ),
                    ),
                ],
              ]),
            ),
          ),
          if (collapsed && !mobile)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: IconButton(
                tooltip: 'Expand sidebar',
                onPressed: () => setState(() => collapsed = false),
                icon: const Icon(Icons.chevron_right),
                color: const Color(0xFFD7E4EF),
              ),
            ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(collapsed && !mobile ? 9 : 12, 7, collapsed && !mobile ? 9 : 12, 12),
              children: [
                // Overview stays immediately accessible. The remaining workspaces
                // are grouped by the business workflow users naturally follow.
                _navTile(0, mobile: mobile, closeDrawer: closeDrawer),
                _navTile(21, mobile: mobile, closeDrawer: closeDrawer),
                const SizedBox(height: 5),
                ..._navGroup('sales', 'SALES', [1, 9, 10, 12], mobile: mobile, closeDrawer: closeDrawer),
                ..._navGroup('inventory', 'INVENTORY', [2, 8, 3, 20, 4], mobile: mobile, closeDrawer: closeDrawer),
                ..._navGroup('purchasing', 'PURCHASING', [5, 19, 6, 7], mobile: mobile, closeDrawer: closeDrawer),
                ..._navGroup('finance', 'FINANCE & REPORTS', [11, 13, 14, 15], mobile: mobile, closeDrawer: closeDrawer),
                ..._navGroup('admin', 'ADMINISTRATION', [16, 17, 18, 22, 23, 24], mobile: mobile, closeDrawer: closeDrawer),
                const SizedBox(height: 5),
                _navTile(25, mobile: mobile, closeDrawer: closeDrawer),
              ],
            ),
          ),
          if (!collapsed || mobile)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 10, 12, 12),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_currentUserLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFD7E4EF), fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('@${widget.currentUser.username} · local session', style: const TextStyle(color: V3Style.sidebarMuted, fontSize: 10)),
                ])),
                IconButton(
                  tooltip: 'Logout',
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout, size: 18),
                  color: const Color(0xFFD7E4EF),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  List<Widget> _navGroup(
    String key,
    String label,
    List<int> itemIndexes, {
    required bool mobile,
    VoidCallback? closeDrawer,
  }) {
    final visible = itemIndexes.where(_canAccess).toList();
    if (visible.isEmpty) return const <Widget>[];
    if (collapsed && !mobile) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 5),
          child: Divider(height: 1, color: Color(0x18FFFFFF)),
        ),
        ...visible.map((i) => _navTile(i, mobile: mobile, closeDrawer: closeDrawer)),
      ];
    }
    final expanded = _navGroups[key] ?? false;
    final active = visible.contains(index);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 7, bottom: 2),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: () => setState(() => _navGroups[key] = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              child: Row(children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: active ? const Color(0xFFD7E4EF) : const Color(0xFF7895AC),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .9,
                    ),
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 17,
                  color: active ? const Color(0xFFD7E4EF) : const Color(0xFF7895AC),
                ),
              ]),
            ),
          ),
        ),
      ),
      if (expanded) ...visible.map((i) => _navTile(i, mobile: mobile, closeDrawer: closeDrawer)),
    ];
  }

  String? _navGroupForIndex(int itemIndex) => switch (itemIndex) {
    1 || 9 || 10 || 12 => 'sales',
    2 || 3 || 4 || 8 || 20 => 'inventory',
    5 || 6 || 7 || 19 => 'purchasing',
    11 || 13 || 14 || 15 => 'finance',
    16 || 17 || 18 || 22 || 23 || 24 => 'admin',
    _ => null,
  };


  Widget _navTile(int itemIndex, {required bool mobile, VoidCallback? closeDrawer}) {
    if (!_canAccess(itemIndex)) return const SizedBox.shrink();
    final item = items[itemIndex];
    final selected = itemIndex == index;
    final locked = !_entitled(item.entitlement);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: collapsed && !mobile ? item.title : '',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              _select(itemIndex);
              closeDrawer?.call();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: touchMode ? 56 : 43,
              padding: EdgeInsets.symmetric(horizontal: collapsed && !mobile ? 0 : 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: selected ? V3Style.lime : null,
                border: selected ? const Border(left: BorderSide(color: Colors.white, width: 3)) : null,
              ),
              child: Row(
                mainAxisAlignment: collapsed && !mobile ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  Stack(clipBehavior: Clip.none, children: [
                    Icon(item.icon, size: touchMode ? 24 : 19, color: selected ? V3Style.brandDark : V3Style.sidebarText),
                    if (locked)
                      const Positioned(right: -5, top: -5, child: Icon(Icons.lock, size: 9, color: V3Style.goldLight)),
                  ]),
                  if (!collapsed || mobile) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? V3Style.brandDark : V3Style.sidebarText,
                          fontSize: touchMode ? 14.5 : 13,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (shortcutHelpersEnabled && _navShortcut(itemIndex) != null) ...[
                      const SizedBox(width: 6),
                      _SidebarShortcutBadge(_navShortcut(itemIndex)!, selected: selected),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topbar({VoidCallback? openDrawer}) {
    final item = items[index];
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: touchMode ? 84 : 72,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: ReliqSurface.glassStrong(context).withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .88 : .82),
            border: Border(bottom: BorderSide(color: ReliqSurface.glassBorder(context))),
            boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 18, offset: Offset(0, 5))],
          ),
          child: Row(children: [
        if (openDrawer != null) ...[
          IconButton(onPressed: openDrawer, icon: const Icon(Icons.menu)),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
              const SizedBox(height: 2),
              Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Help',
          onSelected: (value) {
            if (value == 'shortcuts') { ReliqHelp.showKeyboardShortcuts(context); }
            if (value == 'help') { ReliqHelp.showHelpCenter(context); }
            if (value == 'updates') { _openSettingsSection(10); }
            if (value == 'about') { _select(25); }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'help', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.help_outline), title: Text('Help Center'))),
            PopupMenuItem(value: 'shortcuts', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.keyboard_alt_outlined), title: Text('Keyboard Shortcuts'), subtitle: Text('Shift + ?'))),
            PopupMenuItem(value: 'updates', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.system_update_alt_outlined), title: Text('Check for Updates'))),
            PopupMenuDivider(),
            PopupMenuItem(value: 'about', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.info_outline), title: Text('About RELIQ'))),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.help_outline, size: 18),
              if (MediaQuery.sizeOf(context).width >= 1180) ...[const SizedBox(width: 6), const Text('Help', style: TextStyle(fontWeight: FontWeight.w700))],
              const Icon(Icons.arrow_drop_down, size: 18),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        _topAction(Icons.search, 'Lookup', _contextualFind, accent: V3Style.info),
        const SizedBox(width: 8),
        _topAction(Icons.pan_tool_alt_outlined, 'Touch', () {
          setState(() => touchMode = !touchMode);
          AppDatabase.instance.saveSettings({'touch_mode_default': touchMode ? '1' : '0'});
        }, active: touchMode, accent: V3Style.teal),
        const SizedBox(width: 8),
        _topAction(widget.darkMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined, widget.darkMode ? 'Light' : 'Dark', widget.onToggleTheme, accent: V3Style.purple),
        if (MediaQuery.sizeOf(context).width >= 1120) ...[
          const SizedBox(width: 12),
          Text(_currentUserLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout, size: 18),
            style: IconButton.styleFrom(foregroundColor: V3Style.danger, backgroundColor: V3Style.danger.withValues(alpha: .08)),
          ),
        ],
          ]),
        ),
      ),
    );
  }

  Widget _topAction(IconData icon, String label, VoidCallback onTap, {bool active = false, Color? accent}) {
    final showLabel = MediaQuery.sizeOf(context).width >= 1020;
    final tone = accent ?? V3Style.blue;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: Size(showLabel ? (touchMode ? 104 : 86) : (touchMode ? 50 : 40), touchMode ? 50 : 38),
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 9, vertical: 8),
        backgroundColor: active ? V3Style.softFor(tone, dark: dark) : null,
        foregroundColor: active ? tone : Theme.of(context).colorScheme.onSurface,
        side: BorderSide(color: active ? tone.withValues(alpha: .36) : Theme.of(context).dividerColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: touchMode ? 22 : 17, color: active ? tone : null),
        if (showLabel) ...[const SizedBox(width: 7), Text(label)],
      ]),
    );
  }

  Widget _pageHost() {
    // Heavy data workspaces stay mounted after their first visit. Moving to POS
    // or another section therefore does not throw away filters, futures and
    // already-rendered lists only to rebuild them when the user comes back.
    if (_retainedVisited.isEmpty) {
      return KeyedSubtree(key: ValueKey('page-$index-$pageRevision'), child: _page());
    }
    return Stack(children: [
      for (final retainedIndex in _retainedVisited)
        Positioned.fill(child: Offstage(
          offstage: index != retainedIndex,
          child: TickerMode(
            enabled: index == retainedIndex,
            child: KeyedSubtree(
              key: ValueKey('retained-$retainedIndex-${retainedIndex == 15 ? reportsRevision : (_retainedRevisions[retainedIndex] ?? 0)}'),
              child: _page(overrideIndex: retainedIndex),
            ),
          ),
        )),
      if (!_retainedPageIndexes.contains(index))
        Positioned.fill(child: KeyedSubtree(key: ValueKey('page-$index-$pageRevision'), child: _page())),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final themed = touchMode ? _touchTheme(baseTheme) : baseTheme;
    return CallbackShortcuts(
      bindings: _shortcutBindings(),
      child: Focus(
        autofocus: true,
        child: Theme(
      data: themed,
      child: Builder(builder: (innerContext) {
        final mobile = MediaQuery.sizeOf(innerContext).width < 900;
        if (mobile) {
          return ReliqWorkspaceBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              drawerScrimColor: Colors.black54,
              drawer: Drawer(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                width: touchMode ? 304 : 280,
                child: _sidebar(mobile: true, closeDrawer: () => Navigator.of(innerContext).pop()),
              ),
              body: Builder(
                builder: (scaffoldContext) => Column(children: [
                  _topbar(openDrawer: () => Scaffold.of(scaffoldContext).openDrawer()),
                  Expanded(child: _pageHost()),
                ]),
              ),
            ),
          );
        }
        return ReliqWorkspaceBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(children: [
              _sidebar(mobile: false),
              Expanded(child: Column(children: [
                _topbar(),
                Expanded(child: _pageHost()),
              ])),
            ]),
          ),
        );
      }),
        ),
      ),
    );
  }

}

class _ShortcutBadge extends StatelessWidget {
  final String text;
  const _ShortcutBadge(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
  );
}

class _SidebarShortcutBadge extends StatelessWidget {
  final String text;
  final bool selected;
  const _SidebarShortcutBadge(this.text, {required this.selected});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: selected ? const Color(0x181C2D30) : const Color(0x12FFFFFF),
      border: Border.all(color: selected ? const Color(0x401C2D30) : const Color(0x22FFFFFF)),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(text, style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: selected ? V3Style.brandDark : V3Style.sidebarMuted)),
  );
}

class _LookupHit {
  final String kind;
  final Map<String, Object?> row;
  const _LookupHit(this.kind, this.row);

  String get name => (row['name'] ?? row['sku'] ?? row['id'] ?? 'Unknown').toString();
}

class _UniversalLookupDialog extends StatefulWidget {
  final ValueChanged<Map<String, Object?>> onOpenCustomer;
  final ValueChanged<Map<String, Object?>> onOpenSupplier;

  const _UniversalLookupDialog({required this.onOpenCustomer, required this.onOpenSupplier});

  @override
  State<_UniversalLookupDialog> createState() => _UniversalLookupDialogState();
}

class _UniversalLookupDialogState extends State<_UniversalLookupDialog> {
  final controller = TextEditingController();
  Timer? _debounce;
  String query = '';
  String? selectedProductId;
  Future<List<_LookupHit>> _future = Future.value(const <_LookupHit>[]);

  @override
  void dispose() {
    _debounce?.cancel();
    controller.dispose();
    super.dispose();
  }

  Future<List<_LookupHit>> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return const <_LookupHit>[];
    final results = await Future.wait<List<Map<String, Object?>>>([
      AppDatabase.instance.products(search: q, limit: 28),
      AppDatabase.instance.customers(search: q, limit: 18),
      AppDatabase.instance.suppliers(search: q, limit: 18),
    ]);
    final hits = <_LookupHit>[
      ...results[0].map((row) => _LookupHit('product', row)),
      ...results[1].map((row) => _LookupHit('customer', row)),
      ...results[2].map((row) => _LookupHit('supplier', row)),
    ];
    final needle = q.toLowerCase();
    int score(_LookupHit hit) {
      final name = hit.name.toLowerCase();
      if (name == needle) return 0;
      if (name.startsWith(needle)) return 1;
      if (name.contains(needle)) return 2;
      final phone = (hit.row['phone'] ?? hit.row['whatsapp'] ?? '').toString().toLowerCase();
      if (phone == needle) return 0;
      if (phone.contains(needle)) return 2;
      final sku = (hit.row['sku'] ?? hit.row['external_barcode'] ?? hit.row['internal_barcode'] ?? '').toString().toLowerCase();
      if (sku == needle) return 0;
      if (sku.contains(needle)) return 2;
      return 3;
    }
    int kindOrder(String kind) => switch (kind) { 'product' => 0, 'customer' => 1, _ => 2 };
    hits.sort((a, b) {
      final byScore = score(a).compareTo(score(b));
      if (byScore != 0) return byScore;
      final byKind = kindOrder(a.kind).compareTo(kindOrder(b.kind));
      if (byKind != 0) return byKind;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return hits;
  }

  void _onChanged(String value) {
    query = value.trim();
    selectedProductId = null;
    _debounce?.cancel();
    if (query.isEmpty) {
      setState(() => _future = Future.value(const <_LookupHit>[]));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      setState(() => _future = _search(query));
    });
    setState(() {});
  }

  Future<void> _selectFirst() async {
    final rows = await _search(controller.text);
    if (!mounted || rows.isEmpty) return;
    _activate(rows.first);
  }

  void _activate(_LookupHit hit) {
    if (hit.kind == 'product') {
      setState(() => selectedProductId = hit.row['id']?.toString());
      return;
    }
    if (hit.kind == 'customer') {
      widget.onOpenCustomer(hit.row);
      return;
    }
    widget.onOpenSupplier(hit.row);
  }

  IconData _iconFor(String kind) => switch (kind) {
    'customer' => Icons.person_outline,
    'supplier' => Icons.local_shipping_outlined,
    _ => Icons.inventory_2_outlined,
  };

  String _kindLabel(String kind) => switch (kind) {
    'customer' => 'Customer',
    'supplier' => 'Supplier',
    _ => 'Product',
  };

  String _subtitle(_LookupHit hit) {
    final row = hit.row;
    if (hit.kind == 'product') {
      final stock = (row['stock'] as num? ?? 0).toStringAsFixed(2);
      return '${row['sku'] ?? '—'} • Stock $stock ${row['unit'] ?? ''}';
    }
    if (hit.kind == 'customer') {
      final balance = (row['balance'] as num? ?? 0).toStringAsFixed(3);
      final phone = (row['phone'] ?? row['whatsapp'] ?? '').toString();
      return '${phone.isEmpty ? 'No phone' : phone} • Outstanding $balance';
    }
    final balance = (row['balance'] as num? ?? 0).toStringAsFixed(3);
    final phone = (row['phone'] ?? row['whatsapp'] ?? '').toString();
    return '${phone.isEmpty ? 'No phone' : phone} • Payable $balance';
  }

  @override
  Widget build(BuildContext context) {
    final accent = V3Style.labelAccent(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 18, 12, 0),
      title: Row(children: [
        Icon(Icons.manage_search_outlined, size: 23, color: accent),
        const SizedBox(width: 10),
        const Expanded(child: Text('RELIQ Lookup')),
        _ShortcutBadge(Platform.isMacOS ? 'Cmd+F' : 'Ctrl+F'),
        const SizedBox(width: 4),
        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
      ]),
      content: SizedBox(
        width: 1080,
        height: 650,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Search products, customers and suppliers from anywhere. Products open the existing product detail view; customers and suppliers jump straight to their ledger.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          ReliqGlass(
            blur: 14,
            radius: 14,
            padding: EdgeInsets.zero,
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: _onChanged,
              onSubmitted: (_) => _selectFirst(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Product / barcode / customer / phone / supplier — press Enter for first match',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 390,
                child: ReliqGlass(
                  blur: 12,
                  radius: 16,
                  padding: EdgeInsets.zero,
                  child: query.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.manage_search_outlined, size: 46, color: Theme.of(context).colorScheme.outline),
                              const SizedBox(height: 12),
                              const Text('One lookup for the whole business', style: TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              Text('Type a product, barcode, customer, phone number or supplier.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                            ]),
                          ),
                        )
                      : FutureBuilder<List<_LookupHit>>(
                          future: _future,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                            if (snapshot.hasError) return Center(child: Text('Lookup failed: ${snapshot.error}'));
                            final rows = snapshot.data ?? const <_LookupHit>[];
                            if (rows.isEmpty) return const Center(child: Text('No matching products, customers or suppliers.'));
                            return ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).dividerColor),
                              itemBuilder: (context, i) {
                                final hit = rows[i];
                                final id = hit.row['id']?.toString();
                                final selected = hit.kind == 'product' && id == selectedProductId;
                                return Material(
                                  color: selected
                                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .55)
                                      : (i.isOdd ? Theme.of(context).colorScheme.surfaceContainerLowest.withValues(alpha: .50) : Colors.transparent),
                                  child: ListTile(
                                    dense: true,
                                    selected: selected,
                                    onTap: () => _activate(hit),
                                    leading: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(color: accent.withValues(alpha: .10), borderRadius: BorderRadius.circular(9)),
                                      child: Icon(_iconFor(hit.kind), size: 19, color: accent),
                                    ),
                                    title: Text(hit.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                    subtitle: Text(_subtitle(hit), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                      Text(_kindLabel(hit.kind), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: accent)),
                                      if (hit.kind != 'product') const Icon(Icons.arrow_forward, size: 15),
                                    ]),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: selectedProductId == null
                    ? ReliqGlass(
                        blur: 12,
                        radius: 16,
                        child: Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.hub_outlined, size: 46, color: Theme.of(context).colorScheme.outline),
                            const SizedBox(height: 12),
                            const Text('Choose a result', style: TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 5),
                            Text('Products show stock and activity here.\nCustomers and suppliers open their ledger immediately.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ]),
                        ),
                      )
                    : FutureBuilder<Map<String, dynamic>>(
                        future: AppDatabase.instance.productLookupDetails(selectedProductId!),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) return const ReliqGlass(blur: 12, radius: 16, child: Center(child: CircularProgressIndicator()));
                          if (snapshot.data!.isEmpty) return const ReliqGlass(blur: 12, radius: 16, child: Center(child: Text('Product no longer exists.')));
                          return _ProductLookupDetails(data: snapshot.data!);
                        },
                      ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ProductLookupDetails extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ProductLookupDetails({required this.data});

  String _money(Object? value) => ((value as num?) ?? 0).toStringAsFixed(3);
  String _qty(Object? value) => ((value as num?) ?? 0).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final p = data['product'] as Map<String, Object?>;
    final sales = data['sales_summary'] as Map<String, Object?>;
    final purchases = data['purchase_summary'] as Map<String, Object?>;
    final recentSales = data['recent_sales'] as List<Map<String, Object?>>;
    final recentPurchases = data['recent_purchases'] as List<Map<String, Object?>>;
    final movements = data['movements'] as List<Map<String, Object?>>;
    final branches = data['branch_stock'] as List<Map<String, Object?>>;
    final expiries = data['expiries'] as List<Map<String, Object?>>;
    final components = data['components'] as List<Map<String, Object?>>;
    final active = ((p['active'] as num?) ?? 0).toInt() == 1;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: DefaultTabController(
        length: 3,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 48, height: 48, decoration: BoxDecoration(color: const Color(0xFFEAF1FF), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.inventory_2_outlined, color: V3Style.blue)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${p['name']}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  _statusChip(active ? 'Active' : 'Inactive', active ? const Color(0xFF16794C) : const Color(0xFFB42318)),
                ]),
                const SizedBox(height: 4),
                Text('${p['sku'] ?? '—'} • ${p['external_barcode'] ?? p['internal_barcode'] ?? 'No barcode'} • ${p['category'] ?? 'Uncategorised'} • ${p['unit'] ?? 'pcs'}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ])),
            ]),
          ),
          const TabBar(tabs: [Tab(text: 'Overview'), Tab(text: 'Sales & Purchases'), Tab(text: 'Stock & Expiry')]),
          Expanded(
            child: TabBarView(children: [
              ListView(padding: const EdgeInsets.all(16), children: [
                Wrap(spacing: 9, runSpacing: 9, children: [
                  _metric(context, 'Current stock', '${_qty(p['stock'])} ${p['unit'] ?? ''}', const Color(0xFF2563EB)),
                  _metric(context, 'Selling price', _money(p['price']), const Color(0xFF16794C)),
                  _metric(context, 'Cost', _money(p['cost']), const Color(0xFFB06B22)),
                  _metric(context, 'Minimum', _qty(p['min_stock']), const Color(0xFFD97706)),
                  _metric(context, 'Target', _qty(p['target_stock']), const Color(0xFF7C3AED)),
                  _metric(context, 'Product type', '${p['product_type'] ?? 'Stocked'}', const Color(0xFF0F766E)),
                ]),
                const SizedBox(height: 14),
                _section(context, 'Sales performance', [
                  _kv('Units sold', _qty(sales['qty'])),
                  _kv('Sales value', _money(sales['revenue'])),
                  _kv('Invoices', '${sales['invoices'] ?? 0}'),
                  _kv('Last sale', '${sales['last_date'] ?? '—'}'),
                ]),
                const SizedBox(height: 10),
                _section(context, 'Purchase performance', [
                  _kv('Units purchased', _qty(purchases['qty'])),
                  _kv('Purchase value', _money(purchases['spend'])),
                  _kv('Purchase documents', '${purchases['purchases'] ?? 0}'),
                  _kv('Last purchase', '${purchases['last_date'] ?? '—'}'),
                ]),
                if (components.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _section(context, 'Recipe / combo components', [
                    for (final c in components)
                      _kv('${c['component_name']} (${c['component_sku'] ?? '—'})', '${_qty(c['qty'])} ${c['unit'] ?? ''} × ${_qty(c['multiplier'])}'),
                  ]),
                ],
              ]),
              Row(children: [
                Expanded(child: _activityPanel(context, 'Recent sales', recentSales, true)),
                VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
                Expanded(child: _activityPanel(context, 'Recent purchases', recentPurchases, false)),
              ]),
              ListView(padding: const EdgeInsets.all(16), children: [
                _section(context, 'Stock by branch', [
                  for (final b in branches) _kv('${b['branch_name']}', _qty(b['qty'])),
                  _kv('Total across branches', branches.fold<double>(0,(sum,b)=>sum+(b['qty'] as num? ?? 0).toDouble()).toStringAsFixed(2)),
                ]),
                const SizedBox(height: 10),
                _section(context, 'Expiry / batch records from purchases', [
                  if (expiries.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No expiry records captured for this product.')),
                  for (final e in expiries) _kv('${e['expiry_date']} • ${e['batch_no'] ?? 'No batch'}', '${e['purchase_no'] ?? ''}'),
                ]),
                const SizedBox(height: 10),
                _section(context, 'Latest stock movements', [
                  if (movements.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No stock movements yet.')),
                  for (final m in movements) _kv('${m['type']} • ${m['reference'] ?? ''}', '${_qty(m['qty_change'])} • ${m['branch_name'] ?? ''}'),
                ]),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _statusChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      );

  Widget _metric(BuildContext context, String label, String value, Color color) => Container(
        width: 148,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: color.withValues(alpha: .07), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: .18))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)), const SizedBox(height: 4), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: color))]),
      );

  Widget _section(BuildContext context, String title, List<Widget> children) => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(11)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 7), ...children]),
      );

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)), const SizedBox(width: 10), Text(value, style: const TextStyle(fontWeight: FontWeight.w700))]),
      );

  Widget _activityPanel(BuildContext context, String title, List<Map<String, Object?>> rows, bool sale) => Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Expanded(child: rows.isEmpty
              ? const Center(child: Text('No activity.'))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).dividerColor),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r['no'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${r[sale ? 'customer_name' : 'supplier_name'] ?? (sale ? 'Walk-in' : 'Supplier')} • ${r['created_at'] ?? ''}'),
                      trailing: Text('${_qty(r['qty'])} × ${_money(r[sale ? 'unit_price' : 'unit_cost'])}'),
                    );
                  },
                )),
        ]),
      );
}
