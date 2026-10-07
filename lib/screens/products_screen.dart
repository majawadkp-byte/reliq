import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/bulk_product_import_service.dart';
import '../services/print_service.dart';
import '../ui/v3_style.dart';
import '../ui/product_search_field.dart';
import '../ui/shortcut_helper_bar.dart';
import '../ui/reliq_loading.dart';

double? _productUnitMultiplier(String usageUnit, String stockUnit) {
  final from = usageUnit.trim().toLowerCase();
  final to = stockUnit.trim().toLowerCase();
  if (from == to) return 1;
  const factors = <String, double>{
    'g>kg': 0.001,
    'kg>g': 1000,
    'ml>l': 0.001,
    'l>ml': 1000,
  };
  return factors['$from>$to'];
}

class ProductsScreen extends StatefulWidget {
  final bool showShortcutHelpers;
  const ProductsScreen({super.key, this.showShortcutHelpers = true});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  String query = '';
  String categoryFilter = 'All';
  String statusFilter = 'All';
  bool importing = false;
  int refreshKey = 0;
  final Set<String> selectedProductIds = <String>{};
  String typeFilter = 'All';
  String sellableFilter = 'All';
  String purchasableFilter = 'All';
  final searchFocus = FocusNode();
  Timer? _searchDebounce;
  late Future<List<Map<String, Object?>>> _productsFuture;
  late Future<List<String>> _categoriesFuture;

  @override
  void initState() {
    super.initState();
    _categoriesFuture = AppDatabase.instance.categories();
    _productsFuture = AppDatabase.instance.products(activeOnly: false, limit: 10000);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchFocus.dispose();
    super.dispose();
  }

  Map<ShortcutActivator, VoidCallback> _shortcutBindings() => {
    const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => edit(),
    const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => edit(),
    const SingleActivator(LogicalKeyboardKey.f2): () => searchFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.f5): _refresh,
  };

  InputDecoration _fieldDecoration(String label, {String? hint, String? helper}) => InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
      );

  void _refresh() {
    _searchDebounce?.cancel();
    setState(() {
      refreshKey++;
      _categoriesFuture = AppDatabase.instance.categories();
      _productsFuture = AppDatabase.instance.products(search: query, activeOnly: false, limit: 10000);
    });
  }

  void _onSearchChanged(String value) {
    query = value;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      setState(() {
        _productsFuture = AppDatabase.instance.products(search: query, activeOnly: false, limit: 10000);
      });
    });
  }

  Future<String?> _promptMasterValue({required bool category}) async {
    String entered = '';
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: _DialogSurface(
            title: category ? 'Add Category' : 'Add Unit',
            subtitle: category ? 'Create a category that can be selected on products.' : 'Create a unit of measure for products.',
            icon: category ? Icons.folder_outlined : Icons.straighten_outlined,
            child: TextFormField(
              autofocus: true,
              decoration: InputDecoration(labelText: category ? 'Category name' : 'Unit name'),
              onChanged: (v) => entered = v,
              onFieldSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, entered.trim()), child: const Text('Add')),
            ],
          ),
        ),
      ),
    );
    if (result == null || result.trim().isEmpty) return null;
    try {
      if (category) {
        await AppDatabase.instance.addCategory(result);
      } else {
        await AppDatabase.instance.addUnit(result);
      }
      if (mounted) _refresh();
      return result.trim();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      return null;
    }
  }

  Future<void> _manageCategories() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => const _CategoryManagerDialog(),
    );
    if (mounted) _refresh();
  }

  Future<void> _manageComponents(Map<String, Object?> product) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (_) => _RecipeComponentsDialog(product: product),
    );
    if (mounted) _refresh();
  }


  Future<Map<String, Object?>?> _pickReplacementProduct({String? excludeId}) async {
    final ctl = TextEditingController();
    Map<String, Object?>? selected;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: _DialogSurface(
            title: 'Choose Replacement Product',
            subtitle: 'Search by product name, SKU or barcode. Only active products are suggested.',
            icon: Icons.swap_horiz_outlined,
            child: V4ProductSearchField(
              controller: ctl,
              activeOnly: true,
              excludeProductId: excludeId,
              hintText: 'Type product name / SKU / barcode...',
              onSelected: (p) {
                selected = p;
                Navigator.pop(dialogContext);
              },
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            ],
          ),
        ),
      ),
    );
    ctl.dispose();
    return selected;
  }

  Future<void> _deleteProduct(Map<String, Object?> product) async {
    final summary = await AppDatabase.instance.productUsageSummary('${product['id']}');
    if (!mounted) return;
    final used = summary['used'] == true;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(used ? 'Archive product?' : 'Delete product permanently?'),
        content: Text(used
          ? '${product['name']} has stock or transaction history, so it cannot be hard-deleted. It will be archived and removed from normal POS/purchasing lists while history remains intact.'
          : '${product['name']} has no transaction or stock history. This will permanently delete it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(used ? 'Archive' : 'Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final result = await AppDatabase.instance.deleteOrArchiveProduct('${product['id']}');
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> edit([Map<String, Object?>? product]) async {
    final isNew = product == null;
    final categories = await AppDatabase.instance.categories();
    final units = await AppDatabase.instance.units();
    final taxProfiles = await AppDatabase.instance.taxProfiles(activeOnly: true);
    if (!mounted) return;

    final name = TextEditingController(text: '${product?['name'] ?? ''}');
    final sku = TextEditingController(text: '${product?['sku'] ?? ''}');
    final barcode = TextEditingController(text: '${product?['external_barcode'] ?? product?['internal_barcode'] ?? ''}');
    final cost = TextEditingController(text: '${product?['cost'] ?? 0}');
    final price = TextEditingController(text: '${product?['price'] ?? 0}');
    final openingStock = TextEditingController(text: '0');
    final minStock = TextEditingController(text: '${product?['min_stock'] ?? 0}');
    final targetStock = TextEditingController(text: '${product?['target_stock'] ?? 0}');
    final purchaseMoq = TextEditingController(text: '${product?['purchase_moq'] ?? 0}');
    final orderMultiple = TextEditingController(text: '${product?['order_multiple'] ?? 1}');
    final casePack = TextEditingController(text: '${product?['case_pack'] ?? 1}');
    final demandFamily = TextEditingController(text: '${product?['demand_family'] ?? ''}');

    String selectedCategory = (product?['category'] ?? 'General').toString().trim();
    String selectedUnit = (product?['unit'] ?? 'pcs').toString().trim();
    if (selectedCategory.isEmpty) selectedCategory = 'General';
    if (selectedUnit.isEmpty) selectedUnit = 'pcs';
    if (!categories.contains(selectedCategory)) categories.add(selectedCategory);
    if (!units.contains(selectedUnit)) units.add(selectedUnit);
    String productType = (product?['product_type'] ?? 'Stocked').toString();
    if (productType == 'Stock Item' || !['Stocked', 'Non-stocked', 'Service', 'Recipe', 'Combo'].contains(productType)) productType = 'Stocked';
    bool active = ((product?['active'] as num?) ?? 1).toInt() == 1;
    bool sellable = ((product?['sellable'] as num?) ?? 1).toInt() == 1;
    bool purchasable = ((product?['purchasable'] as num?) ?? 1).toInt() == 1;
    String lifecycleStatus = (product?['lifecycle_status'] ?? (active ? 'Active' : 'Archived')).toString();
    if (!['Active','Discontinued','Replaced','Archived'].contains(lifecycleStatus)) lifecycleStatus = active ? 'Active' : 'Archived';
    String replacementProductId = (product?['replacement_product_id'] ?? '').toString();
    String replacementProductName = '';
    bool inheritPredecessorHistory = ((product?['inherit_predecessor_history'] as num?) ?? 1).toInt() == 1;
    bool trackBatch = ((product?['track_batch'] as num?) ?? 0).toInt() == 1;
    bool trackExpiry = ((product?['track_expiry'] as num?) ?? 0).toInt() == 1;
    final defaultTax = taxProfiles.cast<Map<String,Object?>>().firstWhere((x) => ((x['is_default'] as num?) ?? 0).toInt() == 1, orElse: () => {'code':'NONE'});
    String taxCode = isNew ? (defaultTax['code'] ?? 'NONE').toString() : (product['tax_code'] ?? 'NONE').toString();
    if (!taxProfiles.any((x) => x['code'] == taxCode)) taxCode = 'NONE';
    bool addingCategory = false;
    String inlineCategory = '';

    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820, maxHeight: 790),
            child: _DialogSurface(
              title: isNew ? 'Add Product' : 'Edit Product',
              subtitle: isNew
                  ? 'SKU and barcode are generated automatically when left blank.'
                  : 'Edit product details. Use stock adjustment for audited quantity changes.',
              icon: Icons.inventory_2_outlined,
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _SectionLabel('PRODUCT DETAILS'),
                  const SizedBox(height: 10),
                  TextField(controller: name, decoration: _fieldDecoration('Product name')),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: TextField(controller: sku, decoration: _fieldDecoration('SKU', hint: 'Auto if blank'))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: barcode, decoration: _fieldDecoration('Barcode', hint: 'Auto if blank', helper: 'A unique EAN-13 barcode is created when blank.'))),
                  ]),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: productType,
                    isExpanded: true,
                    decoration: _fieldDecoration('Product type', helper: 'Stocked tracks on-hand quantity. Non-stocked and Service do not affect inventory. Recipe/Combo consume component stock.'),
                    items: const [
                      DropdownMenuItem(value: 'Stocked', child: Text('Stocked Product')),
                      DropdownMenuItem(value: 'Non-stocked', child: Text('Non-stocked Product')),
                      DropdownMenuItem(value: 'Service', child: Text('Service')),
                      DropdownMenuItem(value: 'Recipe', child: Text('Recipe')),
                      DropdownMenuItem(value: 'Combo', child: Text('Combo')),
                    ],
                    onChanged: (v) => setDialog(() => productType = v ?? 'Stocked'),
                  ),
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedCategory,
                        isExpanded: true,
                        decoration: _fieldDecoration('Category', helper: 'Categories can be renamed, disabled and reviewed from Category Manager.'),
                        items: [for (final c in (categories..sort())) DropdownMenuItem(value: c, child: Text(c))],
                        onChanged: (v) => setDialog(() => selectedCategory = v ?? selectedCategory),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: IconButton.filledTonal(tooltip: 'Add category', onPressed: () => setDialog(() { addingCategory = !addingCategory; inlineCategory = ''; }), icon: Icon(addingCategory ? Icons.close : Icons.add, size: 18)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedUnit,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Stock / selling unit'),
                        items: [for (final u in units) DropdownMenuItem(value: u, child: Text(u))],
                        onChanged: (v) => setDialog(() => selectedUnit = v ?? selectedUnit),
                      ),
                    ),
                  ]),
                  if (addingCategory) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: V3Style.blue.withValues(alpha: .05), borderRadius: BorderRadius.circular(10), border: Border.all(color: Theme.of(dialogContext).dividerColor)),
                      child: Row(children: [
                        Expanded(child: TextFormField(autofocus: true, decoration: const InputDecoration(labelText: 'New category name'), onChanged: (v) => inlineCategory = v, onFieldSubmitted: (_) async { final clean=inlineCategory.trim(); if(clean.isEmpty) return; await AppDatabase.instance.addCategory(clean); if(!categories.contains(clean)) categories.add(clean); if(dialogContext.mounted) setDialog(() { selectedCategory=clean; addingCategory=false; inlineCategory=''; }); })),
                        const SizedBox(width: 8),
                        FilledButton.icon(onPressed: () async { final clean=inlineCategory.trim(); if(clean.isEmpty) return; await AppDatabase.instance.addCategory(clean); if(!categories.contains(clean)) categories.add(clean); if(dialogContext.mounted) setDialog(() { selectedCategory=clean; addingCategory=false; inlineCategory=''; }); }, icon: const Icon(Icons.add, size: 16), label: const Text('Add')),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 22),
                  const _SectionLabel('PRICING & STOCK'),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Cost'))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Selling price'))),
                  ]),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: taxCode,
                    isExpanded: true,
                    decoration: _fieldDecoration('Tax profile', helper: 'Tax profiles are managed in Settings. POS and purchases will use this product tax by default.'),
                    items: [for (final t in taxProfiles) DropdownMenuItem(value: t['code'].toString(), child: Text('${t['name']} • ${(t['rate'] as num? ?? 0).toStringAsFixed(3)}%${((t['price_inclusive'] as num?) ?? 0).toInt()==1 ? ' • inclusive' : ''}'))],
                    onChanged: (v) => setDialog(() => taxCode = v ?? 'NONE'),
                  ),
                  const SizedBox(height: 12),
                  if (productType == 'Stocked') ...[
                    Row(children: [
                      if (isNew) ...[
                        Expanded(child: TextField(controller: openingStock, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Opening stock'))),
                        const SizedBox(width: 12),
                      ],
                      Expanded(child: TextField(controller: minStock, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Minimum stock'))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: targetStock, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Target stock'))),
                    ]),
                    if (!isNew) ...[
                      const SizedBox(height: 8),
                      Text('Current branch stock: ${(product['stock'] as num? ?? 0).toStringAsFixed(2)}', style: TextStyle(fontSize: 11, color: Theme.of(dialogContext).colorScheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(child: TextField(controller: purchaseMoq, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Purchase MOQ', helper: 'Minimum quantity RELIQ should place on a supplier order.'))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: orderMultiple, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Order multiple', helper: 'Round recommendations up to this multiple.'))),
                      const SizedBox(width: 12),
                      Expanded(child: TextField(controller: casePack, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: _fieldDecoration('Case / pack qty', helper: 'Informational pack size for purchasing.'))),
                    ]),
                  ] else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: V3Style.blue.withValues(alpha: .07), borderRadius: BorderRadius.circular(10), border: Border.all(color: V3Style.blue.withValues(alpha: .18))),
                      child: Text(
                        ['Recipe','Combo'].contains(productType)
                          ? '$productType has no directly adjusted stock balance. Sale availability is calculated from Stocked components.'
                          : '$productType does not maintain on-hand stock and is excluded from stock valuation, reorder alerts and demand-stock forecasting.',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  const SizedBox(height: 22),
                  const _SectionLabel('BEHAVIOUR'),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _OptionTile(title: 'Sellable', subtitle: 'Available in Sales POS when active.', value: sellable, onChanged: (v) => setDialog(() => sellable = v))),
                    const SizedBox(width: 10),
                    Expanded(child: _OptionTile(title: 'Purchasable', subtitle: 'Available in purchase entry.', value: purchasable, onChanged: (v) => setDialog(() => purchasable = v))),
                  ]),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: lifecycleStatus,
                    isExpanded: true,
                    decoration: _fieldDecoration('Lifecycle status', helper: 'Discontinued/Replaced/Archived products stay in history but disappear from normal operational lists.'),
                    items: const [
                      DropdownMenuItem(value:'Active', child:Text('Active')),
                      DropdownMenuItem(value:'Discontinued', child:Text('Discontinued')),
                      DropdownMenuItem(value:'Replaced', child:Text('Replaced')),
                      DropdownMenuItem(value:'Archived', child:Text('Archived')),
                    ],
                    onChanged: (v) => setDialog(() { lifecycleStatus=v??'Active'; active=lifecycleStatus=='Active'; }),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: demandFamily, decoration: _fieldDecoration('Demand family / equivalent group', hint:'e.g. 13mm Cordless Drill', helper:'Optional. Used only as a low-weight cold-start signal; active substitutes are never blindly combined.')),
                  if (!isNew && (lifecycleStatus == 'Replaced' || replacementProductId.isNotEmpty)) ...[
                    const SizedBox(height: 10),
                    Row(children:[
                      Expanded(child: InputDecorator(
                        decoration: const InputDecoration(labelText:'Replacement product'),
                        child: Text(replacementProductName.isNotEmpty ? replacementProductName : (replacementProductId.isEmpty ? 'Not selected' : replacementProductId), overflow: TextOverflow.ellipsis),
                      )),
                      const SizedBox(width:8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked=await _pickReplacementProduct(excludeId:'${product?['id'] ?? ''}');
                          if(picked!=null) setDialog(() { replacementProductId='${picked['id']}'; replacementProductName='${picked['name']}'; lifecycleStatus='Replaced'; active=false; });
                        },
                        icon:const Icon(Icons.search,size:17),
                        label:const Text('Choose'),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    _OptionTile(title:'Use predecessor history for replacement forecasting', subtitle:'Lets the replacement inherit older seasonal demand while it builds its own sales history.', value:inheritPredecessorHistory, onChanged:(v)=>setDialog(()=>inheritPredecessorHistory=v)),
                  ],
                  const SizedBox(height: 8),
                  _OptionTile(title: 'Active', subtitle: 'Active products appear in operational screens subject to Sellable/Purchasable.', value: active, onChanged: (v) => setDialog(() { active=v; lifecycleStatus=v?'Active':'Archived'; })),
                  if (productType == 'Stocked') ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: _OptionTile(title: 'Track batch / lot', subtitle: 'Keep lot numbers on incoming stock.', value: trackBatch, onChanged: (v) => setDialog(() => trackBatch = v))),
                      const SizedBox(width: 10),
                      Expanded(child: _OptionTile(title: 'Track expiry', subtitle: 'Use expiry dates and expiry alerts.', value: trackExpiry, onChanged: (v) => setDialog(() => trackExpiry = v))),
                    ]),
                  ],
                ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, true), icon: const Icon(Icons.save_outlined, size: 17), label: const Text('Save Product')),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok == true && name.text.trim().isNotEmpty) {
      try {
        final values = <String, Object?>{
          'name': name.text.trim(),
          'sku': sku.text.trim().isEmpty ? null : sku.text.trim(),
          'external_barcode': barcode.text.trim().isEmpty ? null : barcode.text.trim(),
          'category': selectedCategory,
          'unit': selectedUnit,
          'cost': double.tryParse(cost.text) ?? 0,
          'price': double.tryParse(price.text) ?? 0,
          'min_stock': double.tryParse(minStock.text) ?? 0,
          'target_stock': double.tryParse(targetStock.text) ?? 0,
          'purchase_moq': (double.tryParse(purchaseMoq.text) ?? 0).clamp(0, double.infinity),
          'order_multiple': (double.tryParse(orderMultiple.text) ?? 1) > 0 ? double.tryParse(orderMultiple.text) ?? 1 : 1,
          'case_pack': (double.tryParse(casePack.text) ?? 1) > 0 ? double.tryParse(casePack.text) ?? 1 : 1,
          'active': (active && lifecycleStatus == 'Active') ? 1 : 0,
          'sellable': sellable ? 1 : 0,
          'purchasable': purchasable ? 1 : 0,
          'lifecycle_status': lifecycleStatus,
          'replacement_product_id': replacementProductId.isEmpty ? null : replacementProductId,
          'demand_family': demandFamily.text.trim().isEmpty ? null : demandFamily.text.trim(),
          'inherit_predecessor_history': inheritPredecessorHistory ? 1 : 0,
          'track_batch': (productType == 'Stocked' && trackBatch) ? 1 : 0,
          'track_expiry': (productType == 'Stocked' && trackExpiry) ? 1 : 0,
          'product_type': productType,
          'tax_code': taxCode,
          'tax_inclusive': taxProfiles.firstWhere((x) => x['code'] == taxCode, orElse: () => {'price_inclusive': 0})['price_inclusive'] ?? 0,
        };
        if (isNew) values['stock'] = productType == 'Stocked' ? (double.tryParse(openingStock.text) ?? 0) : 0;
        final savedId = await AppDatabase.instance.saveProduct(values, id: product?['id'] as String?);
        if (mounted) {
          _refresh();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isNew ? 'Product saved. Missing SKU/barcode were generated automatically.' : 'Product updated.')));
          if (isNew && ['Recipe', 'Combo'].contains(productType)) {
            await _manageComponents({'id': savedId, 'name': name.text.trim(), 'product_type': productType});
          }
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save product: ${e.toString().replaceFirst('Exception: ', '')}')));
      }
    }

    Future<void>.delayed(const Duration(milliseconds: 450), () {
      for (final c in [name, sku, barcode, cost, price, openingStock, minStock, targetStock, purchaseMoq, orderMultiple, casePack, demandFamily]) {
        c.dispose();
      }
    });
  }

  Future<void> _adjust(Map<String, Object?> product) async {
    const reasons = [
      'Count correction', 'Damage / breakage', 'Expired stock', 'Shrinkage / loss',
      'Found stock', 'Opening balance correction', 'Transfer correction', 'Other',
    ];
    String qtyText = '1';
    String mode = 'Increase';
    String reason = reasons.first;
    String note = '';
    final current = (product['stock'] as num? ?? 0).toDouble();
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _DialogSurface(
              title: 'Adjust Stock',
              subtitle: '${product['name']} • ${product['sku'] ?? ''} • Current ${current.toStringAsFixed(2)}',
              icon: Icons.tune,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: mode,
                  decoration: const InputDecoration(labelText: 'Adjustment type'),
                  items: const [
                    DropdownMenuItem(value: 'Increase', child: Text('Increase Stock')),
                    DropdownMenuItem(value: 'Decrease', child: Text('Decrease Stock')),
                    DropdownMenuItem(value: 'Set', child: Text('Set Actual Stock')),
                  ],
                  onChanged: (v) => setDialog(() => mode = v ?? 'Increase'),
                ),
                const SizedBox(height: 12),
                TextFormField(initialValue: qtyText, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: mode == 'Set' ? 'Actual stock' : 'Quantity'), onChanged: (v) => qtyText = v),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: reason,
                  decoration: const InputDecoration(labelText: 'Reason'),
                  items: reasons.map((x) => DropdownMenuItem(value: x, child: Text(x, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) => setDialog(() => reason = v ?? reasons.first),
                ),
                const SizedBox(height: 12),
                TextFormField(decoration: const InputDecoration(labelText: 'Note (optional)'), onChanged: (v) => note = v),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save Adjustment')),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      final entered = double.tryParse(qtyText.trim()) ?? 0;
      final change = mode == 'Set' ? entered - current : mode == 'Decrease' ? -entered : entered;
      try {
        if (entered < 0 || change == 0) throw Exception('Enter a valid quantity change.');
        final combined = note.trim().isEmpty ? reason : '$reason — ${note.trim()}';
        await AppDatabase.instance.adjustStock(product['id'] as String, change, combined);
        if (mounted) _refresh();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Future<void> _toggleActive(Map<String, Object?> product) async {
    final active = ((product['active'] as num?) ?? 1).toInt() == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(active ? 'Disable product?' : 'Enable product?'),
        content: Text(active ? '${product['name']} will be hidden from Sales POS but its history is kept.' : '${product['name']} will be available again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(active ? 'Disable' : 'Enable')),
        ],
      ),
    );
    if (ok != true) return;
    await AppDatabase.instance.setProductActive(product['id'] as String, !active);
    if (mounted) _refresh();
  }

  Future<void> _printBarcode(Map<String, Object?> product) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      await PrintService.printBarcodeLabel(product);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not print barcode: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _downloadTemplate() async {
    try {
      final path = await BulkProductImportService.saveTemplate();
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Template saved: $path')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save template: ${e.toString().replaceFirst('Exception: ', '')}')));
    }
  }

  Future<void> _bulkUpload() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final file = await BulkProductImportService.chooseFile();
      if (file == null) return;
      final rows = await BulkProductImportService.parse(file);
      if (!mounted) return;
      final valid = rows.where((r) => r.valid).length;
      final invalid = rows.length - valid;

      final proceed = await showDialog<bool>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: .48),
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860, maxHeight: 690),
            child: _DialogSurface(
              title: 'Bulk Product Upload',
              subtitle: '${file.name} • $valid ready • $invalid with issues',
              icon: Icons.upload_file_outlined,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Blank SKU and barcode values are generated automatically. Existing duplicate SKU/barcode rows are skipped.'),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: SingleChildScrollView(
                    child: DataTable(
                      headingRowHeight: 36,
                      dataRowMinHeight: 34,
                      dataRowMaxHeight: 48,
                      columns: const [
                        DataColumn(label: Text('Row')),
                        DataColumn(label: Text('Product')),
                        DataColumn(label: Text('SKU')),
                        DataColumn(label: Text('Barcode')),
                        DataColumn(label: Text('Status')),
                      ],
                      rows: [
                        for (final r in rows.take(20))
                          DataRow(cells: [
                            DataCell(Text('${r.rowNumber}')),
                            DataCell(Text('${r.values['name'] ?? ''}')),
                            DataCell(Text('${r.values['sku'] ?? 'Auto'}')),
                            DataCell(Text('${r.values['external_barcode'] ?? 'Auto'}')),
                            DataCell(Text(r.valid ? 'Ready' : r.error ?? 'Invalid')),
                          ]),
                      ],
                    ),
                  ),
                ),
                if (rows.length > 20) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Showing first 20 of ${rows.length} rows.')),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                FilledButton.icon(onPressed: valid == 0 ? null : () => Navigator.pop(dialogContext, true), icon: const Icon(Icons.upload_file_outlined, size: 17), label: Text('Import $valid')),
              ],
            ),
          ),
        ),
      );
      if (proceed != true) return;

      final result = await BulkProductImportService.importRows(rows);
      if (!mounted) return;
      _refresh();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Import Complete'),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${result.imported} imported • ${result.skipped} skipped', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (result.errors.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Skipped rows:', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                ConstrainedBox(constraints: const BoxConstraints(maxHeight: 220), child: SingleChildScrollView(child: Text(result.errors.take(30).join('\n')))),
              ],
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk upload failed: ${e.toString().replaceFirst('Exception: ', '')}')));
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  void _toggleSelected(String id, bool selected) {
    setState(() {
      if (selected) { selectedProductIds.add(id); } else { selectedProductIds.remove(id); }
    });
  }

  Future<bool> _confirmBulk(String title, String message, String actionLabel) async {
    return await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title), content: Text(message), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(actionLabel)),
      ],
    )) ?? false;
  }

  Future<void> _bulkSet({bool? active, bool? sellable, bool? purchasable, String? category}) async {
    final ids = selectedProductIds.toList();
    if (ids.isEmpty) return;
    final labels = <String>[];
    if (active != null) labels.add(active ? 'activate' : 'deactivate');
    if (sellable != null) labels.add(sellable ? 'make sellable' : 'make not sellable');
    if (purchasable != null) labels.add(purchasable ? 'make purchasable' : 'make not purchasable');
    if (category != null) labels.add('move to category "$category"');
    final ok = await _confirmBulk('Bulk edit ${ids.length} products?',
      'This will ${labels.join(', ')} for ${ids.length} selected products. Historical transactions are not changed.', 'Apply');
    if (!ok) return;
    try {
      showReliqWorkingSnack(context, 'Updating ${ids.length} products… RELIQ is still working.');
      final result = await AppDatabase.instance.bulkUpdateProducts(productIds: ids, active: active, sellable: sellable, purchasable: purchasable, category: category);
      if (!mounted) return;
      hideReliqWorkingSnack(context);
      selectedProductIds.clear();
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result['updated'] ?? 0} products updated.')));
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Future<void> _bulkCategory() async {
    final categories = await AppDatabase.instance.categories();
    if (!mounted) return;
    String? chosen;
    chosen = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Change category'),
      content: SizedBox(width: 420, child: DropdownButtonFormField<String>(
        decoration: const InputDecoration(labelText: 'New category'),
        items: categories.map((x) => DropdownMenuItem(value:x, child:Text(x))).toList(),
        onChanged: (v) => chosen = v,
      )),
      actions: [TextButton(onPressed:()=>Navigator.pop(ctx), child:const Text('Cancel')), FilledButton(onPressed:()=>Navigator.pop(ctx, chosen), child:const Text('Continue'))],
    ));
    if (chosen != null && chosen!.trim().isNotEmpty) await _bulkSet(category: chosen);
  }

  Future<void> _bulkDeleteArchive() async {
    final ids = selectedProductIds.toList();
    if (ids.isEmpty) return;
    final ok = await _confirmBulk('Delete / archive ${ids.length} products?',
      'Products with no stock or transaction history will be permanently deleted. Products with stock or history will be archived instead so accounting, reports and intelligence history remain intact.', 'Delete / Archive');
    if (!ok) return;
    try {
      showReliqWorkingSnack(context, 'Deleting / archiving ${ids.length} products… RELIQ is still working.');
      final result = await AppDatabase.instance.bulkDeleteOrArchiveProducts(ids);
      if (!mounted) return;
      hideReliqWorkingSnack(context);
      selectedProductIds.clear();
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${result['deleted'] ?? 0} deleted • ${result['archived'] ?? 0} archived.')));
    } catch (e) {
      if (mounted) {
        hideReliqWorkingSnack(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  Widget _bulkBar(List<Map<String, Object?>> filteredRows) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bulkAccent = dark ? V3Style.lime : const Color(0xFF11908C);
    final bulkSurface = dark ? V3Style.lime.withValues(alpha: .10) : const Color(0xFFEAF2EF);
    final filteredIds = filteredRows.map((p) => '${p['id']}').toSet();
    final selectedInFilter = filteredIds.where(selectedProductIds.contains).length;
    final allFilteredSelected = filteredIds.isNotEmpty && selectedInFilter == filteredIds.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bulkSurface,
        border: Border.all(color: bulkAccent.withValues(alpha: .16)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(spacing: 7, runSpacing: 7, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Checkbox(value: allFilteredSelected, tristate: selectedInFilter > 0 && !allFilteredSelected, onChanged: (v) => setState(() {
          if (v == true) { selectedProductIds.addAll(filteredIds); } else { selectedProductIds.removeAll(filteredIds); }
        })),
        Text('${selectedProductIds.length} selected', style: const TextStyle(fontWeight: FontWeight.w800)),
        if (!allFilteredSelected) TextButton.icon(onPressed: () => setState(() => selectedProductIds.addAll(filteredIds)), icon: const Icon(Icons.select_all, size:16), label: Text('Select all ${filteredRows.length} filtered')),
        if (selectedProductIds.isNotEmpty) ...[
          OutlinedButton.icon(
            onPressed:()=>_bulkSet(active:true),
            style: OutlinedButton.styleFrom(foregroundColor: bulkAccent, backgroundColor: dark ? V3Style.lime.withValues(alpha: .10) : Colors.white70),
            icon:const Icon(Icons.visibility_outlined,size:16), label:const Text('Activate'),
          ),
          OutlinedButton.icon(
            onPressed:()=>_bulkSet(active:false),
            style: OutlinedButton.styleFrom(foregroundColor: bulkAccent, backgroundColor: dark ? V3Style.lime.withValues(alpha: .10) : Colors.white70),
            icon:const Icon(Icons.visibility_off_outlined,size:16), label:const Text('Deactivate'),
          ),
          PopupMenuButton<String>(tooltip:'Sell / purchase flags', onSelected:(v){ if(v=='sell') _bulkSet(sellable:true); if(v=='nosell') _bulkSet(sellable:false); if(v=='buy') _bulkSet(purchasable:true); if(v=='nobuy') _bulkSet(purchasable:false); }, itemBuilder:(_)=>const [
            PopupMenuItem(value:'sell',child:Text('Make Sellable')), PopupMenuItem(value:'nosell',child:Text('Make Not Sellable')),
            PopupMenuItem(value:'buy',child:Text('Make Purchasable')), PopupMenuItem(value:'nobuy',child:Text('Make Not Purchasable')),
          ], child: const Chip(avatar:Icon(Icons.tune,size:16), label:Text('Sales / Purchase'))),
          OutlinedButton.icon(onPressed:_bulkCategory, icon:const Icon(Icons.folder_outlined,size:16), label:const Text('Category')),
          OutlinedButton.icon(onPressed:_bulkDeleteArchive, icon:const Icon(Icons.delete_outline,size:16), label:const Text('Delete / Archive')),
          TextButton(onPressed:()=>setState(()=>selectedProductIds.clear()), child:const Text('Clear')),
        ],
      ]),
    );
  }

  bool _passesFilters(Map<String, Object?> p) {
    if (categoryFilter != 'All' && (p['category'] ?? '').toString() != categoryFilter) return false;
    final active = ((p['active'] as num?) ?? 1).toInt() == 1;
    final stock = (p['stock'] as num? ?? 0).toDouble();
    final min = (p['min_stock'] as num? ?? 0).toDouble();
    final type = (p['product_type'] ?? 'Stocked').toString();
    final lifecycle = (p['lifecycle_status'] ?? (active ? 'Active' : 'Archived')).toString();
    if (typeFilter != 'All' && type != typeFilter) return false;
    final sellable = ((p['sellable'] as num?) ?? 1).toInt() == 1;
    final purchasable = ((p['purchasable'] as num?) ?? 1).toInt() == 1;
    if (sellableFilter == 'Sellable' && !sellable) return false;
    if (sellableFilter == 'Not Sellable' && sellable) return false;
    if (purchasableFilter == 'Purchasable' && !purchasable) return false;
    if (purchasableFilter == 'Not Purchasable' && purchasable) return false;
    switch (statusFilter) {
      case 'Active':
        return lifecycle == 'Active' && active;
      case 'Discontinued':
        return lifecycle == 'Discontinued';
      case 'Replaced':
        return lifecycle == 'Replaced';
      case 'Archived':
        return lifecycle == 'Archived';
      case 'Inactive':
        return !active;
      case 'Low Stock':
        return type == 'Stocked' && stock > 0 && stock <= min;
      case 'Out of Stock':
        return type == 'Stocked' && stock <= 0;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: _shortcutBindings(),
        child: Focus(
          autofocus: true,
          child: Padding(
            padding: V3Style.pagePadding,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LayoutBuilder(builder: (context, box) {
            final narrow = box.maxWidth < 1050;
            final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Products & Barcodes', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text('Manage products, categories, stock status and printable barcode labels.', style: TextStyle(color: V3Style.mutedFor(context))),
            ]);
            final actions = Wrap(spacing: 7, runSpacing: 7, alignment: WrapAlignment.end, children: [
              OutlinedButton.icon(onPressed: _downloadTemplate, icon: const Icon(Icons.download_outlined, size: 17), label: const Text('Template')),
              OutlinedButton.icon(onPressed: importing ? null : _bulkUpload, icon: importing ? const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file_outlined, size: 17), label: const Text('Bulk Upload')),
              OutlinedButton.icon(onPressed: _manageCategories, icon: const Icon(Icons.folder_outlined, size: 17), label: const Text('Categories')),
              FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add, size: 18), label: const Text('Add Product')),
            ]);
            return narrow ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 10), actions]) : Row(children: [Expanded(child: title), actions]);
          }),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(width: 420, child: TextField(focusNode: searchFocus, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search product, SKU or barcode'), onChanged: _onSearchChanged)),
                SizedBox(
                  width: 210,
                  child: FutureBuilder<List<String>>(
                    future: _categoriesFuture,
                    builder: (context, snapshot) {
                      final values = ['All', ...?snapshot.data];
                      if (!values.contains(categoryFilter)) categoryFilter = 'All';
                      return DropdownButtonFormField<String>(
                        value: categoryFilter,
                        decoration: const InputDecoration(labelText: 'Category'),
                        items: [for (final x in values) DropdownMenuItem(value: x, child: Text(x))],
                        onChanged: (v) => setState(() => categoryFilter = v ?? 'All'),
                      );
                    },
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<String>(
                    value: statusFilter,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: const ['All', 'Active', 'Discontinued', 'Replaced', 'Archived', 'Inactive', 'Low Stock', 'Out of Stock'].map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
                    onChanged: (v) => setState(() => statusFilter = v ?? 'All'),
                  ),
                ),
                SizedBox(width: 160, child: DropdownButtonFormField<String>(value:typeFilter, decoration:const InputDecoration(labelText:'Product Type'), items:const ['All','Stocked','Non-stocked','Service','Recipe','Combo'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v)=>setState(()=>typeFilter=v??'All'))),
                SizedBox(width: 155, child: DropdownButtonFormField<String>(value:sellableFilter, decoration:const InputDecoration(labelText:'Sales'), items:const ['All','Sellable','Not Sellable'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v)=>setState(()=>sellableFilter=v??'All'))),
                SizedBox(width: 175, child: DropdownButtonFormField<String>(value:purchasableFilter, decoration:const InputDecoration(labelText:'Purchasing'), items:const ['All','Purchasable','Not Purchasable'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v)=>setState(()=>purchasableFilter=v??'All'))),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
              key: ValueKey(refreshKey),
              future: _productsFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('Products could not load: ${snapshot.error}'));
                if (!snapshot.hasData) return const ReliqLoadingState(
                  message: 'Loading products…',
                  detail: 'RELIQ is reading the product catalogue. You can continue as soon as this finishes.',
                );
                final rows = snapshot.data!.where(_passesFilters).toList();
                if (rows.isEmpty) return const Center(child: Text('No products match the current filters.'));
                return Column(children: [
                  _bulkBar(rows),
                  const SizedBox(height: 8),
                  Expanded(child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 1350) {
                        return ListView.separated(
                          padding: const EdgeInsets.all(8),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 7),
                          itemBuilder: (context, i) => _compactProductCard(rows[i]),
                        );
                      }
                      final width = math.max(1250.0, constraints.maxWidth);
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          child: Column(children: [
                            _productHeader(),
                            Expanded(
                              child: ListView.separated(
                                itemCount: rows.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, i) => _productRow(rows[i], i),
                              ),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                )),
                ]);
              },
            ),
          ),
          if (widget.showShortcutHelpers) const ShortcutHelperBar(items: [
            ('Ctrl/Cmd+F', 'Universal Lookup'), ('Ctrl/Cmd+N', 'New product'), ('F2', 'Lookup'), ('F5', 'Refresh'),
          ]),
        ]),
          ),
        ),
      );

  Widget _compactProductCard(Map<String, Object?> p) {
    final active = ((p['active'] as num?) ?? 1).toInt() == 1;
    final stock = (p['stock'] as num? ?? 0).toDouble();
    final min = (p['min_stock'] as num? ?? 0).toDouble();
    final barcode = (p['external_barcode'] ?? p['internal_barcode'] ?? '—').toString();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Checkbox(value: selectedProductIds.contains('${p['id']}'), onChanged: (v) => _toggleSelected('${p['id']}', v == true)),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              const SizedBox(height: 2),
              Text('${p['sku'] ?? '—'} • $barcode', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: V3Style.muted)),
            ])),
            _statusBadge((p['lifecycle_status'] ?? (active ? 'Active' : 'Archived')).toString(), active),
          ]),
          const SizedBox(height: 9),
          Wrap(spacing: 14, runSpacing: 6, children: [
            Text('Category: ${p['category'] ?? 'General'}', style: const TextStyle(fontSize: 11)),
            Text('Type: ${p['product_type'] ?? 'Stocked'}', style: const TextStyle(fontSize: 11)),
            Text(['Stocked','Recipe','Combo'].contains((p['product_type'] ?? 'Stocked').toString()) ? 'Stock: ${stock.toStringAsFixed(2)}' : 'Stock: Not tracked', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: (p['product_type'] ?? 'Stocked') == 'Stocked' && stock <= min ? V3Style.danger : null)),
            Text('Cost: ${(p['cost'] as num? ?? 0).toStringAsFixed(3)}', style: const TextStyle(fontSize: 11)),
            Text('Price: ${(p['price'] as num? ?? 0).toStringAsFixed(3)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _miniAction(Icons.qr_code_2, 'Print', () => _printBarcode(p), accent: V3Style.info),
            _miniAction(Icons.tune, 'Adjust', () => _adjust(p), accent: V3Style.warning),
            _miniAction(Icons.edit_outlined, 'Edit', () => edit(p), accent: V3Style.blue),
            if (['Recipe', 'Combo'].contains((p['product_type'] ?? '').toString())) _miniAction(Icons.account_tree_outlined, 'Components', () => _manageComponents(p), accent: V3Style.purple),
            _miniAction(active ? Icons.visibility_off_outlined : Icons.visibility_outlined, active ? 'Disable' : 'Enable', () => _toggleActive(p), accent: active ? V3Style.danger : V3Style.success),
            _miniAction(Icons.delete_outline, 'Delete', () => _deleteProduct(p), accent: V3Style.danger),
          ]),
        ]),
      ),
    );
  }

  Widget _productHeader() => Container(
        height: (Theme.of(context).listTileTheme.minTileHeight ?? 42).clamp(42, 60).toDouble(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: V3Style.tableHeader(context),
        child: Row(children: [
          const SizedBox(width: 38),
          _head('SKU', 130),
          _head('PRODUCT', 200),
          _head('BARCODE', 135),
          _head('CATEGORY', 110),
          _head('TYPE', 90),
          _head('UNIT', 70),
          _head('STOCK', 85, right: true),
          _head('COST', 90, right: true),
          _head('PRICE', 90, right: true),
          _head('STATUS', 105),
          const SizedBox(width: 285, child: Text('ACTIONS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .5))),
        ]),
      );

  Widget _productRow(Map<String, Object?> p, int index) {
    final active = ((p['active'] as num?) ?? 1).toInt() == 1;
    final stock = (p['stock'] as num? ?? 0).toDouble();
    final min = (p['min_stock'] as num? ?? 0).toDouble();
    final barcode = (p['external_barcode'] ?? p['internal_barcode'] ?? '—').toString();
    final stockStatus = stock <= 0 ? 'Out' : stock <= min ? 'Low' : 'In Stock';
    final themeRowHeight = Theme.of(context).listTileTheme.minTileHeight ?? 58;
    return Container(
      constraints: BoxConstraints(minHeight: themeRowHeight > 58 ? themeRowHeight : 58),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      color: index.isOdd ? V3Style.rowStripe(context) : Colors.transparent,
      child: Row(children: [
        SizedBox(width:38, child: Checkbox(value:selectedProductIds.contains('${p['id']}'), onChanged:(v)=>_toggleSelected('${p['id']}', v==true))),
        _cell('${p['sku'] ?? '—'}', 130, bold: true),
        SizedBox(width: 200, child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('${p['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(stockStatus, style: TextStyle(fontSize: 10, color: stock <= min ? Theme.of(context).colorScheme.error : V3Style.muted)),
        ])),
        _cell(barcode, 135),
        _cell('${p['category'] ?? 'General'}', 110),
        _cell('${p['product_type'] ?? 'Stocked'}', 90),
        _cell('${p['unit'] ?? 'pcs'}', 70),
        _cell(stock.toStringAsFixed(2), 85, right: true, bold: true),
        _cell((p['cost'] as num? ?? 0).toStringAsFixed(3), 90, right: true),
        _cell((p['price'] as num? ?? 0).toStringAsFixed(3), 90, right: true, bold: true),
        SizedBox(width: 105, child: Align(alignment: Alignment.centerLeft, child: _statusBadge((p['lifecycle_status'] ?? (active ? 'Active' : 'Archived')).toString(), active))),
        SizedBox(
          width: 285,
          child: Wrap(spacing: 5, runSpacing: 5, children: [
            _miniAction(Icons.qr_code_2, 'Print', () => _printBarcode(p), accent: V3Style.info),
            _miniAction(Icons.tune, 'Adjust', () => _adjust(p), accent: V3Style.warning),
            _miniAction(Icons.edit_outlined, 'Edit', () => edit(p), accent: V3Style.blue),
            if (['Recipe', 'Combo'].contains((p['product_type'] ?? '').toString())) _miniAction(Icons.account_tree_outlined, 'Components', () => _manageComponents(p), accent: V3Style.purple),
            _miniAction(active ? Icons.visibility_off_outlined : Icons.visibility_outlined, active ? 'Disable' : 'Enable', () => _toggleActive(p), accent: active ? V3Style.danger : V3Style.success),
            _miniAction(Icons.delete_outline, 'Delete', () => _deleteProduct(p), accent: V3Style.danger),
          ]),
        ),
      ]),
    );
  }

  Widget _head(String text, double width, {bool right = false}) => SizedBox(
        width: width,
        child: Text(text, textAlign: right ? TextAlign.right : TextAlign.left, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .5)),
      );

  Widget _cell(String text, double width, {bool right = false, bool bold = false}) => SizedBox(
        width: width,
        child: Text(text, textAlign: right ? TextAlign.right : TextAlign.left, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
      );

  Widget _statusBadge(String label, bool active) {
    final accent = active ? V3Style.success : V3Style.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: V3Style.softFor(accent, dark: Theme.of(context).brightness == Brightness.dark),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: .20)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: accent)),
    );
  }

  Widget _miniAction(IconData icon, String label, VoidCallback onPressed, {Color? accent}) {
    final tone = accent ?? V3Style.blue;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        visualDensity: VisualDensity.compact,
        foregroundColor: tone,
        backgroundColor: V3Style.softFor(tone, dark: dark),
        side: BorderSide(color: tone.withValues(alpha: .22)),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

class _CategoryManagerDialog extends StatefulWidget {
  const _CategoryManagerDialog();
  @override State<_CategoryManagerDialog> createState() => _CategoryManagerDialogState();
}

class _CategoryManagerDialogState extends State<_CategoryManagerDialog> {
  String query = '';
  String newName = '';
  int refresh = 0;

  Future<void> _add() async {
    final name = newName.trim();
    if (name.isEmpty) return;
    try {
      await AppDatabase.instance.addCategory(name);
      if (!mounted) return;
      setState(() { newName = ''; refresh++; });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _rename(String oldName) async {
    String value = oldName;
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename Category'),
        content: TextFormField(initialValue: oldName, autofocus: true, onChanged: (v) => value = v, onFieldSubmitted: (v) => Navigator.pop(c, v.trim())),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, value.trim()), child: const Text('Rename'))],
      ),
    );
    if (result == null || result.trim().isEmpty || result.trim() == oldName) return;
    await AppDatabase.instance.renameCategory(oldName, result);
    if (mounted) setState(() => refresh++);
  }

  Future<void> _toggle(Map<String, Object?> row) async {
    final name = row['name'].toString();
    final active = (row['active'] as num? ?? 0).toInt() == 1;
    if (active) {
      final total = (row['total_products'] as num? ?? 0).toInt();
      final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: Text('Disable $name?'),
        content: Text(total == 0 ? 'This category will be hidden from new product selection.' : 'This will disable the category and all $total products currently inside it. Historical transactions are not deleted.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Disable Category'))],
      ));
      if (ok != true) return;
    }
    await AppDatabase.instance.setCategoryActive(name, !active);
    if (mounted) setState(() => refresh++);
  }

  @override Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(28), backgroundColor: Colors.transparent,
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780, maxHeight: 720), child: _DialogSurface(
      title: 'Category Manager', subtitle: 'Search, add, rename and disable categories. Disabling a category disables every product inside it.', icon: Icons.folder_outlined,
      child: Column(children: [
        Row(children: [
          Expanded(flex: 2, child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search categories'), onChanged: (v) => setState(() => query = v))),
          const SizedBox(width: 10),
          Expanded(child: TextFormField(key: ValueKey('new-category-$refresh-$newName'), initialValue: newName, decoration: const InputDecoration(labelText: 'New category'), onChanged: (v) => newName = v, onFieldSubmitted: (_) => _add())),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 17), label: const Text('Add')),
        ]),
        const SizedBox(height: 12),
        Container(height: 38, padding: const EdgeInsets.symmetric(horizontal: 12), color: V3Style.tableHeader(context), child: const Row(children: [
          Expanded(child: Text('CATEGORY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
          SizedBox(width: 90, child: Text('ACTIVE', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
          SizedBox(width: 90, child: Text('INACTIVE', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
          SizedBox(width: 90, child: Text('TOTAL', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800))),
          SizedBox(width: 150),
        ])),
        Expanded(child: FutureBuilder<List<Map<String, Object?>>>(
          key: ValueKey(refresh), future: AppDatabase.instance.categoryStats(search: query),
          builder: (context, snap) {
            final rows = snap.data ?? [];
            if (rows.isEmpty) return const Center(child: Text('No categories found.'));
            return ListView.separated(itemCount: rows.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (context, i) {
              final r = rows[i]; final active = (r['active'] as num? ?? 0).toInt() == 1;
              return SizedBox(height: 52, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
                Expanded(child: Row(children: [Icon(active ? Icons.folder_outlined : Icons.folder_off_outlined, size: 18), const SizedBox(width: 9), Expanded(child: Text(r['name'].toString(), overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: active ? null : V3Style.muted)))])),
                SizedBox(width: 90, child: Text('${r['active_products'] ?? 0}', textAlign: TextAlign.right)),
                SizedBox(width: 90, child: Text('${r['inactive_products'] ?? 0}', textAlign: TextAlign.right)),
                SizedBox(width: 90, child: Text('${r['total_products'] ?? 0}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
                SizedBox(width: 150, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  IconButton(tooltip: 'Rename', onPressed: () => _rename(r['name'].toString()), icon: const Icon(Icons.edit_outlined, size: 18)),
                  IconButton(tooltip: active ? 'Disable category' : 'Enable category', onPressed: () => _toggle(r), icon: Icon(active ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18)),
                ])),
              ])));
            });
          },
        )),
      ]), actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    )),
  );
}

class _RecipeComponentsDialog extends StatefulWidget {
  final Map<String, Object?> product;
  const _RecipeComponentsDialog({required this.product});
  @override State<_RecipeComponentsDialog> createState() => _RecipeComponentsDialogState();
}

class _RecipeComponentsDialogState extends State<_RecipeComponentsDialog> {
  List<Map<String, Object?>> products = [];
  List<Map<String, Object?>> components = [];
  List<String> availableUnits = const ['pcs', 'kg', 'g', 'L', 'ml'];
  String componentId = '';
  final componentSearch = TextEditingController();
  String usageUnit = 'pcs';
  double qty = 1;
  double multiplier = 1;
  bool loading = true;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { componentSearch.dispose(); super.dispose(); }
  Future<void> _load() async {
    final all = await AppDatabase.instance.products(activeOnly: true);
    final current = await AppDatabase.instance.recipeComponents(widget.product['id'].toString());
    final units = await AppDatabase.instance.units();
    if (!mounted) return;
    setState(() {
      products = all.where((p) => p['id'] != widget.product['id'] && (p['product_type'] ?? 'Stocked').toString() == 'Stocked').toList();
      components = current.map((r) => Map<String, Object?>.from(r)).toList();
      availableUnits = units.isEmpty ? const ['pcs', 'kg', 'g', 'L', 'ml'] : units;
      if (products.isNotEmpty) {
        componentId = products.first['id'].toString();
        usageUnit = (products.first['unit'] ?? 'pcs').toString();
        if (!availableUnits.contains(usageUnit)) availableUnits = [...availableUnits, usageUnit];
        multiplier = 1;
      }
      loading = false;
    });
  }
  void _add() {
    if (componentId.isEmpty || qty <= 0 || multiplier <= 0) return;
    final p = products.firstWhere((x) => x['id'] == componentId);
    setState(() {
      components.removeWhere((x) => x['component_product_id'] == componentId);
      components.add({'component_product_id': componentId,'component_name': p['name'],'component_sku': p['sku'],'stock_unit': p['unit'],'qty': qty,'unit': usageUnit,'multiplier': multiplier});
    });
  }
  Future<void> _save() async {
    await AppDatabase.instance.saveRecipeComponents(widget.product['id'].toString(), components);
    if (mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(28), backgroundColor: Colors.transparent,
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720), child: _DialogSurface(
      title: '${widget.product['product_type']} Components', subtitle: '${widget.product['name']} • Quantity × multiplier is converted into the component stock unit. Example: 250 g × 0.001 = 0.25 kg.', icon: Icons.account_tree_outlined,
      child: loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
        Row(children: [
          Expanded(flex: 3, child: V4ProductSearchField(
            controller: componentSearch,
            activeOnly: true,
            allowedProductTypes: const {'Stocked'},
            excludeProductId: '${widget.product['id']}',
            hintText: 'Type component name / SKU / barcode...',
            onSelected: (p) {
              final stockUnit=(p['unit'] ?? 'pcs').toString();
              setState(() {
                componentId='${p['id']}';
                componentSearch.text='${p['name']}';
                usageUnit=stockUnit;
                if (!availableUnits.contains(usageUnit)) availableUnits=[...availableUnits,usageUnit];
                multiplier=1;
              });
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: TextFormField(initialValue: '1', decoration: const InputDecoration(labelText: 'Recipe qty'), keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => qty=double.tryParse(v) ?? 0)),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(value: availableUnits.contains(usageUnit) ? usageUnit : null, isExpanded: true, decoration: const InputDecoration(labelText: 'Usage unit'), items: [for (final u in availableUnits) DropdownMenuItem(value:u, child:Text(u))], onChanged: (v) { if(v==null) return; final p=products.firstWhere((x)=>x['id']==componentId); final stockUnit=(p['unit'] ?? 'pcs').toString(); setState(() { usageUnit=v; multiplier=_productUnitMultiplier(v,stockUnit) ?? multiplier; }); })),
          const SizedBox(width: 8),
          Expanded(child: TextFormField(key: ValueKey('component-mult-$componentId-$usageUnit-$multiplier'), initialValue: multiplier.toString(), decoration: const InputDecoration(labelText: 'Multiplier'), keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => multiplier=double.tryParse(v) ?? 0)),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 17), label: const Text('Add')),
        ]),
        const SizedBox(height: 12),
        Expanded(child: components.isEmpty ? const Center(child: Text('No components configured yet.')) : ListView.separated(itemCount: components.length, separatorBuilder: (_,__) => const Divider(height: 1), itemBuilder: (context,i) {
          final c=components[i]; final use=(c['qty'] as num? ?? 0).toDouble(); final mult=(c['multiplier'] as num? ?? 1).toDouble();
          return ListTile(dense:true, title:Text('${c['component_name'] ?? c['component_product_id']}', style: const TextStyle(fontWeight: FontWeight.w700)), subtitle:Text('${use.toStringAsFixed(3)} ${c['unit'] ?? ''} × ${mult.toStringAsFixed(4)} = ${(use*mult).toStringAsFixed(4)} ${c['stock_unit'] ?? ''} per sale unit'), trailing:IconButton(icon:const Icon(Icons.delete_outline), onPressed:()=>setState(()=>components.removeAt(i))));
        })),
      ]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined, size:17), label: const Text('Save Components'))],
    )),
  );
}

class _DialogSurface extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final List<Widget> actions;

  const _DialogSurface({required this.title, required this.subtitle, required this.icon, required this.child, required this.actions});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .76),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dark ? const Color(0xFF294154) : const Color(0xFFDCE4EC)),
        boxShadow: const [BoxShadow(color: Color(0x25000000), blurRadius: 32, offset: Offset(0, 14))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 14, 14),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(18)), border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
          child: Row(children: [
            Container(width: 38, height: 38, decoration: BoxDecoration(color: V3Style.blue.withValues(alpha: .10), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: V3Style.blue, size: 20)),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ])),
          ]),
        ),
        Flexible(child: Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 10), child: child)),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)), border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: 8), actions[i]]]),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF778B9E), letterSpacing: .9));
}

class _OptionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _OptionTile({required this.title, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .55), borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
            const SizedBox(width: 4),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ])),
          ]),
        ),
      );
}
