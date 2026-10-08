import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/license_manager.dart';
import '../services/permission_catalog.dart';

int? _firstIntValue(List<Map<String, Object?>> rows) {
  if (rows.isEmpty || rows.first.isEmpty) return null;
  final value = rows.first.values.first;
  return value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
}

class AppDatabase {
  AppDatabase._();

  @visibleForTesting
  static Future<AppDatabase> openTestDatabase() async {
    final app = AppDatabase._();
    app._db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 32,
            onConfigure: app._configureDatabase,
            onCreate: (d, v) => app._createSchema(d),
            onUpgrade: (d, o, n) => app._upgradeSchema(d, o, n)));
    await app._bootstrapSyncIdentity(app.db);
    await app._bootstrapIdentity(app.db);
    return app;
  }

  static final instance = AppDatabase._();
  Database? _db;
  final Random _secureRandom = Random.secure();
  String _nodeId = 'local';
  final Map<String, Future<List<Map<String, Object?>>>> _inventoryRefreshes =
      {};
  final Map<String, Future<Map<String, dynamic>>> _actionCenterRefreshes = {};

  Database get db => _db!;
  String get nodeId => _nodeId;

  Future<String> get dataDir async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'RELIQ Solutions'));
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> open() async {
    final dir = await dataDir;
    _db = await databaseFactory.openDatabase(
      p.join(dir, 'reliq_solutions.db'),
      options: OpenDatabaseOptions(
        version: 32,
        onConfigure: _configureDatabase,
        onCreate: (d, v) => _createSchema(d),
        onUpgrade: (d, oldVersion, newVersion) =>
            _upgradeSchema(d, oldVersion, newVersion),
      ),
    );
    await _ensureColumn(db, 'sales_returns', 'party_id', 'TEXT');
    await _ensureColumn(db, 'sales_returns', 'source_reference', 'TEXT');
    await _ensureColumn(db, 'purchase_returns', 'party_id', 'TEXT');
    await _ensureColumn(db, 'purchase_returns', 'source_reference', 'TEXT');
    await _bootstrapSyncIdentity(db);
    await _bootstrapIdentity(db);
    await _bootstrapMasterData(db);
    await _repairMissingProductCodes(db);
    await _ensureBranchStockSeed(db);
    await _ensureStockLotSeed(db);
  }

  Future<void> _configureDatabase(Database d) async {
    // Desktop SQLite tuning: keep writes durable while avoiding UI stalls from
    // readers waiting on a writer. WAL also lets report reads coexist better
    // with normal POS activity.
    await d.execute('PRAGMA foreign_keys = ON');
    await d.execute('PRAGMA busy_timeout = 5000');
    await d.execute('PRAGMA journal_mode = WAL');
    await d.execute('PRAGMA synchronous = NORMAL');
    await d.execute('PRAGMA temp_store = MEMORY');
    await d.execute('PRAGMA cache_size = -20000');
  }

  Future<void> _createSchema(Database d) async {
    for (final s in <String>[
      '''CREATE TABLE settings(k TEXT PRIMARY KEY,v TEXT)''',
      '''CREATE TABLE users(id TEXT PRIMARY KEY,username TEXT UNIQUE,display_name TEXT,role TEXT,pin_hash TEXT,active INTEGER,last_login TEXT,email TEXT,permissions TEXT)''',
      '''CREATE TABLE products(id TEXT PRIMARY KEY,sku TEXT UNIQUE,internal_barcode TEXT UNIQUE,external_barcode TEXT,name TEXT,category TEXT,unit TEXT,cost REAL DEFAULT 0,price REAL DEFAULT 0,min_stock REAL DEFAULT 0,target_stock REAL DEFAULT 0,stock REAL DEFAULT 0,location TEXT,supplier TEXT,expiry_date TEXT,active INTEGER DEFAULT 1,created_at TEXT,updated_at TEXT,product_type TEXT DEFAULT 'Stocked',track_batch INTEGER DEFAULT 0,track_expiry INTEGER DEFAULT 0,tax_code TEXT DEFAULT 'NONE',tax_inclusive INTEGER DEFAULT 0,purchase_moq REAL DEFAULT 0,order_multiple REAL DEFAULT 1,case_pack REAL DEFAULT 1,sellable INTEGER DEFAULT 1,purchasable INTEGER DEFAULT 1,lifecycle_status TEXT DEFAULT 'Active',replacement_product_id TEXT,demand_family TEXT,inherit_predecessor_history INTEGER DEFAULT 1)''',
      '''CREATE TABLE customers(id TEXT PRIMARY KEY,name TEXT,phone TEXT,whatsapp TEXT,email TEXT,contact TEXT,address TEXT,preferred_delivery TEXT DEFAULT 'WhatsApp',credit_allowed INTEGER DEFAULT 0,credit_limit REAL DEFAULT 0,terms_days INTEGER DEFAULT 0,active INTEGER DEFAULT 1,balance REAL DEFAULT 0,credit_balance REAL DEFAULT 0,group_id TEXT)''',
      '''CREATE TABLE suppliers(id TEXT PRIMARY KEY,name TEXT,phone TEXT,whatsapp TEXT,email TEXT,contact TEXT,address TEXT,lead_days INTEGER DEFAULT 0,terms_days INTEGER DEFAULT 0,active INTEGER DEFAULT 1,balance REAL DEFAULT 0,min_order_value REAL DEFAULT 0,credit_balance REAL DEFAULT 0)''',
      '''CREATE TABLE sales(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,due_date TEXT,customer_id TEXT,subtotal REAL,discount REAL,tax REAL DEFAULT 0,delivery_charge REAL DEFAULT 0,other_charge REAL DEFAULT 0,total REAL,paid REAL DEFAULT 0,balance REAL DEFAULT 0,returned_total REAL DEFAULT 0,refunded_total REAL DEFAULT 0,payment_method TEXT,status TEXT DEFAULT 'Completed',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT,revision INTEGER DEFAULT 0,edited_at TEXT,edited_by TEXT)''',
      '''CREATE TABLE sale_items(id INTEGER PRIMARY KEY AUTOINCREMENT,sale_id TEXT,product_id TEXT,name TEXT,qty REAL,unit_price REAL,discount REAL DEFAULT 0,cost REAL,tax REAL DEFAULT 0,tax_inclusive INTEGER DEFAULT 0,line_total REAL)''',
      '''CREATE TABLE purchases(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,due_date TEXT,supplier_id TEXT,document_no TEXT,subtotal REAL,discount REAL DEFAULT 0,tax REAL DEFAULT 0,freight REAL DEFAULT 0,other_charges REAL DEFAULT 0,total REAL,paid REAL DEFAULT 0,balance REAL DEFAULT 0,payment_method TEXT,status TEXT DEFAULT 'Received',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT,revision INTEGER DEFAULT 0,edited_at TEXT,edited_by TEXT,purchase_order_id TEXT)''',
      '''CREATE TABLE purchase_items(id INTEGER PRIMARY KEY AUTOINCREMENT,purchase_id TEXT,product_id TEXT,name TEXT,qty REAL,unit_cost REAL,discount REAL DEFAULT 0,tax REAL DEFAULT 0,tax_inclusive INTEGER DEFAULT 0,line_total REAL,batch_no TEXT,expiry_date TEXT,purchase_order_item_id INTEGER)''',
      '''CREATE TABLE stock_movements(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,product_id TEXT,qty_change REAL,type TEXT,reference TEXT,reason TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE payments(id TEXT PRIMARY KEY,created_at TEXT,party_type TEXT,party_id TEXT,document_type TEXT,document_id TEXT,amount REAL,method TEXT,reference TEXT,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE expenses(id TEXT PRIMARY KEY,expense_date TEXT,category TEXT,description TEXT,amount REAL,tax_amount REAL DEFAULT 0,tax_code TEXT DEFAULT 'NONE',payment_method TEXT,reference_no TEXT,notes TEXT,status TEXT DEFAULT 'Active',branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE audit(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,user TEXT,action TEXT,entity TEXT,entity_id TEXT,details TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE app_meta(k TEXT PRIMARY KEY,v TEXT)''',
      '''CREATE TABLE update_history(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,version TEXT,status TEXT,details TEXT)''',
      '''CREATE TABLE license_entitlements(feature TEXT PRIMARY KEY,enabled INTEGER NOT NULL DEFAULT 0)''',
      '''CREATE TABLE branches(id TEXT PRIMARY KEY,code TEXT UNIQUE,name TEXT,address TEXT,phone TEXT,active INTEGER DEFAULT 1,created_at TEXT)''',
      '''CREATE TABLE terminals(id TEXT PRIMARY KEY,name TEXT,branch_id TEXT,device_key TEXT UNIQUE,active INTEGER DEFAULT 1,last_seen TEXT)''',
      '''CREATE TABLE user_branches(user_id TEXT,branch_id TEXT,PRIMARY KEY(user_id,branch_id))''',
      '''CREATE TABLE sync_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE,entity_type TEXT,entity_id TEXT,operation TEXT,payload TEXT,created_at TEXT,updated_at TEXT,synced_at TEXT,status TEXT DEFAULT 'Pending',attempts INTEGER DEFAULT 0,next_retry_at TEXT,last_error TEXT,device_id TEXT,branch_id TEXT,sequence INTEGER DEFAULT 0,checksum TEXT)''',
      '''CREATE TABLE sync_inbox(id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE,entity_type TEXT,entity_id TEXT,operation TEXT,payload TEXT,received_at TEXT,applied_at TEXT,status TEXT DEFAULT 'Pending',error TEXT,source_device_id TEXT,server_sequence INTEGER)''',
      '''CREATE TABLE sync_devices(device_id TEXT PRIMARY KEY,name TEXT,platform TEXT,branch_id TEXT,terminal_id TEXT,registered_at TEXT,last_seen_at TEXT,server_device_id TEXT,status TEXT DEFAULT 'Local')''',
      '''CREATE TABLE sync_state(k TEXT PRIMARY KEY,v TEXT)''',
      '''CREATE TABLE sync_conflicts(id TEXT PRIMARY KEY,event_id TEXT,entity_type TEXT,entity_id TEXT,local_payload TEXT,remote_payload TEXT,detected_at TEXT,status TEXT DEFAULT 'Open',resolution TEXT,resolved_at TEXT)''',
      '''CREATE TABLE sync_entity_versions(entity_type TEXT,entity_id TEXT,revision INTEGER DEFAULT 0,payload_checksum TEXT,updated_at TEXT,source_device_id TEXT,PRIMARY KEY(entity_type,entity_id))''',
      '''CREATE TABLE sync_transaction_guards(entity_type TEXT,entity_id TEXT,event_id TEXT,applied_at TEXT,PRIMARY KEY(entity_type,entity_id))''',
      '''CREATE TABLE sync_security_events(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,kind TEXT,detail TEXT,severity TEXT DEFAULT 'Info')''',
      '''CREATE TABLE sales_returns(id TEXT PRIMARY KEY,no TEXT UNIQUE,sale_id TEXT,party_id TEXT,source_reference TEXT,created_at TEXT,total REAL DEFAULT 0,refund_amount REAL DEFAULT 0,refund_method TEXT,status TEXT DEFAULT 'Posted',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE sale_return_items(id INTEGER PRIMARY KEY AUTOINCREMENT,return_id TEXT,sale_item_id INTEGER,product_id TEXT,name TEXT,qty REAL,unit_price REAL,discount REAL DEFAULT 0,invoice_discount REAL DEFAULT 0,tax REAL DEFAULT 0,cost REAL DEFAULT 0,line_total REAL)''',
      '''CREATE TABLE purchase_returns(id TEXT PRIMARY KEY,no TEXT UNIQUE,purchase_id TEXT,party_id TEXT,source_reference TEXT,created_at TEXT,total REAL DEFAULT 0,refund_amount REAL DEFAULT 0,refund_method TEXT,status TEXT DEFAULT 'Posted',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE purchase_return_items(id INTEGER PRIMARY KEY AUTOINCREMENT,return_id TEXT,purchase_item_id INTEGER,product_id TEXT,name TEXT,qty REAL,unit_cost REAL,discount REAL DEFAULT 0,tax REAL DEFAULT 0,line_total REAL)''',
      '''CREATE TABLE product_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)''',
      '''CREATE TABLE product_units(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)''',
      '''CREATE TABLE branch_stock(product_id TEXT,branch_id TEXT,qty REAL DEFAULT 0,PRIMARY KEY(product_id,branch_id))''',
      '''CREATE TABLE stock_transfers(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,from_branch_id TEXT,to_branch_id TEXT,status TEXT DEFAULT 'Requested',notes TEXT,user_id TEXT,terminal_id TEXT,sent_at TEXT,received_at TEXT,rejected_at TEXT)''',
      '''CREATE TABLE stock_transfer_items(id INTEGER PRIMARY KEY AUTOINCREMENT,transfer_id TEXT,product_id TEXT,qty REAL)''',
      '''CREATE TABLE stock_transfer_lots(id INTEGER PRIMARY KEY AUTOINCREMENT,transfer_id TEXT,product_id TEXT,batch_no TEXT,expiry_date TEXT,qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,purchase_item_id INTEGER)''',
      '''CREATE TABLE recipe_components(parent_product_id TEXT,component_product_id TEXT,qty REAL,unit TEXT,multiplier REAL DEFAULT 1,PRIMARY KEY(parent_product_id,component_product_id))''',
      '''CREATE TABLE expense_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)''',
      '''CREATE TABLE tax_profiles(code TEXT PRIMARY KEY,name TEXT,rate REAL DEFAULT 0,price_inclusive INTEGER DEFAULT 0,active INTEGER DEFAULT 1,is_default INTEGER DEFAULT 0)''',
      '''CREATE TABLE cash_sessions(id TEXT PRIMARY KEY,session_date TEXT,opening_cash REAL DEFAULT 0,closing_cash REAL,opened_at TEXT,closed_at TEXT,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE cash_movements(id TEXT PRIMARY KEY,created_at TEXT,session_date TEXT,kind TEXT,amount REAL,method TEXT,reference TEXT,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE purchase_orders(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,expected_date TEXT,supplier_id TEXT,status TEXT DEFAULT 'Draft',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT,ordered_total REAL DEFAULT 0)''',
      '''CREATE TABLE purchase_order_items(id INTEGER PRIMARY KEY AUTOINCREMENT,purchase_order_id TEXT,product_id TEXT,name TEXT,ordered_qty REAL,received_qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,discount REAL DEFAULT 0,tax REAL DEFAULT 0,tax_inclusive INTEGER DEFAULT 0,batch_no TEXT,expiry_date TEXT)''',
      '''CREATE TABLE stock_lots(id TEXT PRIMARY KEY,product_id TEXT,branch_id TEXT,purchase_item_id INTEGER,batch_no TEXT,expiry_date TEXT,received_qty REAL DEFAULT 0,remaining_qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,created_at TEXT,status TEXT DEFAULT 'Open')''',
      '''CREATE TABLE stock_counts(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,posted_at TEXT,status TEXT DEFAULT 'Draft',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE stock_count_items(id INTEGER PRIMARY KEY AUTOINCREMENT,stock_count_id TEXT,product_id TEXT,name TEXT,expected_qty REAL DEFAULT 0,counted_qty REAL,variance REAL DEFAULT 0,posted INTEGER DEFAULT 0)''',
      '''CREATE TABLE bi_snoozes(action_key TEXT PRIMARY KEY,snoozed_until TEXT,created_at TEXT,user_id TEXT)''',
      '''CREATE TABLE business_action_state(action_key TEXT PRIMARY KEY,status TEXT DEFAULT 'Open',fingerprint TEXT,snoozed_until TEXT,note TEXT,updated_at TEXT,user_id TEXT)''',
      '''CREATE TABLE payment_allocations(id INTEGER PRIMARY KEY AUTOINCREMENT,payment_id TEXT,document_type TEXT,document_id TEXT,allocated_amount REAL DEFAULT 0,created_at TEXT)''',
      '''CREATE TABLE customer_groups(id TEXT PRIMARY KEY,name TEXT UNIQUE,default_discount_pct REAL DEFAULT 0,active INTEGER DEFAULT 1,notes TEXT)''',
      '''CREATE TABLE customer_group_discount_rules(id TEXT PRIMARY KEY,group_id TEXT,scope_type TEXT,scope_value TEXT,discount_pct REAL DEFAULT 0,active INTEGER DEFAULT 1)''',
      '''CREATE TABLE sale_tenders(id INTEGER PRIMARY KEY AUTOINCREMENT,sale_id TEXT,method TEXT,amount REAL DEFAULT 0,tendered REAL DEFAULT 0,change_due REAL DEFAULT 0,reference TEXT)''',
      '''CREATE TABLE held_sales(id TEXT PRIMARY KEY,created_at TEXT,customer_id TEXT,bill_discount REAL DEFAULT 0,delivery_charge REAL DEFAULT 0,other_charge REAL DEFAULT 0,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE held_sale_items(id INTEGER PRIMARY KEY AUTOINCREMENT,held_sale_id TEXT,product_id TEXT,qty REAL,price REAL,line_discount REAL DEFAULT 0)''',
      '''CREATE TABLE account_adjustments(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,due_date TEXT,party_type TEXT,party_id TEXT,kind TEXT,amount REAL DEFAULT 0,balance REAL DEFAULT 0,reference TEXT,notes TEXT,status TEXT DEFAULT 'Posted',branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE adjustment_allocations(id INTEGER PRIMARY KEY AUTOINCREMENT,adjustment_id TEXT,document_type TEXT,document_id TEXT,allocated_amount REAL DEFAULT 0,created_at TEXT)''',
      '''CREATE TABLE payment_reconciliations(id TEXT PRIMARY KEY,payment_id TEXT UNIQUE,account_type TEXT,statement_ref TEXT,reconciled_at TEXT,reconciled_by TEXT,notes TEXT)''',
      '''CREATE TABLE quotations(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,valid_until TEXT,customer_id TEXT,status TEXT DEFAULT 'Draft',subtotal REAL DEFAULT 0,discount REAL DEFAULT 0,tax REAL DEFAULT 0,delivery_charge REAL DEFAULT 0,other_charge REAL DEFAULT 0,total REAL DEFAULT 0,notes TEXT,custom_fields TEXT,converted_held_sale_id TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)''',
      '''CREATE TABLE quotation_items(id INTEGER PRIMARY KEY AUTOINCREMENT,quotation_id TEXT,product_id TEXT,name TEXT,sku TEXT,qty REAL,unit_price REAL,line_discount REAL DEFAULT 0,tax REAL DEFAULT 0,line_total REAL DEFAULT 0)''',
      '''CREATE TABLE communication_log(id TEXT PRIMARY KEY,created_at TEXT,party_type TEXT,party_id TEXT,channel TEXT,document_type TEXT,document_id TEXT,action TEXT,user_id TEXT)''',
      '''CREATE TABLE analytics_snapshots(cache_key TEXT PRIMARY KEY,payload TEXT NOT NULL,updated_at TEXT NOT NULL,dirty INTEGER NOT NULL DEFAULT 0)''',
    ]) {
      await d.execute(s);
    }
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_created_at ON sales(created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_created_at ON purchases(created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements(product_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payments_party ON payments(party_type,party_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_due ON sales(due_date,balance)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_due ON purchases(due_date,balance)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_returns_sale ON sales_returns(sale_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_returns_branch_created ON sales_returns(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_return_items_sale_item ON sale_return_items(sale_item_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_returns_purchase ON purchase_returns(purchase_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_returns_branch_created ON purchase_returns(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_return_items_purchase_item ON purchase_return_items(purchase_item_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_branch_stock_branch ON branch_stock(branch_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfer_created ON stock_transfers(created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_transfer_lots_transfer ON stock_transfer_lots(transfer_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_branch_created ON sales(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_branch_created ON purchases(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payments_branch_created ON payments(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_branch_date ON expenses(branch_id,expense_date)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_movements_branch_created ON stock_movements(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_products_category_active ON products(category,active)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_products_name_nocase ON products(name COLLATE NOCASE)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_products_external_barcode ON products(external_barcode)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_products_internal_barcode ON products(internal_barcode)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_customers_name_nocase ON customers(name COLLATE NOCASE)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_customers_whatsapp ON customers(whatsapp)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_suppliers_name_nocase ON suppliers(name COLLATE NOCASE)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_suppliers_phone ON suppliers(phone)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_customer_created ON sales(customer_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_status_balance_created ON sales(status,balance,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_supplier_created ON purchases(supplier_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_status_balance_created ON purchases(status,balance,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_branch_due_balance ON sales(branch_id,due_date,balance)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_branch_due_balance ON purchases(branch_id,due_date,balance)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_branch_status_date ON expenses(branch_id,status,expense_date)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sales_branch_status_created ON sales(branch_id,status,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchases_branch_status_created ON purchases(branch_id,status,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payments_created ON payments(created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_communication_document_channel_created ON communication_log(document_type,document_id,channel,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_cash_sessions_day_branch ON cash_sessions(session_date,branch_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_cash_movements_day_branch ON cash_movements(session_date,branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_expense_category_name ON expense_categories(name)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_orders_branch_status ON purchase_orders(branch_id,status,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_order_items_po ON purchase_order_items(purchase_order_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_lots_product_branch_expiry ON stock_lots(product_id,branch_id,expiry_date,remaining_qty)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_counts_branch_status ON stock_counts(branch_id,status,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_stock_count_items_count ON stock_count_items(stock_count_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_bi_snoozes_until ON bi_snoozes(snoozed_until)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_business_action_state_status ON business_action_state(status,snoozed_until,updated_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payment_allocations_payment ON payment_allocations(payment_id,document_type,document_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_customer_group_rules_group ON customer_group_discount_rules(group_id,scope_type,scope_value)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_tenders_sale ON sale_tenders(sale_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_held_sales_branch ON held_sales(branch_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_account_adjustments_party ON account_adjustments(party_type,party_id,created_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_account_adjustments_due ON account_adjustments(due_date,balance)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_adjustment_allocations_adjustment ON adjustment_allocations(adjustment_id,document_type,document_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payment_reconciliations_payment ON payment_reconciliations(payment_id)');
    await _createAnalyticsInfrastructure(d);
    await d.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_outbox_event ON sync_outbox(event_id) WHERE event_id IS NOT NULL");
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_outbox_status_retry ON sync_outbox(status,next_retry_at,created_at)');
    await d.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_inbox_event ON sync_inbox(event_id) WHERE event_id IS NOT NULL");
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_inbox_status ON sync_inbox(status,received_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status ON sync_conflicts(status,detected_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_txn_guards_event ON sync_transaction_guards(event_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_entity_versions_updated ON sync_entity_versions(updated_at)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_security_events_created ON sync_security_events(created_at)');
    // Audit Trail hot paths. Audit data is append-only and can grow into the
    // millions of rows, so all normal browsing must be backed by indexes.
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_created_id ON audit(created_at DESC,id DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_action_created ON audit(action,created_at DESC,id DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_entity_created ON audit(entity,created_at DESC,id DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_user_created ON audit(user_id,created_at DESC,id DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_branch_created ON audit(branch_id,created_at DESC,id DESC)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_audit_entity_id_created ON audit(entity,entity_id,created_at DESC,id DESC)');
    await d.insert('app_meta', {'k': 'schema_version', 'v': '2.3.1-audit'});
    await _bootstrapIdentity(d);
  }

  Future<void> _upgradeSchema(
      Database d, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _ensureColumn(d, 'sales', 'delivery_charge', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'sales', 'other_charge', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'purchases', 'freight', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'purchases', 'other_charges', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'purchases', 'payment_method', 'TEXT');
      await _ensureColumn(d, 'purchases', 'notes', 'TEXT');
      await d.insert(
        'app_meta',
        {'k': 'schema_version', 'v': '4.0.0-m3'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (oldVersion < 3) {
      await d.execute(
          'CREATE TABLE IF NOT EXISTS branches(id TEXT PRIMARY KEY,code TEXT UNIQUE,name TEXT,address TEXT,phone TEXT,active INTEGER DEFAULT 1,created_at TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS terminals(id TEXT PRIMARY KEY,name TEXT,branch_id TEXT,device_key TEXT UNIQUE,active INTEGER DEFAULT 1,last_seen TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS user_branches(user_id TEXT,branch_id TEXT,PRIMARY KEY(user_id,branch_id))');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS sync_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT,entity_type TEXT,entity_id TEXT,operation TEXT,payload TEXT,created_at TEXT,synced_at TEXT)');
      await _ensureColumn(d, 'users', 'email', 'TEXT');
      await _ensureColumn(d, 'users', 'permissions', 'TEXT');
      for (final table in [
        'sales',
        'purchases',
        'payments',
        'stock_movements',
        'audit'
      ]) {
        await _ensureColumn(d, table, 'branch_id', 'TEXT');
        await _ensureColumn(d, table, 'terminal_id', 'TEXT');
        await _ensureColumn(d, table, 'user_id', 'TEXT');
      }
      await _bootstrapIdentity(d);
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m5'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 4) {
      await _ensureColumn(d, 'expenses', 'branch_id', 'TEXT');
      await _ensureColumn(d, 'expenses', 'terminal_id', 'TEXT');
      await _ensureColumn(d, 'expenses', 'user_id', 'TEXT');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_created_at ON sales(created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_created_at ON purchases(created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements(product_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_payments_party ON payments(party_type,party_id,created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 5) {
      await _ensureColumn(d, 'suppliers', 'terms_days', 'INTEGER DEFAULT 0');
      await _ensureColumn(d, 'sales', 'due_date', 'TEXT');
      await _ensureColumn(d, 'purchases', 'due_date', 'TEXT');
      await d.execute(
          "UPDATE sales SET due_date=created_at WHERE due_date IS NULL AND balance>0");
      await d.execute(
          "UPDATE purchases SET due_date=created_at WHERE due_date IS NULL AND balance>0");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_due ON sales(due_date,balance)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_due ON purchases(due_date,balance)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 6) {
      await _ensureColumn(d, 'sales', 'returned_total', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'sales', 'refunded_total', 'REAL DEFAULT 0');
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sales_returns(id TEXT PRIMARY KEY,no TEXT UNIQUE,sale_id TEXT,party_id TEXT,source_reference TEXT,created_at TEXT,total REAL DEFAULT 0,refund_amount REAL DEFAULT 0,refund_method TEXT,status TEXT DEFAULT 'Posted',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sale_return_items(id INTEGER PRIMARY KEY AUTOINCREMENT,return_id TEXT,sale_item_id INTEGER,product_id TEXT,name TEXT,qty REAL,unit_price REAL,line_total REAL)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_returns_sale ON sales_returns(sale_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sale_return_items_sale_item ON sale_return_items(sale_item_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_branch_stock_branch ON branch_stock(branch_id,product_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_transfer_created ON stock_transfers(created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6.3'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 7) {
      await _ensureColumn(d, 'purchases', 'discount', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'purchase_items', 'discount', 'REAL DEFAULT 0');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS product_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS product_units(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS expense_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS tax_profiles(code TEXT PRIMARY KEY,name TEXT,rate REAL DEFAULT 0,price_inclusive INTEGER DEFAULT 0,active INTEGER DEFAULT 1,is_default INTEGER DEFAULT 0)');
      for (final name in const [
        'General',
        'Utilities',
        'Rent',
        'Transport',
        'Repairs',
        'Staff',
        'Bank Charges',
        'Marketing'
      ]) {
        await d.insert('expense_categories', {'name': name, 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await d.insert(
          'tax_profiles',
          {
            'code': 'NONE',
            'name': 'No Tax / Exempt',
            'rate': 0.0,
            'price_inclusive': 0,
            'active': 1,
            'is_default': 1
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6.5'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 8) {
      await d.execute(
          'CREATE TABLE IF NOT EXISTS branch_stock(product_id TEXT,branch_id TEXT,qty REAL DEFAULT 0,PRIMARY KEY(product_id,branch_id))');
      await d.execute(
          "CREATE TABLE IF NOT EXISTS stock_transfers(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,from_branch_id TEXT,to_branch_id TEXT,status TEXT DEFAULT 'Completed',notes TEXT,user_id TEXT,terminal_id TEXT)");
      await d.execute(
          'CREATE TABLE IF NOT EXISTS stock_transfer_items(id INTEGER PRIMARY KEY AUTOINCREMENT,transfer_id TEXT,product_id TEXT,qty REAL)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS recipe_components(parent_product_id TEXT,component_product_id TEXT,qty REAL,unit TEXT,multiplier REAL DEFAULT 1,PRIMARY KEY(parent_product_id,component_product_id))');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_branch_stock_branch ON branch_stock(branch_id,product_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_transfer_created ON stock_transfers(created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_branch_created ON sales(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_branch_created ON purchases(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_payments_branch_created ON payments(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_expenses_branch_date ON expenses(branch_id,expense_date)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_movements_branch_created ON stock_movements(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_category_active ON products(category,active)');
      await d.execute(
          "UPDATE products SET product_type='Stocked' WHERE product_type IS NULL OR TRIM(product_type)='' OR product_type='Stock Item'");
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6.7'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 9) {
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_users_username_active ON users(username,active)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sale_items_product_sale ON sale_items(product_id,sale_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_items_product_purchase ON purchase_items(product_id,purchase_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m6.9'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 10) {
      await d.execute(
          'CREATE TABLE IF NOT EXISTS expense_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS tax_profiles(code TEXT PRIMARY KEY,name TEXT,rate REAL DEFAULT 0,price_inclusive INTEGER DEFAULT 0,active INTEGER DEFAULT 1,is_default INTEGER DEFAULT 0)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS cash_sessions(id TEXT PRIMARY KEY,session_date TEXT,opening_cash REAL DEFAULT 0,closing_cash REAL,opened_at TEXT,closed_at TEXT,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS cash_movements(id TEXT PRIMARY KEY,created_at TEXT,session_date TEXT,kind TEXT,amount REAL,method TEXT,reference TEXT,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)');
      await _ensureColumn(d, 'expenses', 'tax_code', "TEXT DEFAULT 'NONE'");
      await _ensureColumn(
          d, 'sale_items', 'tax_inclusive', 'INTEGER DEFAULT 0');
      await _ensureColumn(
          d, 'purchase_items', 'tax_inclusive', 'INTEGER DEFAULT 0');
      await _ensureColumn(d, 'sales', 'revision', 'INTEGER DEFAULT 0');
      await _ensureColumn(d, 'sales', 'edited_at', 'TEXT');
      await _ensureColumn(d, 'sales', 'edited_by', 'TEXT');
      await _ensureColumn(d, 'purchases', 'revision', 'INTEGER DEFAULT 0');
      await _ensureColumn(d, 'purchases', 'edited_at', 'TEXT');
      await _ensureColumn(d, 'purchases', 'edited_by', 'TEXT');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_cash_sessions_day_branch ON cash_sessions(session_date,branch_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_cash_movements_day_branch ON cash_movements(session_date,branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_expense_category_name ON expense_categories(name)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m7.1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 11) {
      await _ensureColumn(d, 'sale_return_items', 'discount', 'REAL DEFAULT 0');
      await _ensureColumn(
          d, 'sale_return_items', 'invoice_discount', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'sale_return_items', 'tax', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'sale_return_items', 'cost', 'REAL DEFAULT 0');
      await d.execute(
          "CREATE TABLE IF NOT EXISTS purchase_returns(id TEXT PRIMARY KEY,no TEXT UNIQUE,purchase_id TEXT,party_id TEXT,source_reference TEXT,created_at TEXT,total REAL DEFAULT 0,refund_amount REAL DEFAULT 0,refund_method TEXT,status TEXT DEFAULT 'Posted',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS purchase_return_items(id INTEGER PRIMARY KEY AUTOINCREMENT,return_id TEXT,purchase_item_id INTEGER,product_id TEXT,name TEXT,qty REAL,unit_cost REAL,discount REAL DEFAULT 0,tax REAL DEFAULT 0,line_total REAL)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_returns_purchase ON purchase_returns(purchase_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_return_items_purchase_item ON purchase_return_items(purchase_item_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m7.6'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 12) {
      await _ensureColumn(d, 'products', 'purchase_moq', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'products', 'order_multiple', 'REAL DEFAULT 1');
      await _ensureColumn(d, 'products', 'case_pack', 'REAL DEFAULT 1');
      await _ensureColumn(d, 'suppliers', 'min_order_value', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'purchases', 'purchase_order_id', 'TEXT');
      await _ensureColumn(
          d, 'purchase_items', 'purchase_order_item_id', 'INTEGER');
      await d.execute(
          "CREATE TABLE IF NOT EXISTS purchase_orders(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,expected_date TEXT,supplier_id TEXT,status TEXT DEFAULT 'Draft',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT,ordered_total REAL DEFAULT 0)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS purchase_order_items(id INTEGER PRIMARY KEY AUTOINCREMENT,purchase_order_id TEXT,product_id TEXT,name TEXT,ordered_qty REAL,received_qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,discount REAL DEFAULT 0,tax REAL DEFAULT 0,tax_inclusive INTEGER DEFAULT 0,batch_no TEXT,expiry_date TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS stock_lots(id TEXT PRIMARY KEY,product_id TEXT,branch_id TEXT,purchase_item_id INTEGER,batch_no TEXT,expiry_date TEXT,received_qty REAL DEFAULT 0,remaining_qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,created_at TEXT,status TEXT DEFAULT 'Open')");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS stock_counts(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,posted_at TEXT,status TEXT DEFAULT 'Draft',notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS stock_count_items(id INTEGER PRIMARY KEY AUTOINCREMENT,stock_count_id TEXT,product_id TEXT,name TEXT,expected_qty REAL DEFAULT 0,counted_qty REAL,variance REAL DEFAULT 0,posted INTEGER DEFAULT 0)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_orders_branch_status ON purchase_orders(branch_id,status,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_order_items_po ON purchase_order_items(purchase_order_id,product_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_lots_product_branch_expiry ON stock_lots(product_id,branch_id,expiry_date,remaining_qty)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_counts_branch_status ON stock_counts(branch_id,status,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_count_items_count ON stock_count_items(stock_count_id,product_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m7.7'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 13) {
      await d.execute(
          'CREATE TABLE IF NOT EXISTS bi_snoozes(action_key TEXT PRIMARY KEY,snoozed_until TEXT,created_at TEXT,user_id TEXT)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_bi_snoozes_until ON bi_snoozes(snoozed_until)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m7.8'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 14) {
      await _ensureColumn(d, 'customers', 'credit_balance', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'customers', 'group_id', 'TEXT');
      await _ensureColumn(d, 'suppliers', 'credit_balance', 'REAL DEFAULT 0');
      await _ensureColumn(d, 'stock_transfers', 'sent_at', 'TEXT');
      await _ensureColumn(d, 'stock_transfers', 'received_at', 'TEXT');
      await _ensureColumn(d, 'stock_transfers', 'rejected_at', 'TEXT');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS payment_allocations(id INTEGER PRIMARY KEY AUTOINCREMENT,payment_id TEXT,document_type TEXT,document_id TEXT,allocated_amount REAL DEFAULT 0,created_at TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS customer_groups(id TEXT PRIMARY KEY,name TEXT UNIQUE,default_discount_pct REAL DEFAULT 0,active INTEGER DEFAULT 1,notes TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS customer_group_discount_rules(id TEXT PRIMARY KEY,group_id TEXT,scope_type TEXT,scope_value TEXT,discount_pct REAL DEFAULT 0,active INTEGER DEFAULT 1)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS sale_tenders(id INTEGER PRIMARY KEY AUTOINCREMENT,sale_id TEXT,method TEXT,amount REAL DEFAULT 0,tendered REAL DEFAULT 0,change_due REAL DEFAULT 0,reference TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS held_sales(id TEXT PRIMARY KEY,created_at TEXT,customer_id TEXT,bill_discount REAL DEFAULT 0,delivery_charge REAL DEFAULT 0,other_charge REAL DEFAULT 0,notes TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS held_sale_items(id INTEGER PRIMARY KEY AUTOINCREMENT,held_sale_id TEXT,product_id TEXT,qty REAL,price REAL,line_discount REAL DEFAULT 0)');
      await d.execute(
          'CREATE TABLE IF NOT EXISTS stock_transfer_lots(id INTEGER PRIMARY KEY AUTOINCREMENT,transfer_id TEXT,product_id TEXT,batch_no TEXT,expiry_date TEXT,qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,purchase_item_id INTEGER)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_payment_allocations_payment ON payment_allocations(payment_id,document_type,document_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_customer_group_rules_group ON customer_group_discount_rules(group_id,scope_type,scope_value)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sale_tenders_sale ON sale_tenders(sale_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_held_sales_branch ON held_sales(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_stock_transfer_lots_transfer ON stock_transfer_lots(transfer_id,product_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m7.9'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 15) {
      for (final entry in const <String, String>{
        'event_id': 'TEXT',
        'updated_at': 'TEXT',
        'status': "TEXT DEFAULT 'Pending'",
        'attempts': 'INTEGER DEFAULT 0',
        'next_retry_at': 'TEXT',
        'last_error': 'TEXT',
        'device_id': 'TEXT',
        'branch_id': 'TEXT',
        'sequence': 'INTEGER DEFAULT 0',
        'checksum': 'TEXT',
      }.entries) {
        await _ensureColumn(d, 'sync_outbox', entry.key, entry.value);
      }
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_inbox(id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE,entity_type TEXT,entity_id TEXT,operation TEXT,payload TEXT,received_at TEXT,applied_at TEXT,status TEXT DEFAULT 'Pending',error TEXT,source_device_id TEXT,server_sequence INTEGER)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_devices(device_id TEXT PRIMARY KEY,name TEXT,platform TEXT,branch_id TEXT,terminal_id TEXT,registered_at TEXT,last_seen_at TEXT,server_device_id TEXT,status TEXT DEFAULT 'Local')");
      await d.execute(
          'CREATE TABLE IF NOT EXISTS sync_state(k TEXT PRIMARY KEY,v TEXT)');
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_conflicts(id TEXT PRIMARY KEY,event_id TEXT,entity_type TEXT,entity_id TEXT,local_payload TEXT,remote_payload TEXT,detected_at TEXT,status TEXT DEFAULT 'Open',resolution TEXT,resolved_at TEXT)");
      await d.execute(
          "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_outbox_event ON sync_outbox(event_id) WHERE event_id IS NOT NULL");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_outbox_status_retry ON sync_outbox(status,next_retry_at,created_at)');
      await d.execute(
          "CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_inbox_event ON sync_inbox(event_id) WHERE event_id IS NOT NULL");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_inbox_status ON sync_inbox(status,received_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status ON sync_conflicts(status,detected_at)');
      await _bootstrapSyncIdentity(d);
      final syncMeta = await d.query('app_meta',
          where: "k IN ('sync_device_id','current_branch_id')");
      final syncValues = <String, String>{
        for (final r in syncMeta)
          (r['k'] ?? '').toString(): (r['v'] ?? '').toString()
      };
      final legacyRows =
          await d.query('sync_outbox', where: 'event_id IS NULL');
      for (final row in legacyRows) {
        final legacyId = ((row['id'] as num?) ?? 0).toInt();
        await d.update(
            'sync_outbox',
            {
              'event_id':
                  'EVT-${syncValues['sync_device_id'] ?? 'legacy'}-legacy-$legacyId',
              'status': 'Pending',
              'attempts': 0,
              'updated_at': (row['created_at'] ??
                      DateTime.now().toUtc().toIso8601String())
                  .toString(),
              'device_id': syncValues['sync_device_id'] ?? '',
              'branch_id': syncValues['current_branch_id'] ?? 'BR-HQ',
              'sequence': legacyId,
            },
            where: 'id=?',
            whereArgs: [legacyId]);
      }
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m8.0a'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 16) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_entity_versions(entity_type TEXT,entity_id TEXT,revision INTEGER DEFAULT 0,payload_checksum TEXT,updated_at TEXT,source_device_id TEXT,PRIMARY KEY(entity_type,entity_id))");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_entity_versions_updated ON sync_entity_versions(updated_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m8.0b'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 17) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_transaction_guards(entity_type TEXT,entity_id TEXT,event_id TEXT,applied_at TEXT,PRIMARY KEY(entity_type,entity_id))");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_txn_guards_event ON sync_transaction_guards(event_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m8.0c'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 18) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS sync_security_events(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,kind TEXT,detail TEXT,severity TEXT DEFAULT 'Info')");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_security_events_created ON sync_security_events(created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '4.0.0-m8.0d'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (oldVersion < 19) {
      await _ensureColumn(d, 'sales_returns', 'party_id', 'TEXT');
      await _ensureColumn(d, 'sales_returns', 'source_reference', 'TEXT');
      await _ensureColumn(d, 'purchase_returns', 'party_id', 'TEXT');
      await _ensureColumn(d, 'purchase_returns', 'source_reference', 'TEXT');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '1.0.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 20) {
      await _ensureColumn(d, 'products', 'sellable', 'INTEGER DEFAULT 1');
      await _ensureColumn(d, 'products', 'purchasable', 'INTEGER DEFAULT 1');
      await _ensureColumn(
          d, 'products', 'lifecycle_status', "TEXT DEFAULT 'Active'");
      await _ensureColumn(d, 'products', 'replacement_product_id', 'TEXT');
      await _ensureColumn(d, 'products', 'demand_family', 'TEXT');
      await _ensureColumn(
          d, 'products', 'inherit_predecessor_history', 'INTEGER DEFAULT 1');
      await d.execute(
          "UPDATE products SET lifecycle_status=CASE WHEN active=1 THEN 'Active' ELSE 'Archived' END WHERE lifecycle_status IS NULL OR TRIM(lifecycle_status)=''");
      await d.execute("UPDATE products SET sellable=1 WHERE sellable IS NULL");
      await d.execute(
          "UPDATE products SET purchasable=1 WHERE purchasable IS NULL");
      await d.execute(
          "CREATE INDEX IF NOT EXISTS idx_products_replacement ON products(replacement_product_id)");
      await d.execute(
          "CREATE INDEX IF NOT EXISTS idx_products_demand_family ON products(demand_family,lifecycle_status)");
      await d.insert('app_meta', {'k': 'schema_version', 'v': '1.6.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 21) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS account_adjustments(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,due_date TEXT,party_type TEXT,party_id TEXT,kind TEXT,amount REAL DEFAULT 0,balance REAL DEFAULT 0,reference TEXT,notes TEXT,status TEXT DEFAULT 'Posted',branch_id TEXT,terminal_id TEXT,user_id TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS adjustment_allocations(id INTEGER PRIMARY KEY AUTOINCREMENT,adjustment_id TEXT,document_type TEXT,document_id TEXT,allocated_amount REAL DEFAULT 0,created_at TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS payment_reconciliations(id TEXT PRIMARY KEY,payment_id TEXT UNIQUE,account_type TEXT,statement_ref TEXT,reconciled_at TEXT,reconciled_by TEXT,notes TEXT)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_account_adjustments_party ON account_adjustments(party_type,party_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_account_adjustments_due ON account_adjustments(due_date,balance)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_adjustment_allocations_adjustment ON adjustment_allocations(adjustment_id,document_type,document_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_payment_reconciliations_payment ON payment_reconciliations(payment_id)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '1.8.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 22) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS update_history(id INTEGER PRIMARY KEY AUTOINCREMENT,created_at TEXT,version TEXT,status TEXT,details TEXT)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_update_history_created ON update_history(created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '1.9.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 23) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS analytics_snapshots(cache_key TEXT PRIMARY KEY,payload TEXT NOT NULL,updated_at TEXT NOT NULL,dirty INTEGER NOT NULL DEFAULT 0)");
      await _createAnalyticsInfrastructure(d);
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.0.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 24) {
      await _ensureColumn(d, 'customers', 'whatsapp', 'TEXT');
      await _ensureColumn(
          d, 'customers', 'preferred_delivery', "TEXT DEFAULT 'WhatsApp'");
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.0.3'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 25) {
      await _ensureColumn(d, 'suppliers', 'whatsapp', 'TEXT');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.0.4'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // V2.0.5 quotation + communication schema. An older build accidentally
    // placed this migration after a return statement, so keep it idempotent.
    if (oldVersion < 26) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS quotations(id TEXT PRIMARY KEY,no TEXT UNIQUE,created_at TEXT,valid_until TEXT,customer_id TEXT,status TEXT DEFAULT 'Draft',subtotal REAL DEFAULT 0,discount REAL DEFAULT 0,tax REAL DEFAULT 0,delivery_charge REAL DEFAULT 0,other_charge REAL DEFAULT 0,total REAL DEFAULT 0,notes TEXT,custom_fields TEXT,converted_held_sale_id TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS quotation_items(id INTEGER PRIMARY KEY AUTOINCREMENT,quotation_id TEXT,product_id TEXT,name TEXT,sku TEXT,qty REAL,unit_price REAL,line_discount REAL DEFAULT 0,tax REAL DEFAULT 0,line_total REAL DEFAULT 0)");
      await d.execute(
          "CREATE TABLE IF NOT EXISTS communication_log(id TEXT PRIMARY KEY,created_at TEXT,party_type TEXT,party_id TEXT,channel TEXT,document_type TEXT,document_id TEXT,action TEXT,user_id TEXT)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_quotations_branch_date ON quotations(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_quotation_items_quote ON quotation_items(quotation_id)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_communication_party ON communication_log(party_type,party_id,created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.0.5'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 27) {
      await d.execute(
          "CREATE TABLE IF NOT EXISTS business_action_state(action_key TEXT PRIMARY KEY,status TEXT DEFAULT 'Open',fingerprint TEXT,snoozed_until TEXT,note TEXT,updated_at TEXT,user_id TEXT)");
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_business_action_state_status ON business_action_state(status,snoozed_until,updated_at)');
      await _createAnalyticsInfrastructure(d);
      await d.rawUpdate('UPDATE analytics_snapshots SET dirty=1 WHERE dirty=0');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.1.0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 28) {
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_returns_branch_created ON sales_returns(branch_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchase_returns_branch_created ON purchase_returns(branch_id,created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.1.1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 29) {
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_name_nocase ON products(name COLLATE NOCASE)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_external_barcode ON products(external_barcode)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_internal_barcode ON products(internal_barcode)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_customers_name_nocase ON customers(name COLLATE NOCASE)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_customers_whatsapp ON customers(whatsapp)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_suppliers_name_nocase ON suppliers(name COLLATE NOCASE)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_suppliers_phone ON suppliers(phone)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.1.2'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 30) {
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_customer_created ON sales(customer_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_status_balance_created ON sales(status,balance,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_supplier_created ON purchases(supplier_id,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_status_balance_created ON purchases(status,balance,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_payments_created ON payments(created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_communication_document_channel_created ON communication_log(document_type,document_id,channel,created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.1.3'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 31) {
      // V2.2.3: reporting hot paths. These composite indexes keep large ledgers
      // responsive without changing accounting behaviour or stored values.
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_branch_due_balance ON sales(branch_id,due_date,balance)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_branch_due_balance ON purchases(branch_id,due_date,balance)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_expenses_branch_status_date ON expenses(branch_id,status,expense_date)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_sales_branch_status_created ON sales(branch_id,status,created_at)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_purchases_branch_status_created ON purchases(branch_id,status,created_at)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.2.3'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    if (oldVersion < 32) {
      // V2.3.1 audit-performance migration. These indexes make pagination and
      // common filters scale without changing any existing audit records.
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_created_id ON audit(created_at DESC,id DESC)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_action_created ON audit(action,created_at DESC,id DESC)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_entity_created ON audit(entity,created_at DESC,id DESC)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_user_created ON audit(user_id,created_at DESC,id DESC)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_branch_created ON audit(branch_id,created_at DESC,id DESC)');
      await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_audit_entity_id_created ON audit(entity,entity_id,created_at DESC,id DESC)');
      await d.insert('app_meta', {'k': 'schema_version', 'v': '2.3.1-audit'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _createAnalyticsInfrastructure(DatabaseExecutor d) async {
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_items_sale_product ON sale_items(sale_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase_product ON purchase_items(purchase_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_return_items_return_product ON sale_return_items(return_id,product_id)');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_return_items_return_product ON purchase_return_items(return_id,product_id)');
    const tables = <String>[
      'settings',
      'products',
      'customers',
      'suppliers',
      'branches',
      'branch_stock',
      'stock_lots',
      'sales',
      'sale_items',
      'sales_returns',
      'sale_return_items',
      'purchases',
      'purchase_items',
      'purchase_returns',
      'purchase_return_items',
      'purchase_orders',
      'purchase_order_items',
      'payments',
      'payment_allocations',
      'expenses',
      'stock_movements',
      'bi_snoozes',
      'business_action_state',
      'account_adjustments'
    ];
    for (final table in tables) {
      // Older schemas may not have tables introduced by later migrations.
      // SQLite cannot create a trigger on a table that does not exist yet.
      final present = await d.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      if (present.isEmpty) continue;
      for (final op in const <String>['INSERT', 'UPDATE', 'DELETE']) {
        final suffix =
            switch (op) { 'INSERT' => 'ai', 'UPDATE' => 'au', _ => 'ad' };
        await d.execute(
            'CREATE TRIGGER IF NOT EXISTS trg_analytics_${table}_$suffix AFTER $op ON $table BEGIN UPDATE analytics_snapshots SET dirty=1 WHERE dirty=0; END');
      }
    }
  }

  Future<Map<String, Object?>?> _analyticsSnapshot(String key) async {
    final rows = await db.query('analytics_snapshots',
        where: 'cache_key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  bool _snapshotNeedsRefresh(Map<String, Object?> row,
      {Duration maxAge = const Duration(minutes: 10)}) {
    if ((row['dirty'] as num? ?? 0).toInt() != 0) return true;
    final updated = DateTime.tryParse('${row['updated_at'] ?? ''}');
    if (updated == null) return true;
    return DateTime.now().toUtc().difference(updated.toUtc()) > maxAge;
  }

  List<Map<String, Object?>>? _decodeAnalyticsList(Map<String, Object?>? row) {
    if (row == null) return null;
    try {
      final decoded = jsonDecode('${row['payload']}');
      if (decoded is! List) return null;
      return decoded.map((e) => Map<String, Object?>.from(e as Map)).toList();
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _decodeAnalyticsMap(Map<String, Object?>? row) {
    if (row == null) return null;
    try {
      final decoded = jsonDecode('${row['payload']}');
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAnalyticsSnapshot(String key, Object payload) async {
    await db.insert(
        'analytics_snapshots',
        {
          'cache_key': key,
          'payload': jsonEncode(payload),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'dirty': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> warmAnalyticsSnapshots() async {
    try {
      await inventoryIntelligence(lookbackDays: 30);
      await businessActionCenter(lookbackDays: 30, refreshInventory: false);
      final now = DateTime.now();
      final from = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 29));
      final to = DateTime(now.year, now.month, now.day);
      await reportSummaryFast(from, to);
      await reportDailySeriesFast(from, to);
    } catch (_) {
      // Analytics are an enhancement. Startup and POS must never fail because a refresh failed.
    }
  }

  Future<void> logSyncSecurityEvent(String kind, String detail,
      {String severity = 'Info'}) async {
    await db.insert('sync_security_events', {
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'kind': kind,
      'detail': detail,
      'severity': severity,
    });
  }

  Future<void> _bootstrapMasterData(DatabaseExecutor d) async {
    await d.execute(
        'CREATE TABLE IF NOT EXISTS product_categories(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
    await d.execute(
        'CREATE TABLE IF NOT EXISTS product_units(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE COLLATE NOCASE,active INTEGER DEFAULT 1)');
    for (final name in const ['General']) {
      await d.insert('product_categories', {'name': name, 'active': 1},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final name in const [
      'pcs',
      'box',
      'pack',
      'kg',
      'g',
      'L',
      'ml',
      'set'
    ]) {
      await d.insert('product_units', {'name': name, 'active': 1},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final productCats = await d.rawQuery(
        "SELECT DISTINCT TRIM(category) name FROM products WHERE TRIM(COALESCE(category,''))<>''");
    for (final row in productCats) {
      final name = (row['name'] ?? '').toString().trim();
      if (name.isNotEmpty) {
        await d.insert('product_categories', {'name': name, 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    final productUnits = await d.rawQuery(
        "SELECT DISTINCT TRIM(unit) name FROM products WHERE TRIM(COALESCE(unit,''))<>''");
    for (final row in productUnits) {
      final name = (row['name'] ?? '').toString().trim();
      if (name.isNotEmpty) {
        await d.insert('product_units', {'name': name, 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
  }

  Future<bool> _settingBool(DatabaseExecutor e, String key,
      {bool fallback = false}) async {
    final rows = await e.query('settings',
        columns: ['v'], where: 'k=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return fallback;
    final value = (rows.first['v'] ?? '').toString().toLowerCase();
    if (value.isEmpty) return fallback;
    return value == '1' || value == 'true' || value == 'yes';
  }

  Future<String> _settingText(
      DatabaseExecutor e, String key, String fallback) async {
    final rows = await e.query('settings',
        columns: ['v'], where: 'k=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return fallback;
    final value = (rows.first['v'] ?? '').toString().trim();
    return value.isEmpty ? fallback : value;
  }

  Future<void> _repairMissingProductCodes(DatabaseExecutor d) async {
    final autoSku = await _settingBool(d, 'auto_generate_sku', fallback: true);
    final autoBarcode =
        await _settingBool(d, 'auto_generate_barcode', fallback: true);
    if (!autoSku && !autoBarcode) return;
    final rows = await d.rawQuery(
      "SELECT id,sku,external_barcode,internal_barcode FROM products "
      "WHERE TRIM(COALESCE(sku,''))='' OR (TRIM(COALESCE(external_barcode,''))='' AND TRIM(COALESCE(internal_barcode,''))='')",
    );
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final updates = <String, Object?>{};
      if (autoSku && (row['sku'] ?? '').toString().trim().isEmpty) {
        updates['sku'] = await generateUniqueSku(d);
      }
      if (autoBarcode &&
          (row['external_barcode'] ?? '').toString().trim().isEmpty &&
          (row['internal_barcode'] ?? '').toString().trim().isEmpty) {
        updates['external_barcode'] = await generateUniqueBarcode(d);
      }
      if (updates.isNotEmpty) {
        updates['updated_at'] = DateTime.now().toIso8601String();
        await d.update('products', updates, where: 'id=?', whereArgs: [id]);
      }
    }
  }

  Future<void> _ensureBranchStockSeed(DatabaseExecutor d) async {
    await d.execute(
        'CREATE TABLE IF NOT EXISTS branch_stock(product_id TEXT,branch_id TEXT,qty REAL DEFAULT 0,PRIMARY KEY(product_id,branch_id))');
    final ctx = await operationalContext(d);
    final branchId = ctx['branch_id'] ?? 'BR-HQ';
    final rows = await d.rawQuery('''
      SELECT p.id,p.stock FROM products p
      WHERE NOT EXISTS (SELECT 1 FROM branch_stock bs WHERE bs.product_id=p.id)
    ''');
    for (final row in rows) {
      await d.insert(
          'branch_stock',
          {
            'product_id': row['id'],
            'branch_id': branchId,
            'qty': (row['stock'] as num? ?? 0).toDouble(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<double> _branchQty(
      DatabaseExecutor e, String productId, String branchId) async {
    final rows = await e.query('branch_stock',
        columns: ['qty'],
        where: 'product_id=? AND branch_id=?',
        whereArgs: [productId, branchId],
        limit: 1);
    return rows.isEmpty ? 0 : (rows.first['qty'] as num? ?? 0).toDouble();
  }

  Future<void> _changeBranchStock(
      DatabaseExecutor e, String productId, String branchId, double delta,
      {bool updateAggregate = true}) async {
    final current = await _branchQty(e, productId, branchId);
    final next = current + delta;
    if (next < -0.000001)
      throw Exception('Stock cannot become negative at this branch');
    await e.insert(
        'branch_stock',
        {
          'product_id': productId,
          'branch_id': branchId,
          'qty': next < 0 ? 0 : next
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (updateAggregate) {
      await e.rawUpdate(
          'UPDATE products SET stock=MAX(stock+?,0),updated_at=? WHERE id=?',
          [delta, DateTime.now().toIso8601String(), productId]);
    }
  }

  Future<void> _ensureStockLotSeed(DatabaseExecutor d) async {
    await d.execute(
        "CREATE TABLE IF NOT EXISTS stock_lots(id TEXT PRIMARY KEY,product_id TEXT,branch_id TEXT,purchase_item_id INTEGER,batch_no TEXT,expiry_date TEXT,received_qty REAL DEFAULT 0,remaining_qty REAL DEFAULT 0,unit_cost REAL DEFAULT 0,created_at TEXT,status TEXT DEFAULT 'Open')");
    final rows = await d.rawQuery('''
      SELECT bs.product_id,bs.branch_id,bs.qty,p.cost
      FROM branch_stock bs
      JOIN products p ON p.id=bs.product_id
      WHERE bs.qty>0.000001
        AND NOT EXISTS (
          SELECT 1 FROM stock_lots sl
          WHERE sl.product_id=bs.product_id AND sl.branch_id=bs.branch_id
        )
    ''');
    final now = DateTime.now().toIso8601String();
    for (final row in rows) {
      final qty = (row['qty'] as num? ?? 0).toDouble();
      if (qty <= 0) continue;
      await d.insert('stock_lots', {
        'id': _id('LOT'),
        'product_id': row['product_id'],
        'branch_id': row['branch_id'],
        'purchase_item_id': null,
        'batch_no': 'OPENING',
        'expiry_date': null,
        'received_qty': qty,
        'remaining_qty': qty,
        'unit_cost': (row['cost'] as num? ?? 0).toDouble(),
        'created_at': now,
        'status': 'Open',
      });
    }
  }

  String _randomHex(int bytes) {
    final values = List<int>.generate(bytes, (_) => _secureRandom.nextInt(256));
    return values.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _bootstrapSyncIdentity(DatabaseExecutor d) async {
    Future<String> meta(String key) async {
      final rows = await d.query('app_meta',
          columns: ['v'], where: 'k=?', whereArgs: [key], limit: 1);
      return rows.isEmpty ? '' : (rows.first['v'] ?? '').toString();
    }

    var companyId = await meta('sync_company_id');
    if (companyId.isEmpty) {
      companyId = 'CMP-${_randomHex(12)}';
      await d.insert('app_meta', {'k': 'sync_company_id', 'v': companyId},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    var deviceId = await meta('sync_device_id');
    if (deviceId.isEmpty) {
      deviceId = 'DEV-${_randomHex(12)}';
      await d.insert('app_meta', {'k': 'sync_device_id', 'v': deviceId},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    _nodeId = deviceId.replaceAll('DEV-', '').substring(0, 8);
    final ctxRows = await d.query('app_meta',
        where: "k IN ('current_branch_id','current_terminal_id')");
    final ctx = <String, String>{
      for (final r in ctxRows)
        (r['k'] ?? '').toString(): (r['v'] ?? '').toString()
    };
    final now = DateTime.now().toUtc().toIso8601String();
    await d.insert(
        'sync_devices',
        {
          'device_id': deviceId,
          'name': Platform.localHostname.isEmpty
              ? 'This Device'
              : Platform.localHostname,
          'platform': Platform.operatingSystem,
          'branch_id': ctx['current_branch_id'] ?? 'BR-HQ',
          'terminal_id': ctx['current_terminal_id'] ?? 'TERM-LOCAL',
          'registered_at': now,
          'last_seen_at': now,
          'status': 'Local',
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await d.update(
        'sync_devices',
        {
          'last_seen_at': now,
          'branch_id': ctx['current_branch_id'] ?? 'BR-HQ',
          'terminal_id': ctx['current_terminal_id'] ?? 'TERM-LOCAL'
        },
        where: 'device_id=?',
        whereArgs: [deviceId]);
    await d.insert(
        'sync_state',
        {
          'k': 'outbox_sequence',
          'v': (await meta('sync_outbox_sequence')).isEmpty
              ? '0'
              : await meta('sync_outbox_sequence')
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _bootstrapIdentity(DatabaseExecutor d) async {
    final now = DateTime.now().toIso8601String();
    const defaultBranchId = 'BR-HQ';
    const defaultUserId = 'USR-OWNER';
    const defaultTerminalId = 'TERM-LOCAL';
    final hostname =
        Platform.localHostname.isEmpty ? 'This Device' : Platform.localHostname;
    final deviceKey = '${Platform.operatingSystem}-$hostname';

    await d.insert(
      'branches',
      {
        'id': defaultBranchId,
        'code': 'HQ',
        'name': 'Main Branch',
        'address': '',
        'phone': '',
        'active': 1,
        'created_at': now
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await d.insert(
      'users',
      {
        'id': defaultUserId,
        'username': 'owner',
        'display_name': 'Owner',
        'role': 'Owner',
        'pin_hash': '',
        'active': 1,
        'last_login': now
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await d.insert(
      'terminals',
      {
        'id': defaultTerminalId,
        'name': hostname,
        'branch_id': defaultBranchId,
        'device_key': deviceKey,
        'active': 1,
        'last_seen': now
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    var userId = defaultUserId;
    var userRows = await d.query('users',
        columns: ['id'], where: 'id=?', whereArgs: [userId], limit: 1);
    if (userRows.isEmpty) {
      userRows = await d.query('users',
          columns: ['id'],
          where: "username='owner' OR active=1",
          orderBy: "CASE WHEN username='owner' THEN 0 ELSE 1 END",
          limit: 1);
      if (userRows.isNotEmpty) userId = userRows.first['id'].toString();
    }

    var terminalId = defaultTerminalId;
    var terminalRows = await d.query('terminals',
        columns: ['id'], where: 'id=?', whereArgs: [terminalId], limit: 1);
    if (terminalRows.isEmpty) {
      terminalRows = await d.query('terminals',
          columns: ['id'],
          where: 'device_key=?',
          whereArgs: [deviceKey],
          limit: 1);
      if (terminalRows.isNotEmpty)
        terminalId = terminalRows.first['id'].toString();
    }

    await d.insert(
        'user_branches', {'user_id': userId, 'branch_id': defaultBranchId},
        conflictAlgorithm: ConflictAlgorithm.ignore);

    Future<String> validMeta(String key, String table, String fallback) async {
      final meta = await d.query('app_meta',
          columns: ['v'], where: 'k=?', whereArgs: [key], limit: 1);
      final current = meta.isEmpty ? '' : (meta.first['v'] ?? '').toString();
      if (current.isNotEmpty) {
        final exists = await d.query(table,
            columns: ['id'], where: 'id=?', whereArgs: [current], limit: 1);
        if (exists.isNotEmpty) return current;
      }
      await d.insert('app_meta', {'k': key, 'v': fallback},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return fallback;
    }

    final branchId =
        await validMeta('current_branch_id', 'branches', defaultBranchId);
    userId = await validMeta('current_user_id', 'users', userId);
    terminalId =
        await validMeta('current_terminal_id', 'terminals', terminalId);
    await d.update('terminals', {'branch_id': branchId, 'last_seen': now},
        where: 'id=?', whereArgs: [terminalId]);
    await d.insert('user_branches', {'user_id': userId, 'branch_id': branchId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<Map<String, String>> operationalContext(
      [DatabaseExecutor? executor]) async {
    final e = executor ?? db;
    final rows = await e.query('app_meta', where: 'k IN (?,?,?)', whereArgs: [
      'current_branch_id',
      'current_user_id',
      'current_terminal_id'
    ]);
    final values = <String, String>{};
    for (final r in rows) {
      values[r['k'] as String] = (r['v'] as String?) ?? '';
    }
    return {
      'branch_id': values['current_branch_id'] ?? 'BR-HQ',
      'user_id': values['current_user_id'] ?? 'USR-OWNER',
      'terminal_id': values['current_terminal_id'] ?? 'TERM-LOCAL',
    };
  }

  Future<List<Map<String, Object?>>> branches() =>
      db.query('branches', orderBy: 'name');
  Future<List<Map<String, Object?>>> terminals() => db.rawQuery(
      'SELECT t.*,b.name branch_name FROM terminals t LEFT JOIN branches b ON b.id=t.branch_id ORDER BY t.name');
  Future<List<Map<String, Object?>>> users() =>
      db.query('users', orderBy: 'display_name');

  Future<List<String>> userBranchIds(String userId) async {
    final rows = await db.query('user_branches',
        columns: ['branch_id'], where: 'user_id=?', whereArgs: [userId]);
    return rows
        .map((r) => (r['branch_id'] ?? '').toString())
        .where((x) => x.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> productLookupDetails(String productId) async {
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final productRows = await db.rawQuery('''
      SELECT p.*,COALESCE(bs.qty,0) branch_stock
      FROM products p
      LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=?
      WHERE p.id=? LIMIT 1
    ''', [branchId, productId]);
    if (productRows.isEmpty) return {};

    final results = await Future.wait<List<Map<String, Object?>>>([
      db.rawQuery('''
        SELECT COALESCE(SUM(si.qty),0) qty,COALESCE(SUM(si.line_total),0) revenue,
               COUNT(DISTINCT s.id) invoices,MAX(s.created_at) last_date
        FROM sale_items si JOIN sales s ON s.id=si.sale_id
        WHERE si.product_id=? AND s.branch_id=?
      ''', [productId, branchId]),
      db.rawQuery('''
        SELECT COALESCE(SUM(pi.qty),0) qty,COALESCE(SUM(pi.line_total),0) spend,
               COUNT(DISTINCT p.id) purchases,MAX(p.created_at) last_date
        FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id
        WHERE pi.product_id=? AND p.branch_id=?
      ''', [productId, branchId]),
      db.rawQuery('''
        SELECT s.no,s.created_at,c.name customer_name,si.qty,si.unit_price,si.discount,si.tax,si.line_total
        FROM sale_items si JOIN sales s ON s.id=si.sale_id
        LEFT JOIN customers c ON c.id=s.customer_id
        WHERE si.product_id=? AND s.branch_id=?
        ORDER BY s.created_at DESC LIMIT 6
      ''', [productId, branchId]),
      db.rawQuery('''
        SELECT p.no,p.created_at,s.name supplier_name,pi.qty,pi.unit_cost,pi.discount,pi.tax,pi.line_total,pi.batch_no,pi.expiry_date
        FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id
        LEFT JOIN suppliers s ON s.id=p.supplier_id
        WHERE pi.product_id=? AND p.branch_id=?
        ORDER BY p.created_at DESC LIMIT 6
      ''', [productId, branchId]),
      db.rawQuery('''
        SELECT m.created_at,m.qty_change,m.type,m.reference,m.reason,b.name branch_name
        FROM stock_movements m LEFT JOIN branches b ON b.id=m.branch_id
        WHERE m.product_id=? ORDER BY m.created_at DESC LIMIT 8
      ''', [productId]),
      db.rawQuery('''
        SELECT b.name branch_name,COALESCE(bs.qty,0) qty
        FROM branches b LEFT JOIN branch_stock bs ON bs.branch_id=b.id AND bs.product_id=?
        WHERE b.active=1 ORDER BY b.name
      ''', [productId]),
      db.rawQuery('''
        SELECT pi.batch_no,pi.expiry_date,p.no purchase_no,p.created_at
        FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id
        WHERE pi.product_id=? AND pi.expiry_date IS NOT NULL AND TRIM(pi.expiry_date)<>''
        ORDER BY pi.expiry_date ASC LIMIT 8
      ''', [productId]),
      db.rawQuery('''
        SELECT rc.qty,rc.unit,rc.multiplier,cp.name component_name,cp.sku component_sku
        FROM recipe_components rc JOIN products cp ON cp.id=rc.component_product_id
        WHERE rc.parent_product_id=? ORDER BY cp.name
      ''', [productId]),
    ]);

    return {
      'product': {
        ...productRows.first,
        'stock': productRows.first['branch_stock']
      },
      'sales_summary': results[0].first,
      'purchase_summary': results[1].first,
      'recent_sales': results[2],
      'recent_purchases': results[3],
      'movements': results[4],
      'branch_stock': results[5],
      'expiries': results[6],
      'components': results[7],
    };
  }

  Future<void> saveBranch(
      {String? id,
      required String name,
      required String code,
      String address = '',
      String phone = '',
      bool active = true}) async {
    await requirePermission('users', 'manage branches');
    if (id != null &&
        !active &&
        (await operationalContext())['branch_id'] == id)
      throw Exception('Switch to another branch before disabling this branch.');
    if (id == null) {
      final branchCount = _firstIntValue(await db
              .rawQuery('SELECT COUNT(*) FROM branches WHERE active=1')) ??
          0;
      if (branchCount >= 1)
        await LicenseManager.instance
            .requireUsable(entitlement: LicenseEntitlements.multiBranch);
    }
    if (name.trim().isEmpty || code.trim().isEmpty)
      throw Exception('Branch name and code are required');
    final row = {
      'name': name.trim(),
      'code': code.trim().toUpperCase(),
      'address': address.trim(),
      'phone': phone.trim(),
      'active': active ? 1 : 0
    };
    await db.transaction((t) async {
      final branchId = id ?? _id('BR');
      if (id == null) {
        await t.insert('branches', {
          'id': branchId,
          'created_at': DateTime.now().toIso8601String(),
          ...row
        });
      } else {
        await t.update('branches', row, where: 'id=?', whereArgs: [branchId]);
      }
      final record = await _rowById(t, 'branches', branchId);
      await _queueMasterRecordTx(t,
          entityType: 'branch',
          entityId: branchId,
          operation: 'upsert',
          record: record);
      await _audit(
          t,
          id == null ? 'Create branch' : 'Update branch',
          'branch',
          branchId,
          '${row['name']} • ${row['code']} • ${active ? 'active' : 'inactive'}');
    });
  }

  Future<String> saveUser(
      {String? id,
      required String username,
      required String displayName,
      required String role,
      String email = '',
      bool active = true,
      List<String> branchIds = const [],
      List<String> permissions = const []}) async {
    await requirePermission('users', 'manage users');
    if (id == null && active && !LicenseManager.instance.developmentBypass) {
      final state = await LicenseManager.instance.requireUsable();
      final activeUsers = _firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM users WHERE active=1')) ??
          0;
      if (state.maxUsers > 0 && activeUsers >= state.maxUsers)
        throw Exception('License user limit reached (${state.maxUsers}).');
    }
    if (username.trim().isEmpty || displayName.trim().isEmpty)
      throw Exception('Username and display name are required');
    final selectedPermissions = permissions.toSet();
    final defaults = PermissionCatalog.permissionsForRole(role);
    final customPermissions = role != 'Owner' &&
        selectedPermissions.isNotEmpty &&
        !(selectedPermissions.length == defaults.length &&
            selectedPermissions.containsAll(defaults));
    if (customPermissions && !LicenseManager.instance.developmentBypass) {
      await LicenseManager.instance
          .requireUsable(entitlement: LicenseEntitlements.advancedRoles);
    }
    final storedPermissions = customPermissions ? permissions.join(',') : '';
    final uid = id ?? _id('USR');
    await db.transaction((t) async {
      final row = {
        'username': username.trim().toLowerCase(),
        'display_name': displayName.trim(),
        'role': role,
        'email': email.trim(),
        'active': active ? 1 : 0,
        'permissions': storedPermissions
      };
      if (id == null) {
        await t.insert(
            'users', {'id': uid, 'pin_hash': '', 'last_login': null, ...row});
      } else {
        await t.update('users', row, where: 'id=?', whereArgs: [uid]);
        await t.delete('user_branches', where: 'user_id=?', whereArgs: [uid]);
      }
      for (final bid in branchIds) {
        await t.insert('user_branches', {'user_id': uid, 'branch_id': bid},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final scope = storedPermissions.isEmpty
          ? 'role preset'
          : '${selectedPermissions.length} custom permissions';
      await _audit(t, id == null ? 'Create user' : 'Update user', 'user', uid,
          '${displayName.trim()} (@${username.trim().toLowerCase()}) • $role • ${active ? 'active' : 'inactive'} • $scope • ${branchIds.length} branch(es)');
    });
    return uid;
  }

  Future<void> switchBranch(String branchId) async {
    final rows = await db.query('branches',
        where: 'id=? AND active=1', whereArgs: [branchId], limit: 1);
    if (rows.isEmpty) throw Exception('Branch is inactive or missing');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      await t.insert('app_meta', {'k': 'current_branch_id', 'v': branchId},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await t.update(
          'terminals',
          {
            'branch_id': branchId,
            'last_seen': DateTime.now().toIso8601String()
          },
          where: 'id=?',
          whereArgs: [ctx['terminal_id']]);
      await _audit(t, 'Switch branch', 'branch', branchId,
          'Active branch changed on this terminal');
    });
  }

  Future<void> repairIdentity() => _bootstrapIdentity(db);

  Future<Map<String, Object?>> currentIdentity() async {
    final c = await operationalContext();
    final b = await db.query('branches',
        where: 'id=?', whereArgs: [c['branch_id']], limit: 1);
    final u = await db.query('users',
        where: 'id=?', whereArgs: [c['user_id']], limit: 1);
    final t = await db.query('terminals',
        where: 'id=?', whereArgs: [c['terminal_id']], limit: 1);
    return {
      'branch': b.isEmpty ? null : b.first,
      'user': u.isEmpty ? null : u.first,
      'terminal': t.isEmpty ? null : t.first
    };
  }

  Future<bool> currentUserHasPermission(String permission) async {
    final c = await operationalContext();
    final rows = await db.query('users',
        where: 'id=? AND active=1', whereArgs: [c['user_id']], limit: 1);
    if (rows.isEmpty) return false;
    final row = rows.first;
    final role = (row['role'] ?? 'Viewer').toString();
    if (role == 'Owner') return true;
    final raw = (row['permissions'] ?? '').toString().trim();
    if (raw.isNotEmpty)
      return raw.split(',').map((e) => e.trim()).contains(permission);
    return PermissionCatalog.permissionsForRole(role).contains(permission);
  }

  Future<void> requirePermission(String permission, String action) async {
    if (!await currentUserHasPermission(permission))
      throw Exception('You do not have permission to $action.');
  }

  Future<void> _ensureColumn(DatabaseExecutor d, String table, String column,
      String definition) async {
    final info = await d.rawQuery('PRAGMA table_info($table)');
    final exists = info.any((row) => row['name'] == column);
    if (!exists) {
      await d.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  String _id(String prefix) =>
      '$prefix-$_nodeId-${DateTime.now().microsecondsSinceEpoch}-${_secureRandom.nextInt(1 << 20).toRadixString(36)}';

  Future<List<Map<String, Object?>>> products(
      {String search = '', bool activeOnly = false, int limit = 500}) async {
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final clauses = <String>[];
    final args = <Object?>[branchId, branchId];
    if (activeOnly) clauses.add('p.active=1');
    if (search.trim().isNotEmpty) {
      clauses.add(
          '(p.name LIKE ? OR p.sku LIKE ? OR p.external_barcode LIKE ? OR p.internal_barcode LIKE ?)');
      final like = '%${search.trim()}%';
      args.addAll([like, like, like, like]);
    }
    final whereSql = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery('''
      WITH recipe_availability AS (
        SELECT rc.parent_product_id,
               MIN(COALESCE(cbs.qty,0) / NULLIF(rc.qty * rc.multiplier,0)) AS available_qty
        FROM recipe_components rc
        LEFT JOIN branch_stock cbs ON cbs.product_id=rc.component_product_id AND cbs.branch_id=?
        WHERE rc.qty>0 AND rc.multiplier>0
        GROUP BY rc.parent_product_id
      )
      SELECT p.*,
             COALESCE(tp.rate,0) AS tax_rate,
             COALESCE(tp.price_inclusive,p.tax_inclusive,0) AS tax_profile_inclusive,
             CASE WHEN p.product_type IN ('Recipe','Combo') THEN COALESCE(ra.available_qty,0) ELSE COALESCE(bs.qty,0) END AS branch_stock
      FROM products p
      LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=?
      LEFT JOIN tax_profiles tp ON tp.code=p.tax_code AND tp.active=1
      LEFT JOIN recipe_availability ra ON ra.parent_product_id=p.id
      $whereSql
      ORDER BY p.name COLLATE NOCASE
      LIMIT ?
    ''', [...args, limit]);
    return rows
        .map((r) =>
            {...r, 'global_stock': r['stock'], 'stock': r['branch_stock']})
        .toList();
  }

  String _ean13FromBase(String base12) {
    final digits = base12
        .padLeft(12, '0')
        .substring(base12.length > 12 ? base12.length - 12 : 0);
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = int.parse(digits[i]);
      sum += d * (i.isEven ? 1 : 3);
    }
    final check = (10 - (sum % 10)) % 10;
    return '$digits$check';
  }

  Future<List<String>> categories() async {
    await _bootstrapMasterData(db);
    final rows = await db.query('product_categories',
        columns: ['name'], where: 'active=1', orderBy: 'name COLLATE NOCASE');
    return rows
        .map((r) => (r['name'] ?? '').toString())
        .where((x) => x.isNotEmpty)
        .toList();
  }

  Future<List<String>> units() async {
    await _bootstrapMasterData(db);
    final rows = await db.query('product_units',
        columns: ['name'], where: 'active=1', orderBy: 'name COLLATE NOCASE');
    return rows
        .map((r) => (r['name'] ?? '').toString())
        .where((x) => x.isNotEmpty)
        .toList();
  }

  Future<void> addCategory(String value) async {
    final name = value.trim();
    if (name.isEmpty) throw Exception('Category name is required');
    await db.insert('product_categories', {'name': name, 'active': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, Object?>>> categoryStats({String search = ''}) async {
    final like = '%${search.trim()}%';
    return db.rawQuery('''
      SELECT c.id,c.name,c.active,
             SUM(CASE WHEN p.active=1 THEN 1 ELSE 0 END) active_products,
             SUM(CASE WHEN p.id IS NOT NULL AND p.active=0 THEN 1 ELSE 0 END) inactive_products,
             COUNT(p.id) total_products
      FROM product_categories c
      LEFT JOIN products p ON LOWER(TRIM(p.category))=LOWER(TRIM(c.name))
      WHERE (?='' OR c.name LIKE ?)
      GROUP BY c.id,c.name,c.active
      ORDER BY c.active DESC,c.name COLLATE NOCASE
    ''', [search.trim(), like]);
  }

  Future<void> renameCategory(String oldName, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) throw Exception('Category name is required');
    await db.transaction((t) async {
      final exists = await t.query('product_categories',
          where: 'LOWER(name)=LOWER(?) AND LOWER(name)<>LOWER(?)',
          whereArgs: [clean, oldName],
          limit: 1);
      if (exists.isNotEmpty)
        throw Exception('A category with this name already exists');
      await t.update('product_categories', {'name': clean},
          where: 'LOWER(name)=LOWER(?)', whereArgs: [oldName]);
      await t.update('products',
          {'category': clean, 'updated_at': DateTime.now().toIso8601String()},
          where: 'LOWER(category)=LOWER(?)', whereArgs: [oldName]);
      await _audit(
          t, 'Rename category', 'category', oldName, '$oldName → $clean');
    });
  }

  Future<void> setCategoryActive(String name, bool active) async {
    await db.transaction((t) async {
      await t.update('product_categories', {'active': active ? 1 : 0},
          where: 'LOWER(name)=LOWER(?)', whereArgs: [name]);
      if (!active) {
        await t.update('products',
            {'active': 0, 'updated_at': DateTime.now().toIso8601String()},
            where: 'LOWER(category)=LOWER(?)', whereArgs: [name]);
      }
      await _audit(
          t,
          active ? 'Enable category' : 'Disable category',
          'category',
          name,
          active
              ? 'Category enabled; products remain in their current status'
              : 'Category disabled and all products in it were disabled');
    });
  }

  Future<void> addUnit(String value) async {
    final name = value.trim();
    if (name.isEmpty) throw Exception('Unit name is required');
    await db.insert('product_units', {'name': name, 'active': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, Object?>>> recipeComponents(
      String parentProductId) async {
    return db.rawQuery('''
      SELECT rc.*,p.name component_name,p.sku component_sku,p.unit stock_unit,p.cost component_cost
      FROM recipe_components rc
      JOIN products p ON p.id=rc.component_product_id
      WHERE rc.parent_product_id=?
      ORDER BY p.name COLLATE NOCASE
    ''', [parentProductId]);
  }

  Future<void> saveRecipeComponents(
      String parentProductId, List<Map<String, Object?>> components) async {
    await db.transaction((t) async {
      await t.delete('recipe_components',
          where: 'parent_product_id=?', whereArgs: [parentProductId]);
      for (final c in components) {
        final componentId = (c['component_product_id'] ?? '').toString();
        final qty = (c['qty'] as num? ?? 0).toDouble();
        final multiplier = (c['multiplier'] as num? ?? 1).toDouble();
        if (componentId.isEmpty ||
            qty <= 0 ||
            multiplier <= 0 ||
            componentId == parentProductId) continue;
        final componentRows = await t.query('products',
            columns: ['product_type', 'name'],
            where: 'id=?',
            whereArgs: [componentId],
            limit: 1);
        if (componentRows.isEmpty)
          throw Exception('A recipe component no longer exists');
        final componentType =
            (componentRows.first['product_type'] ?? 'Stocked').toString();
        if (componentType != 'Stocked')
          throw Exception(
              'Recipe/Combo components must be Stocked products. ${componentRows.first['name']} is $componentType.');
        await t.insert(
            'recipe_components',
            {
              'parent_product_id': parentProductId,
              'component_product_id': componentId,
              'qty': qty,
              'unit': (c['unit'] ?? '').toString(),
              'multiplier': multiplier,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _audit(t, 'Update recipe components', 'product', parentProductId,
          '${components.length} component rows');
      final rows = await t.query('recipe_components',
          where: 'parent_product_id=?',
          whereArgs: [parentProductId],
          orderBy: 'component_product_id');
      await _enqueueSyncEventTx(t,
          entityType: 'recipe_definition',
          entityId: parentProductId,
          operation: 'replace',
          payload: {
            'schema': 1,
            'parent_product_id': parentProductId,
            'components': rows,
          });
    });
  }

  Future<List<Map<String, Object?>>> branchInventory(String branchId,
      {String search = ''}) async {
    final like = '%${search.trim()}%';
    return db.rawQuery('''
      SELECT p.*,COALESCE(bs.qty,0) branch_stock
      FROM products p
      LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=?
      WHERE p.active=1 AND COALESCE(p.product_type,'Stocked')='Stocked'
        AND (?='' OR p.name LIKE ? OR p.sku LIKE ? OR p.external_barcode LIKE ? OR p.internal_barcode LIKE ?)
      ORDER BY p.name COLLATE NOCASE
      LIMIT 500
    ''', [branchId, search.trim(), like, like, like, like]);
  }

  Future<String> createStockTransfer(
      {required String fromBranchId,
      required String toBranchId,
      required List<Map<String, Object?>> items,
      String notes = ''}) async {
    if (fromBranchId == toBranchId)
      throw Exception('Source and destination branch must be different');
    if (items.isEmpty) throw Exception('Add at least one product to transfer');
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.multiBranch);
    final now = DateTime.now();
    final transferId = _id('TRF');
    final no = 'TR-${now.millisecondsSinceEpoch}';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final fromRows = await t.query('branches',
          where: 'id=? AND active=1', whereArgs: [fromBranchId], limit: 1);
      final toRows = await t.query('branches',
          where: 'id=? AND active=1', whereArgs: [toBranchId], limit: 1);
      if (fromRows.isEmpty || toRows.isEmpty)
        throw Exception('Both branches must be active');
      for (final item in items) {
        final productId = (item['product_id'] ?? item['id'] ?? '').toString();
        final qty = (item['qty'] as num? ?? 0).toDouble();
        if (productId.isEmpty || qty <= 0)
          throw Exception('Transfer quantities must be greater than zero');
      }
      await t.insert('stock_transfers', {
        'id': transferId,
        'no': no,
        'created_at': now.toIso8601String(),
        'from_branch_id': fromBranchId,
        'to_branch_id': toBranchId,
        'status': 'Requested',
        'notes': notes.trim(),
        'user_id': ctx['user_id'],
        'terminal_id': ctx['terminal_id'],
      });
      for (final item in items) {
        await t.insert('stock_transfer_items', {
          'transfer_id': transferId,
          'product_id': (item['product_id'] ?? item['id']).toString(),
          'qty': (item['qty'] as num).toDouble()
        });
      }
      await _audit(t, 'Request stock transfer', 'stock_transfer', transferId,
          '$no • ${items.length} line(s)');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_transfer_txn',
          entityId: transferId,
          operation: 'request',
          payload: {
            'schema': 1,
            'transfer': await _rowById(t, 'stock_transfers', transferId),
            'items': await t.query('stock_transfer_items',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'lots': const <Map<String, Object?>>[],
            'stock_effects': const <Map<String, Object?>>[]
          });
    });
    return no;
  }

  Future<void> sendStockTransfer(String transferId) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.multiBranch);
    await db.transaction((t) async {
      final rows = await t.query('stock_transfers',
          where: 'id=?', whereArgs: [transferId], limit: 1);
      if (rows.isEmpty) throw Exception('Transfer not found');
      final h = rows.first;
      if ((h['status'] ?? '').toString() != 'Requested')
        throw Exception('Only requested transfers can be sent');
      final fromBranch = h['from_branch_id'].toString();
      final ctx = await operationalContext(t);
      final items = await t.query('stock_transfer_items',
          where: 'transfer_id=?', whereArgs: [transferId]);
      for (final item in items) {
        final pid = item['product_id'].toString();
        final qty = (item['qty'] as num? ?? 0).toDouble();
        final available = await _branchQty(t, pid, fromBranch);
        if (available + 0.000001 < qty) {
          final pRows = await t.query('products',
              columns: ['name'], where: 'id=?', whereArgs: [pid], limit: 1);
          throw Exception(
              'Not enough source stock for ${pRows.isEmpty ? 'a product' : pRows.first['name']}');
        }
      }
      await t.delete('stock_transfer_lots',
          where: 'transfer_id=?', whereArgs: [transferId]);
      for (final item in items) {
        final pid = item['product_id'].toString();
        final qty = (item['qty'] as num).toDouble();
        var remaining = qty;
        final lots = await t.rawQuery('''
          SELECT * FROM stock_lots
          WHERE product_id=? AND branch_id=? AND remaining_qty>0.000001
          ORDER BY CASE WHEN expiry_date IS NULL OR TRIM(expiry_date)='' THEN 1 ELSE 0 END,
                   expiry_date ASC,created_at ASC
        ''', [pid, fromBranch]);
        for (final lot in lots) {
          if (remaining <= 0.000001) break;
          final available = (lot['remaining_qty'] as num? ?? 0).toDouble();
          final moved = available < remaining ? available : remaining;
          final left = (available - moved).clamp(0, double.infinity).toDouble();
          await t.update(
              'stock_lots',
              {
                'remaining_qty': left,
                'status': left <= 0.000001 ? 'Depleted' : 'Open'
              },
              where: 'id=?',
              whereArgs: [lot['id']]);
          await t.insert('stock_transfer_lots', {
            'transfer_id': transferId,
            'product_id': pid,
            'batch_no': lot['batch_no'],
            'expiry_date': lot['expiry_date'],
            'qty': moved,
            'unit_cost': lot['unit_cost'],
            'purchase_item_id': lot['purchase_item_id']
          });
          remaining -= moved;
        }
        if (remaining > 0.000001) {
          final productRows = await t.query('products',
              columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
          await t.insert('stock_transfer_lots', {
            'transfer_id': transferId,
            'product_id': pid,
            'batch_no': 'TRANSFER',
            'expiry_date': null,
            'qty': remaining,
            'unit_cost': productRows.isEmpty
                ? 0
                : (productRows.first['cost'] as num? ?? 0),
            'purchase_item_id': null
          });
        }
        await _changeBranchStock(t, pid, fromBranch, -qty,
            updateAggregate: false);
        await t.insert('stock_movements', {
          'created_at': DateTime.now().toIso8601String(),
          'product_id': pid,
          'qty_change': -qty,
          'type': 'Transfer Sent',
          'reference': h['no'],
          'reason': (h['notes'] ?? '').toString(),
          'branch_id': fromBranch,
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await t.update('stock_transfers',
          {'status': 'Sent', 'sent_at': DateTime.now().toIso8601String()},
          where: 'id=?', whereArgs: [transferId]);
      await _audit(t, 'Send stock transfer', 'stock_transfer', transferId,
          '${h['no']} • stock moved to in-transit');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_transfer_txn',
          entityId: transferId,
          operation: 'send',
          payload: {
            'schema': 1,
            'transfer': await _rowById(t, 'stock_transfers', transferId),
            'items': await t.query('stock_transfer_items',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'lots': await t.query('stock_transfer_lots',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Transfer Sent'",
                whereArgs: [h['no']],
                orderBy: 'id')
          });
    });
  }

  Future<void> receiveStockTransfer(String transferId) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.multiBranch);
    await db.transaction((t) async {
      final rows = await t.query('stock_transfers',
          where: 'id=?', whereArgs: [transferId], limit: 1);
      if (rows.isEmpty) throw Exception('Transfer not found');
      final h = rows.first;
      if ((h['status'] ?? '').toString() != 'Sent')
        throw Exception('Only sent transfers can be received');
      final toBranch = h['to_branch_id'].toString();
      final ctx = await operationalContext(t);
      final lots = await t.query('stock_transfer_lots',
          where: 'transfer_id=?', whereArgs: [transferId]);
      final totals = <String, double>{};
      for (final lot in lots) {
        final pid = lot['product_id'].toString();
        final qty = (lot['qty'] as num? ?? 0).toDouble();
        if (qty <= 0) continue;
        await t.insert('stock_lots', {
          'id': _id('LOT'),
          'product_id': pid,
          'branch_id': toBranch,
          'purchase_item_id': lot['purchase_item_id'],
          'batch_no': lot['batch_no'],
          'expiry_date': lot['expiry_date'],
          'received_qty': qty,
          'remaining_qty': qty,
          'unit_cost': lot['unit_cost'],
          'created_at': DateTime.now().toIso8601String(),
          'status': 'Open'
        });
        totals[pid] = (totals[pid] ?? 0) + qty;
      }
      for (final e in totals.entries) {
        await _changeBranchStock(t, e.key, toBranch, e.value,
            updateAggregate: false);
        await t.insert('stock_movements', {
          'created_at': DateTime.now().toIso8601String(),
          'product_id': e.key,
          'qty_change': e.value,
          'type': 'Transfer Received',
          'reference': h['no'],
          'reason': (h['notes'] ?? '').toString(),
          'branch_id': toBranch,
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await t.update(
          'stock_transfers',
          {
            'status': 'Received',
            'received_at': DateTime.now().toIso8601String()
          },
          where: 'id=?',
          whereArgs: [transferId]);
      await _audit(t, 'Receive stock transfer', 'stock_transfer', transferId,
          '${h['no']} • ${totals.length} product(s) received');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_transfer_txn',
          entityId: transferId,
          operation: 'receive',
          payload: {
            'schema': 1,
            'transfer': await _rowById(t, 'stock_transfers', transferId),
            'items': await t.query('stock_transfer_items',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'lots': await t.query('stock_transfer_lots',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Transfer Received'",
                whereArgs: [h['no']],
                orderBy: 'id')
          });
    });
  }

  Future<void> rejectStockTransfer(String transferId) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.multiBranch);
    await db.transaction((t) async {
      final rows = await t.query('stock_transfers',
          where: 'id=?', whereArgs: [transferId], limit: 1);
      if (rows.isEmpty) throw Exception('Transfer not found');
      final h = rows.first;
      final status = (h['status'] ?? '').toString();
      if (status != 'Requested' && status != 'Sent')
        throw Exception('This transfer can no longer be rejected');
      if (status == 'Sent') {
        final fromBranch = h['from_branch_id'].toString();
        final ctx = await operationalContext(t);
        final lots = await t.query('stock_transfer_lots',
            where: 'transfer_id=?', whereArgs: [transferId]);
        final totals = <String, double>{};
        for (final lot in lots) {
          final pid = lot['product_id'].toString();
          final qty = (lot['qty'] as num? ?? 0).toDouble();
          if (qty <= 0) continue;
          await t.insert('stock_lots', {
            'id': _id('LOT'),
            'product_id': pid,
            'branch_id': fromBranch,
            'purchase_item_id': lot['purchase_item_id'],
            'batch_no': lot['batch_no'],
            'expiry_date': lot['expiry_date'],
            'received_qty': qty,
            'remaining_qty': qty,
            'unit_cost': lot['unit_cost'],
            'created_at': DateTime.now().toIso8601String(),
            'status': 'Open'
          });
          totals[pid] = (totals[pid] ?? 0) + qty;
        }
        for (final e in totals.entries) {
          await _changeBranchStock(t, e.key, fromBranch, e.value,
              updateAggregate: false);
          await t.insert('stock_movements', {
            'created_at': DateTime.now().toIso8601String(),
            'product_id': e.key,
            'qty_change': e.value,
            'type': 'Transfer Returned',
            'reference': h['no'],
            'reason': 'Transfer rejected',
            'branch_id': fromBranch,
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id']
          });
        }
      }
      await t.update(
          'stock_transfers',
          {
            'status': 'Rejected',
            'rejected_at': DateTime.now().toIso8601String()
          },
          where: 'id=?',
          whereArgs: [transferId]);
      await _audit(t, 'Reject stock transfer', 'stock_transfer', transferId,
          '${h['no']} • previous status $status');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_transfer_txn',
          entityId: transferId,
          operation: 'reject',
          payload: {
            'schema': 1,
            'transfer': await _rowById(t, 'stock_transfers', transferId),
            'items': await t.query('stock_transfer_items',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'lots': await t.query('stock_transfer_lots',
                where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Transfer Returned'",
                whereArgs: [h['no']],
                orderBy: 'id')
          });
    });
  }

  Future<List<Map<String, Object?>>> stockTransfers({int limit = 200}) async {
    return db.rawQuery('''
      SELECT st.*,fb.name from_branch,tb.name to_branch,
             COUNT(sti.id) line_count,COALESCE(SUM(sti.qty),0) total_qty
      FROM stock_transfers st
      LEFT JOIN branches fb ON fb.id=st.from_branch_id
      LEFT JOIN branches tb ON tb.id=st.to_branch_id
      LEFT JOIN stock_transfer_items sti ON sti.transfer_id=st.id
      GROUP BY st.id
      ORDER BY st.created_at DESC
      LIMIT ?
    ''', [limit]);
  }

  Future<String> generateUniqueSku([DatabaseExecutor? executor]) async {
    final e = executor ?? db;
    final countRows = await e.rawQuery('SELECT COUNT(*) c FROM products');
    var seed = ((countRows.first['c'] as num?) ?? 0).toInt() + 1;
    for (var attempt = 0; attempt < 100000; attempt++) {
      final code = 'SKU-${seed.toString().padLeft(6, '0')}';
      final found = await e.rawQuery(
          'SELECT id FROM products WHERE LOWER(sku)=LOWER(?) LIMIT 1', [code]);
      if (found.isEmpty) return code;
      seed++;
    }
    throw Exception('Could not generate a unique SKU.');
  }

  Future<String> generateUniqueBarcode([DatabaseExecutor? executor]) async {
    final e = executor ?? db;
    var seed = DateTime.now().microsecondsSinceEpoch;
    for (var attempt = 0; attempt < 100; attempt++) {
      final base = (seed % 1000000000000).toString().padLeft(12, '0');
      final code = _ean13FromBase(base);
      final found = await e.rawQuery(
        'SELECT id FROM products WHERE external_barcode=? OR internal_barcode=? LIMIT 1',
        [code, code],
      );
      if (found.isEmpty) return code;
      seed++;
    }
    throw Exception(
        'Could not generate a unique barcode. Please enter one manually.');
  }

  Future<String> saveProduct(Map<String, Object?> v, {String? id}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    if (id != null && v.containsKey('price')) {
      final existingPrice = await db.query('products',
          columns: ['price'], where: 'id=?', whereArgs: [id], limit: 1);
      if (existingPrice.isNotEmpty) {
        final oldPrice = (existingPrice.first['price'] as num? ?? 0).toDouble();
        final newPrice = (v['price'] as num? ?? oldPrice).toDouble();
        if ((oldPrice - newPrice).abs() > 0.000001)
          await requirePermission(
              'edit_prices', 'change product selling prices');
      }
    }
    final now = DateTime.now().toIso8601String();
    var savedId = id ?? '';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final autoSku =
          await _settingBool(t, 'auto_generate_sku', fallback: true);
      final autoBarcode =
          await _settingBool(t, 'auto_generate_barcode', fallback: true);
      if (id == null) {
        final newId = _id('PRD');
        savedId = newId;
        final row = {...v, 'id': newId, 'created_at': now, 'updated_at': now};
        final suppliedSku = (row['sku'] ?? '').toString().trim();
        if (autoSku && suppliedSku.isEmpty) {
          row['sku'] = await generateUniqueSku(t);
        } else if (!autoSku && suppliedSku.isEmpty) {
          row['sku'] = null;
        }
        final suppliedBarcode =
            (row['external_barcode'] ?? '').toString().trim();
        final internalBarcode =
            (row['internal_barcode'] ?? '').toString().trim();
        if (autoBarcode && suppliedBarcode.isEmpty && internalBarcode.isEmpty) {
          row['external_barcode'] = await generateUniqueBarcode(t);
        } else if (!autoBarcode &&
            suppliedBarcode.isEmpty &&
            internalBarcode.isEmpty) {
          row['external_barcode'] = null;
          row['internal_barcode'] = null;
        }
        final category = (row['category'] ?? '').toString().trim();
        final unit = (row['unit'] ?? '').toString().trim();
        row['category'] = category.isEmpty ? 'General' : category;
        row['unit'] = unit.isEmpty ? 'pcs' : unit;
        final newType = (row['product_type'] ?? 'Stocked').toString();
        if (newType != 'Stocked') row['stock'] = 0.0;
        if ((row['lifecycle_status'] ?? 'Active').toString() != 'Active')
          row['active'] = 0;
        await t.insert(
            'product_categories', {'name': row['category'], 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final catState = await t.query('product_categories',
            columns: ['active'],
            where: 'LOWER(name)=LOWER(?)',
            whereArgs: [row['category']],
            limit: 1);
        if (catState.isNotEmpty &&
            (catState.first['active'] as num? ?? 1).toInt() != 1)
          row['active'] = 0;
        await t.insert('product_units', {'name': row['unit'], 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await t.insert('products', row);
        final openingStock = (row['stock'] as num? ?? 0).toDouble();
        await t.insert(
            'branch_stock',
            {
              'product_id': newId,
              'branch_id': ctx['branch_id'],
              'qty': openingStock
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (openingStock != 0) {
          await t.insert('stock_lots', {
            'id': _id('LOT'),
            'product_id': newId,
            'branch_id': ctx['branch_id'],
            'purchase_item_id': null,
            'batch_no': 'OPENING',
            'expiry_date': null,
            'received_qty': openingStock,
            'remaining_qty': openingStock,
            'unit_cost': (row['cost'] as num? ?? 0).toDouble(),
            'created_at': now,
            'status': 'Open',
          });
          await t.insert('stock_movements', {
            'created_at': now,
            'product_id': newId,
            'qty_change': openingStock,
            'type': 'Opening Stock',
            'reference': '',
            'reason': 'Opening stock at product creation',
            'branch_id': ctx['branch_id'],
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id'],
          });
        }
        await _audit(t, 'Create product', 'product', newId, '${row['name']}');
      } else {
        final row = {...v, 'updated_at': now};
        row.remove('stock');
        if (autoSku && (row['sku'] ?? '').toString().trim().isEmpty) {
          row['sku'] = await generateUniqueSku(t);
        } else if (!autoSku && (row['sku'] ?? '').toString().trim().isEmpty) {
          row['sku'] = null;
        }
        final suppliedBarcode =
            (row['external_barcode'] ?? '').toString().trim();
        final internalBarcode =
            (row['internal_barcode'] ?? '').toString().trim();
        if (autoBarcode && suppliedBarcode.isEmpty && internalBarcode.isEmpty) {
          row['external_barcode'] = await generateUniqueBarcode(t);
        } else if (!autoBarcode &&
            suppliedBarcode.isEmpty &&
            internalBarcode.isEmpty) {
          row['external_barcode'] = null;
          row['internal_barcode'] = null;
        }
        final category = (row['category'] ?? '').toString().trim();
        final unit = (row['unit'] ?? '').toString().trim();
        row['category'] = category.isEmpty ? 'General' : category;
        row['unit'] = unit.isEmpty ? 'pcs' : unit;
        await t.insert(
            'product_categories', {'name': row['category'], 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final catState = await t.query('product_categories',
            columns: ['active'],
            where: 'LOWER(name)=LOWER(?)',
            whereArgs: [row['category']],
            limit: 1);
        if (catState.isNotEmpty &&
            (catState.first['active'] as num? ?? 1).toInt() != 1)
          row['active'] = 0;
        await t.insert('product_units', {'name': row['unit'], 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final updateType = (row['product_type'] ?? 'Stocked').toString();
        if ((row['lifecycle_status'] ?? 'Active').toString() != 'Active')
          row['active'] = 0;
        if (updateType != 'Stocked') {
          row['min_stock'] = 0.0;
          row['target_stock'] = 0.0;
          row['track_batch'] = 0;
          row['track_expiry'] = 0;
        }
        await t.update('products', row, where: 'id=?', whereArgs: [id]);
        await _audit(t, 'Update product', 'product', id, '${row['name']}');
      }
      final syncRecord = await _rowById(t, 'products', savedId);
      final openingStock =
          id == null ? (syncRecord['stock'] as num? ?? 0).toDouble() : 0.0;
      syncRecord.remove('stock');
      await _queueMasterRecordTx(
        t,
        entityType: 'product',
        entityId: savedId,
        operation: 'upsert',
        record: syncRecord,
        extras: openingStock == 0
            ? const {}
            : {
                'opening_stock': openingStock,
                'opening_branch_id': ctx['branch_id'],
                'opening_cost': (syncRecord['cost'] as num? ?? 0).toDouble(),
              },
      );
    });
    return savedId;
  }

  Future<Map<String, Object?>> productUsageSummary(String productId) async {
    final refs = <String, int>{};
    Future<void> count(String table, String column) async {
      final rows = await db.rawQuery(
          'SELECT COUNT(*) c FROM $table WHERE $column=?', [productId]);
      refs['$table.$column'] = (rows.first['c'] as num? ?? 0).toInt();
    }

    for (final entry in const <List<String>>[
      ['sale_items', 'product_id'],
      ['purchase_items', 'product_id'],
      ['stock_movements', 'product_id'],
      ['sale_return_items', 'product_id'],
      ['purchase_return_items', 'product_id'],
      ['purchase_order_items', 'product_id'],
      ['stock_lots', 'product_id'],
      ['stock_transfer_items', 'product_id'],
      ['stock_count_items', 'product_id'],
      ['recipe_components', 'parent_product_id'],
      ['recipe_components', 'component_product_id'],
    ]) {
      await count(entry[0], entry[1]);
    }
    final branchRows = await db.rawQuery(
        'SELECT COALESCE(SUM(ABS(qty)),0) q FROM branch_stock WHERE product_id=?',
        [productId]);
    final stockMagnitude = (branchRows.first['q'] as num? ?? 0).toDouble();
    final used = refs.values.any((x) => x > 0) || stockMagnitude > .000001;
    return {
      'used': used,
      'references': refs,
      'stock_magnitude': stockMagnitude
    };
  }

  Future<String> deleteOrArchiveProduct(String productId,
      {String reason = ''}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('delete_products', 'delete or archive products');
    final usage = await productUsageSummary(productId);
    final used = usage['used'] == true;
    final now = DateTime.now().toIso8601String();
    return db.transaction((t) async {
      final rows = await t.query('products',
          where: 'id=?', whereArgs: [productId], limit: 1);
      if (rows.isEmpty) throw Exception('Product not found');
      final name = '${rows.first['name'] ?? productId}';
      if (!used) {
        await t.delete('recipe_components',
            where: 'parent_product_id=? OR component_product_id=?',
            whereArgs: [productId, productId]);
        await t.delete('branch_stock',
            where: 'product_id=?', whereArgs: [productId]);
        await t.delete('products', where: 'id=?', whereArgs: [productId]);
        await _audit(t, 'Delete product', 'product', productId,
            '$name permanently deleted${reason.trim().isEmpty ? '' : ' • ${reason.trim()}'}');
        await _enqueueSyncEventTx(t,
            entityType: 'product',
            entityId: productId,
            operation: 'delete',
            payload: {'schema': 1, 'id': productId});
        return 'Product permanently deleted.';
      }
      await t.update(
          'products',
          {
            'active': 0,
            'lifecycle_status': 'Archived',
            'updated_at': now,
          },
          where: 'id=?',
          whereArgs: [productId]);
      await _audit(t, 'Archive product', 'product', productId,
          '$name archived because transaction/stock history exists${reason.trim().isEmpty ? '' : ' • ${reason.trim()}'}');
      final record = await _rowById(t, 'products', productId);
      record.remove('stock');
      await _queueMasterRecordTx(t,
          entityType: 'product',
          entityId: productId,
          operation: 'upsert',
          record: record);
      return 'Product has history, so it was archived instead of deleted.';
    });
  }

  Future<void> setProductLifecycle({
    required String productId,
    required String status,
    String? replacementProductId,
    String demandFamily = '',
    bool inheritPredecessorHistory = true,
  }) async {
    const allowed = {'Active', 'Discontinued', 'Replaced', 'Archived'};
    if (!allowed.contains(status))
      throw Exception('Invalid product lifecycle status');
    if (replacementProductId == productId)
      throw Exception('A product cannot replace itself');
    if (status == 'Replaced' &&
        (replacementProductId == null || replacementProductId.isEmpty)) {
      throw Exception('Choose the replacement product first');
    }
    await db.transaction((t) async {
      if (replacementProductId != null && replacementProductId.isNotEmpty) {
        final replacement = await t.query('products',
            where: 'id=?', whereArgs: [replacementProductId], limit: 1);
        if (replacement.isEmpty)
          throw Exception('Replacement product not found');
      }
      await t.update(
          'products',
          {
            'lifecycle_status': status,
            'replacement_product_id': replacementProductId?.isEmpty == true
                ? null
                : replacementProductId,
            'demand_family':
                demandFamily.trim().isEmpty ? null : demandFamily.trim(),
            'inherit_predecessor_history': inheritPredecessorHistory ? 1 : 0,
            'active': status == 'Active' ? 1 : 0,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id=?',
          whereArgs: [productId]);
      await _audit(t, 'Update product lifecycle', 'product', productId,
          'Status $status${replacementProductId == null || replacementProductId.isEmpty ? '' : ' • replacement $replacementProductId'}');
      final record = await _rowById(t, 'products', productId);
      record.remove('stock');
      await _queueMasterRecordTx(t,
          entityType: 'product',
          entityId: productId,
          operation: 'upsert',
          record: record);
    });
  }

  Future<Map<String, int>> bulkUpdateProducts({
    required List<String> productIds,
    bool? active,
    bool? sellable,
    bool? purchasable,
    String? category,
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    if (productIds.isEmpty) return {'updated': 0, 'deleted': 0, 'archived': 0};
    final ids = productIds.toSet().toList();
    final now = DateTime.now().toIso8601String();
    var updated = 0;
    await db.transaction((t) async {
      for (final id in ids) {
        final changes = <String, Object?>{'updated_at': now};
        if (active != null) {
          changes['active'] = active ? 1 : 0;
          changes['lifecycle_status'] = active ? 'Active' : 'Archived';
        }
        if (sellable != null) changes['sellable'] = sellable ? 1 : 0;
        if (purchasable != null) changes['purchasable'] = purchasable ? 1 : 0;
        if (category != null && category.trim().isNotEmpty)
          changes['category'] = category.trim();
        final count =
            await t.update('products', changes, where: 'id=?', whereArgs: [id]);
        if (count == 0) continue;
        updated += count;
        await _audit(
            t,
            'Bulk edit product',
            'product',
            id,
            'Bulk update${active == null ? '' : active ? ' • enabled' : ' • disabled'}'
                '${sellable == null ? '' : sellable ? ' • sellable' : ' • not sellable'}'
                '${purchasable == null ? '' : purchasable ? ' • purchasable' : ' • not purchasable'}'
                '${category == null ? '' : ' • category ${category.trim()}'}');
        final record = await _rowById(t, 'products', id);
        record.remove('stock');
        await _queueMasterRecordTx(t,
            entityType: 'product',
            entityId: id,
            operation: 'upsert',
            record: record);
      }
    });
    return {'updated': updated, 'deleted': 0, 'archived': 0};
  }

  Future<Map<String, int>> bulkDeleteOrArchiveProducts(
      List<String> productIds) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('delete_products', 'delete or archive products');
    if (productIds.isEmpty) return {'updated': 0, 'deleted': 0, 'archived': 0};
    var deleted = 0;
    var archived = 0;
    for (final id in productIds.toSet()) {
      final usage = await productUsageSummary(id);
      final used = usage['used'] == true;
      final now = DateTime.now().toIso8601String();
      await db.transaction((t) async {
        final rows =
            await t.query('products', where: 'id=?', whereArgs: [id], limit: 1);
        if (rows.isEmpty) return;
        final name = '${rows.first['name'] ?? id}';
        if (!used) {
          await t.delete('recipe_components',
              where: 'parent_product_id=? OR component_product_id=?',
              whereArgs: [id, id]);
          await t
              .delete('branch_stock', where: 'product_id=?', whereArgs: [id]);
          await t.delete('products', where: 'id=?', whereArgs: [id]);
          await _audit(t, 'Bulk delete product', 'product', id,
              '$name permanently deleted by bulk action');
          await _enqueueSyncEventTx(t,
              entityType: 'product',
              entityId: id,
              operation: 'delete',
              payload: {'schema': 1, 'id': id});
          deleted++;
        } else {
          await t.update('products',
              {'active': 0, 'lifecycle_status': 'Archived', 'updated_at': now},
              where: 'id=?', whereArgs: [id]);
          await _audit(t, 'Bulk archive product', 'product', id,
              '$name archived by bulk action because history/stock exists');
          final record = await _rowById(t, 'products', id);
          record.remove('stock');
          await _queueMasterRecordTx(t,
              entityType: 'product',
              entityId: id,
              operation: 'upsert',
              record: record);
          archived++;
        }
      });
    }
    return {'updated': 0, 'deleted': deleted, 'archived': archived};
  }

  Future<void> setProductActive(String productId, bool active) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await db.transaction((t) async {
      await t.update(
          'products',
          {
            'active': active ? 1 : 0,
            'lifecycle_status': active ? 'Active' : 'Archived',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id=?',
          whereArgs: [productId]);
      await _audit(t, active ? 'Enable product' : 'Disable product', 'product',
          productId, active ? 'Product enabled' : 'Product disabled');
      final record = await _rowById(t, 'products', productId);
      record.remove('stock');
      await _queueMasterRecordTx(t,
          entityType: 'product',
          entityId: productId,
          operation: 'upsert',
          record: record);
    });
  }

  Future<void> adjustStock(
      String productId, double change, String reason) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('stock_adjust', 'adjust stock');
    final adjustmentId = _id('ADJ');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final product = await t.query('products',
          columns: ['id', 'cost'],
          where: 'id=?',
          whereArgs: [productId],
          limit: 1);
      if (product.isEmpty) throw Exception('Product not found');
      final current = await _branchQty(t, productId, ctx['branch_id']!);
      if (current + change < 0) throw Exception('Stock cannot become negative');
      final now = DateTime.now().toIso8601String();
      final cost = (product.first['cost'] as num? ?? 0).toDouble();
      if (change < 0) {
        await _consumeLots(t, productId, ctx['branch_id']!, -change);
      } else if (change > 0) {
        await t.insert('stock_lots', {
          'id': _id('LOT'),
          'product_id': productId,
          'branch_id': ctx['branch_id'],
          'purchase_item_id': null,
          'batch_no': 'ADJ',
          'expiry_date': null,
          'received_qty': change,
          'remaining_qty': change,
          'unit_cost': cost,
          'created_at': now,
          'status': 'Open',
        });
      }
      await _changeBranchStock(t, productId, ctx['branch_id']!, change);
      await t.insert('stock_movements', {
        'created_at': now,
        'product_id': productId,
        'qty_change': change,
        'type': 'Adjustment',
        'reference': adjustmentId,
        'reason': reason,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      await _audit(
          t, 'Stock adjustment', 'product', productId, '$change • $reason');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_adjustment_txn',
          entityId: adjustmentId,
          operation: 'post',
          payload: {
            'schema': 1,
            'product_id': productId,
            'branch_id': ctx['branch_id'],
            'qty_change': change,
            'reason': reason,
            'unit_cost': cost,
            'created_at': now,
          });
    });
  }

  Future<List<Map<String, Object?>>> customers(
      {String search = '', bool activeOnly = false, int limit = 500}) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (activeOnly) clauses.add('c.active=1');
    final searchTerms = search
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty);
    for (final term in searchTerms) {
      clauses.add("""(
        LOWER(COALESCE(c.name,'')) LIKE ? OR
        LOWER(COALESCE(c.phone,'')) LIKE ? OR
        LOWER(COALESCE(c.whatsapp,'')) LIKE ? OR
        LOWER(COALESCE(c.email,'')) LIKE ? OR
        LOWER(COALESCE(c.address,'')) LIKE ? OR
        LOWER(COALESCE(c.id,'')) LIKE ?
      )""");
      final like = '%$term%';
      args.addAll([like, like, like, like, like, like]);
    }
    final whereSql = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.rawQuery('''
      SELECT c.*, COALESCE(od.overdue_balance,0) overdue_balance
      FROM customers c
      LEFT JOIN (
        SELECT customer_id,SUM(balance) overdue_balance
        FROM sales
        WHERE balance>0 AND due_date IS NOT NULL AND datetime(due_date)<datetime('now')
        GROUP BY customer_id
      ) od ON od.customer_id=c.id
      $whereSql
      ORDER BY c.name COLLATE NOCASE
      LIMIT ?
    ''', [...args, limit]);
  }

  Future<String> saveCustomer(Map<String, Object?> values, {String? id}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    final customerId = id ?? _id('CUS');
    await db.transaction((t) async {
      if (id == null) {
        await t.insert('customers', {'id': customerId, ...values});
      } else {
        await t.update('customers', values, where: 'id=?', whereArgs: [id]);
      }
      final record = await _rowById(t, 'customers', customerId);
      record.remove('balance');
      record.remove('credit_balance');
      await _queueMasterRecordTx(t,
          entityType: 'customer',
          entityId: customerId,
          operation: 'upsert',
          record: record);
    });
    return customerId;
  }

  Future<Map<String, Object?>?> customerById(String id) async {
    final rows =
        await db.query('customers', where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> customerGroups(
      {bool activeOnly = false}) async {
    final where = activeOnly ? 'WHERE active=1' : '';
    return db.rawQuery(
        'SELECT * FROM customer_groups $where ORDER BY name COLLATE NOCASE');
  }

  Future<String> saveCustomerGroup(
      {String? id,
      required String name,
      required double defaultDiscountPct,
      String notes = '',
      bool active = true}) async {
    final groupId = id ?? _id('CGR');
    final values = <String, Object?>{
      'name': name.trim(),
      'default_discount_pct': defaultDiscountPct.clamp(0, 100),
      'notes': notes.trim(),
      'active': active ? 1 : 0,
    };
    await db.transaction((t) async {
      if (id == null)
        await t.insert('customer_groups', {'id': groupId, ...values});
      else
        await t
            .update('customer_groups', values, where: 'id=?', whereArgs: [id]);
      final record = await _rowById(t, 'customer_groups', groupId);
      await _queueMasterRecordTx(t,
          entityType: 'customer_group',
          entityId: groupId,
          operation: 'upsert',
          record: record);
    });
    return groupId;
  }

  Future<void> saveCustomerGroupRule(
      {String? id,
      required String groupId,
      required String scopeType,
      required String scopeValue,
      required double discountPct,
      bool active = true}) async {
    final ruleId = id ?? _id('CGRR');
    final values = <String, Object?>{
      'group_id': groupId,
      'scope_type': scopeType,
      'scope_value': scopeValue.trim(),
      'discount_pct': discountPct.clamp(0, 100),
      'active': active ? 1 : 0,
    };
    await db.transaction((t) async {
      if (id == null)
        await t
            .insert('customer_group_discount_rules', {'id': ruleId, ...values});
      else
        await t.update('customer_group_discount_rules', values,
            where: 'id=?', whereArgs: [id]);
      final record = await _rowById(t, 'customer_group_discount_rules', ruleId);
      await _queueMasterRecordTx(t,
          entityType: 'customer_group_rule',
          entityId: ruleId,
          operation: 'upsert',
          record: record);
    });
  }

  Future<List<Map<String, Object?>>> customerGroupRules(String groupId) =>
      db.query('customer_group_discount_rules',
          where: 'group_id=?',
          whereArgs: [groupId],
          orderBy: 'scope_type,scope_value');

  Future<double> customerDiscountPctForProduct(
      String customerId, Map<String, Object?> product) async {
    final rows = await db.rawQuery('''
      SELECT c.group_id,g.default_discount_pct
      FROM customers c LEFT JOIN customer_groups g ON g.id=c.group_id AND g.active=1
      WHERE c.id=? LIMIT 1
    ''', [customerId]);
    if (rows.isEmpty || rows.first['group_id'] == null) return 0;
    final groupId = rows.first['group_id'].toString();
    var pct = (rows.first['default_discount_pct'] as num? ?? 0).toDouble();
    final productId = (product['id'] ?? '').toString();
    final category = (product['category'] ?? '').toString();
    final rules = await db.query('customer_group_discount_rules',
        where: 'group_id=? AND active=1', whereArgs: [groupId]);
    for (final r in rules) {
      final type = (r['scope_type'] ?? '').toString();
      final value = (r['scope_value'] ?? '').toString();
      if (type == 'Category' && value.toLowerCase() == category.toLowerCase())
        pct = (r['discount_pct'] as num? ?? 0).toDouble();
    }
    for (final r in rules) {
      final type = (r['scope_type'] ?? '').toString();
      final value = (r['scope_value'] ?? '').toString();
      if (type == 'Product' && value == productId)
        pct = (r['discount_pct'] as num? ?? 0).toDouble();
    }
    return pct.clamp(0, 100).toDouble();
  }

  Future<Map<String, Object?>> customerProductPricing(
      String customerId, String productId) async {
    final pRows = await db.query('products',
        where: 'id=?', whereArgs: [productId], limit: 1);
    if (pRows.isEmpty)
      return {'discount_pct': 0.0, 'last_price': null, 'last_discount': null};
    final pct = await customerDiscountPctForProduct(customerId, pRows.first);
    final last = await db.rawQuery('''
      SELECT si.unit_price,si.discount,si.qty,s.created_at FROM sale_items si
      JOIN sales s ON s.id=si.sale_id WHERE s.customer_id=? AND si.product_id=? AND COALESCE(s.status,'Completed')<>'Cancelled'
      ORDER BY s.created_at DESC LIMIT 1
    ''', [customerId, productId]);
    return {
      'discount_pct': pct,
      'last_price': last.isEmpty ? null : last.first['unit_price'],
      'last_discount': last.isEmpty ? null : last.first['discount'],
      'last_sale_at': last.isEmpty ? null : last.first['created_at']
    };
  }

  Future<List<Map<String, Object?>>> customerStatement(String customerId,
      {DateTime? from, DateTime? to}) async {
    String rangeSql(String column) {
      var sql = '';
      if (from != null) sql += ' AND datetime($column)>=datetime(?)';
      if (to != null) sql += ' AND datetime($column)<datetime(?)';
      return sql;
    }

    List<Object?> args(String id) {
      final out = <Object?>[id];
      if (from != null) out.add(from!.toIso8601String());
      if (to != null) {
        final next =
            DateTime(to!.year, to!.month, to!.day).add(const Duration(days: 1));
        out.add(next.toIso8601String());
      }
      return out;
    }

    final sales = await db.rawQuery('''
      SELECT created_at date,no reference,'Invoice' type,total debit,0.0 credit,balance
      FROM sales
      WHERE customer_id=? AND COALESCE(status,'Completed')<>'Cancelled'${rangeSql('created_at')}
    ''', args(customerId));
    final payments = await db.rawQuery('''
      SELECT created_at date,COALESCE(NULLIF(reference,''),id) reference,'Payment' type,0.0 debit,amount credit,0.0 balance
      FROM payments
      WHERE party_type='Customer' AND party_id=? AND amount>0${rangeSql('created_at')}
    ''', args(customerId));
    final returns = await db.rawQuery('''
      SELECT r.created_at date,r.no reference,'Sales Return' type,0.0 debit,MAX(r.total-COALESCE(r.refund_amount,0),0) credit,0.0 balance
      FROM sales_returns r
      JOIN sales s ON s.id=r.sale_id
      WHERE s.customer_id=? AND COALESCE(r.status,'Posted')<>'Cancelled'${rangeSql('r.created_at')}
    ''', args(customerId));
    final adjustments = await db.rawQuery('''
      SELECT created_at date,COALESCE(NULLIF(reference,''),no) reference,kind type,
        CASE WHEN kind IN ('Opening Receivable','Customer Debit Note') THEN amount ELSE 0 END debit,
        CASE WHEN kind IN ('Opening Credit','Customer Credit Note') THEN amount ELSE 0 END credit,
        balance
      FROM account_adjustments
      WHERE party_type='Customer' AND party_id=?${rangeSql('created_at')}
    ''', args(customerId));
    final rows = <Map<String, Object?>>[
      ...sales,
      ...payments,
      ...returns,
      ...adjustments
    ];
    rows.sort((a, b) =>
        (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()));
    return rows;
  }

  Future<List<Map<String, Object?>>> supplierStatement(String supplierId,
      {DateTime? from, DateTime? to}) async {
    String rangeSql(String column) {
      var sql = '';
      if (from != null) sql += ' AND datetime($column)>=datetime(?)';
      if (to != null) sql += ' AND datetime($column)<datetime(?)';
      return sql;
    }

    List<Object?> args(String id) {
      final out = <Object?>[id];
      if (from != null) out.add(from!.toIso8601String());
      if (to != null) {
        final next =
            DateTime(to!.year, to!.month, to!.day).add(const Duration(days: 1));
        out.add(next.toIso8601String());
      }
      return out;
    }

    final purchases = await db.rawQuery('''
      SELECT created_at date,COALESCE(NULLIF(document_no,''),no) reference,'Purchase' type,total debit,0.0 credit,balance
      FROM purchases
      WHERE supplier_id=? AND COALESCE(status,'Received')<>'Cancelled'${rangeSql('created_at')}
    ''', args(supplierId));
    final payments = await db.rawQuery('''
      SELECT created_at date,COALESCE(NULLIF(reference,''),id) reference,'Payment' type,0.0 debit,amount credit,0.0 balance
      FROM payments
      WHERE party_type='Supplier' AND party_id=? AND amount>0${rangeSql('created_at')}
    ''', args(supplierId));
    final returns = await db.rawQuery('''
      SELECT r.created_at date,r.no reference,'Purchase Return' type,0.0 debit,MAX(r.total-COALESCE(r.refund_amount,0),0) credit,0.0 balance
      FROM purchase_returns r
      JOIN purchases p ON p.id=r.purchase_id
      WHERE p.supplier_id=? AND COALESCE(r.status,'Posted')<>'Cancelled'${rangeSql('r.created_at')}
    ''', args(supplierId));
    final adjustments = await db.rawQuery('''
      SELECT created_at date,COALESCE(NULLIF(reference,''),no) reference,kind type,
        CASE WHEN kind IN ('Opening Payable','Supplier Credit Note') THEN amount ELSE 0 END debit,
        CASE WHEN kind IN ('Opening Advance','Supplier Debit Note') THEN amount ELSE 0 END credit,
        balance
      FROM account_adjustments
      WHERE party_type='Supplier' AND party_id=?${rangeSql('created_at')}
    ''', args(supplierId));
    final rows = <Map<String, Object?>>[
      ...purchases,
      ...payments,
      ...returns,
      ...adjustments
    ];
    rows.sort((a, b) =>
        (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()));
    return rows;
  }

  Future<List<Map<String, Object?>>> openCustomerInvoices(String customerId) =>
      db.rawQuery('''
    SELECT id,no,created_at,due_date,total,paid,balance,'Sale' document_type,COALESCE(due_date,created_at) sort_date FROM sales
    WHERE customer_id=? AND balance>0.000001 AND COALESCE(status,'Completed')<>'Cancelled'
    UNION ALL
    SELECT id,no,created_at,due_date,amount total,MAX(amount-balance,0) paid,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date
    FROM account_adjustments
    WHERE party_type='Customer' AND party_id=? AND balance>0.000001 AND status='Posted'
    ORDER BY sort_date,created_at
  ''', [customerId, customerId]);

  Future<List<Map<String, Object?>>> openSupplierBills(String supplierId) =>
      db.rawQuery('''
    SELECT id,no,document_no,created_at,due_date,total,paid,balance,'Purchase' document_type,COALESCE(due_date,created_at) sort_date FROM purchases
    WHERE supplier_id=? AND balance>0.000001 AND COALESCE(status,'Received')<>'Cancelled'
    UNION ALL
    SELECT id,no,'' document_no,created_at,due_date,amount total,MAX(amount-balance,0) paid,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date
    FROM account_adjustments
    WHERE party_type='Supplier' AND party_id=? AND balance>0.000001 AND status='Posted'
    ORDER BY sort_date,created_at
  ''', [supplierId, supplierId]);

  Future<List<Map<String, Object?>>> suppliers(
      {String search = '', bool activeOnly = false, int limit = 500}) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (activeOnly) clauses.add('s.active=1');
    final searchTerms = search
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty);
    for (final term in searchTerms) {
      clauses.add("""(
        LOWER(COALESCE(s.name,'')) LIKE ? OR
        LOWER(COALESCE(s.phone,'')) LIKE ? OR
        LOWER(COALESCE(s.whatsapp,'')) LIKE ? OR
        LOWER(COALESCE(s.email,'')) LIKE ? OR
        LOWER(COALESCE(s.address,'')) LIKE ? OR
        LOWER(COALESCE(s.id,'')) LIKE ?
      )""");
      final like = '%$term%';
      args.addAll([like, like, like, like, like, like]);
    }
    final whereSql = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.rawQuery('''
      SELECT s.*, COALESCE(od.overdue_balance,0) overdue_balance
      FROM suppliers s
      LEFT JOIN (
        SELECT supplier_id,SUM(balance) overdue_balance
        FROM purchases
        WHERE balance>0 AND due_date IS NOT NULL AND datetime(due_date)<datetime('now')
        GROUP BY supplier_id
      ) od ON od.supplier_id=s.id
      $whereSql
      ORDER BY s.name COLLATE NOCASE
      LIMIT ?
    ''', [...args, limit]);
  }

  Future<String> saveSupplier(Map<String, Object?> values, {String? id}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    final supplierId = id ?? _id('SUP');
    await db.transaction((t) async {
      if (id == null) {
        await t.insert('suppliers', {'id': supplierId, ...values});
      } else {
        await t.update('suppliers', values, where: 'id=?', whereArgs: [id]);
      }
      final record = await _rowById(t, 'suppliers', supplierId);
      record.remove('balance');
      record.remove('credit_balance');
      await _queueMasterRecordTx(t,
          entityType: 'supplier',
          entityId: supplierId,
          operation: 'upsert',
          record: record);
    });
    return supplierId;
  }

  Future<String> postSale({
    required List<Map<String, Object?>> items,
    String? customerId,
    required double discount,
    required double deliveryCharge,
    required double otherCharge,
    required double paid,
    required String paymentMethod,
    List<Map<String, Object?>>? tenders,
    String notes = '',
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    if (items.isEmpty) throw Exception('Cart is empty');
    if (discount < 0 || deliveryCharge < 0 || otherCharge < 0 || paid < 0)
      throw Exception('Discount, charges and payment cannot be negative');
    final now = DateTime.now();
    final id = _id('SAL');
    final prefix = await _settingText(db, 'sale_prefix', 'S');
    final no = '$prefix-${now.millisecondsSinceEpoch}';
    final canOverridePrices = await currentUserHasPermission('edit_prices');

    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      double subtotal = 0;
      final componentRequirements = <String, double>{};
      for (final x in items) {
        final pid = x['id'] as String;
        final qty = (x['qty'] as num).toDouble();
        final price = (x['price'] as num).toDouble();
        final lineDiscount = (x['line_discount'] as num? ?? 0)
            .toDouble()
            .clamp(0, double.infinity);
        if (qty <= 0) throw Exception('Quantity must be greater than zero');
        if (price < 0) throw Exception('Selling price cannot be negative');
        if (lineDiscount > qty * price)
          throw Exception('Item discount cannot exceed the line value');
        final rows = await t.query(
          'products',
          columns: [
            'active',
            'sellable',
            'name',
            'cost',
            'price',
            'product_type'
          ],
          where: 'id=?',
          whereArgs: [pid],
          limit: 1,
        );
        if (rows.isEmpty) throw Exception('Product no longer exists');
        if ((rows.first['active'] as num? ?? 0).toInt() != 1) {
          throw Exception('${rows.first['name']} is inactive');
        }
        if ((rows.first['sellable'] as num? ?? 1).toInt() != 1) {
          throw Exception('${rows.first['name']} is not marked as sellable');
        }
        final masterPrice = (rows.first['price'] as num? ?? price).toDouble();
        if (!canOverridePrices && (masterPrice - price).abs() > 0.000001) {
          throw Exception(
              'You do not have permission to override the selling price of ${rows.first['name']}.');
        }
        final type = (rows.first['product_type'] ?? 'Stocked').toString();
        if (type == 'Recipe' || type == 'Combo') {
          final components = await t.query('recipe_components',
              where: 'parent_product_id=?', whereArgs: [pid]);
          if (components.isEmpty)
            throw Exception(
                '${rows.first['name']} has no recipe/combo components configured');
          for (final c in components) {
            final componentId = c['component_product_id'].toString();
            final needed = qty *
                (c['qty'] as num? ?? 0).toDouble() *
                (c['multiplier'] as num? ?? 1).toDouble();
            componentRequirements[componentId] =
                (componentRequirements[componentId] ?? 0) + needed;
            final available =
                await _branchQty(t, componentId, ctx['branch_id']!);
            if (available + 0.000001 < needed)
              throw Exception(
                  'Not enough component stock for ${rows.first['name']}');
          }
        } else if (type == 'Stocked') {
          final stock = await _branchQty(t, pid, ctx['branch_id']!);
          if (stock < qty)
            throw Exception('Not enough stock for ${rows.first['name']}');
        }
        subtotal += qty * price;
      }

      for (final requirement in componentRequirements.entries) {
        final available =
            await _branchQty(t, requirement.key, ctx['branch_id']!);
        if (available + 0.000001 < requirement.value) {
          final componentRows = await t.query('products',
              columns: ['name'],
              where: 'id=?',
              whereArgs: [requirement.key],
              limit: 1);
          final componentName = componentRows.isEmpty
              ? 'a recipe component'
              : componentRows.first['name'];
          throw Exception(
              'Not enough $componentName stock for all recipe/combo items in this sale');
        }
      }

      final taxTotal = items.fold<double>(
          0, (sum, x) => sum + (x['tax_amount'] as num? ?? 0).toDouble());
      final itemsTotal = items.fold<double>(0, (sum, x) {
        final gross =
            (x['qty'] as num).toDouble() * (x['price'] as num).toDouble();
        final lineDiscount = (x['line_discount'] as num? ?? 0).toDouble();
        final lineTax = (x['tax_amount'] as num? ?? 0).toDouble();
        final inclusive = ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        return sum + (gross - lineDiscount + (inclusive ? 0 : lineTax));
      });
      final total = (itemsTotal - discount + deliveryCharge + otherCharge)
          .clamp(0, double.infinity)
          .toDouble();
      final safePaid = paid.clamp(0, total).toDouble();
      final balance = (total - safePaid).clamp(0, double.infinity).toDouble();

      Map<String, Object?>? customer;
      if (customerId != null) {
        final rows = await t.query('customers',
            where: 'id=?', whereArgs: [customerId], limit: 1);
        if (rows.isEmpty) throw Exception('Customer no longer exists');
        customer = rows.first;
      }

      if (balance > 0) {
        if (customer == null)
          throw Exception('Select a customer for a credit sale');
        if ((customer['credit_allowed'] as num? ?? 0).toInt() != 1) {
          throw Exception('Credit is not enabled for this customer');
        }
        final existing = (customer['balance'] as num? ?? 0).toDouble();
        final limit = (customer['credit_limit'] as num? ?? 0).toDouble();
        if (limit > 0 && existing + balance > limit) {
          throw Exception('Customer credit limit would be exceeded');
        }
      }
      final customerTerms = (customer?['terms_days'] as num? ?? 0).toInt();
      final dueDate = balance > 0
          ? now.add(Duration(days: customerTerms)).toIso8601String()
          : null;

      await t.insert('sales', {
        'id': id,
        'no': no,
        'created_at': now.toIso8601String(),
        'due_date': dueDate,
        'customer_id': customerId,
        'subtotal': subtotal,
        'discount': discount,
        'tax': taxTotal,
        'delivery_charge': deliveryCharge,
        'other_charge': otherCharge,
        'total': total,
        'paid': safePaid,
        'balance': balance,
        'payment_method': paymentMethod,
        'status': balance > 0 ? 'Credit' : 'Completed',
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });

      for (final x in items) {
        final qty = (x['qty'] as num).toDouble();
        final price = (x['price'] as num).toDouble();
        final pid = x['id'] as String;
        final lineDiscount = (x['line_discount'] as num? ?? 0).toDouble();
        final lineTax = (x['tax_amount'] as num? ?? 0).toDouble();
        final inclusive = ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        final lineTotal =
            (qty * price - lineDiscount + (inclusive ? 0 : lineTax))
                .clamp(0, double.infinity)
                .toDouble();
        final fresh = await t.query('products',
            columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
        final cost = (fresh.first['cost'] as num? ?? 0).toDouble();
        await t.insert('sale_items', {
          'sale_id': id,
          'product_id': pid,
          'name': x['name'],
          'qty': qty,
          'unit_price': price,
          'discount': lineDiscount,
          'cost': cost,
          'tax': lineTax,
          'tax_inclusive': inclusive ? 1 : 0,
          'line_total': lineTotal,
        });
        final typeRows = await t.query('products',
            columns: ['product_type'],
            where: 'id=?',
            whereArgs: [pid],
            limit: 1);
        final productType =
            (typeRows.first['product_type'] ?? 'Stocked').toString();
        if (productType == 'Recipe' || productType == 'Combo') {
          final components = await t.query('recipe_components',
              where: 'parent_product_id=?', whereArgs: [pid]);
          for (final c in components) {
            final componentId = c['component_product_id'].toString();
            final used = qty *
                (c['qty'] as num? ?? 0).toDouble() *
                (c['multiplier'] as num? ?? 1).toDouble();
            await _consumeLots(t, componentId, ctx['branch_id']!, used);
            await _changeBranchStock(t, componentId, ctx['branch_id']!, -used);
            await t.insert('stock_movements', {
              'created_at': now.toIso8601String(),
              'product_id': componentId,
              'qty_change': -used,
              'type': '$productType Consumption',
              'reference': no,
              'reason': 'Used by ${x['name']}',
              'branch_id': ctx['branch_id'],
              'terminal_id': ctx['terminal_id'],
              'user_id': ctx['user_id'],
            });
          }
        } else if (productType == 'Stocked') {
          await _consumeLots(t, pid, ctx['branch_id']!, qty);
          await _changeBranchStock(t, pid, ctx['branch_id']!, -qty);
          await t.insert('stock_movements', {
            'created_at': now.toIso8601String(),
            'product_id': pid,
            'qty_change': -qty,
            'type': 'Sale',
            'reference': no,
            'reason': 'POS sale',
            'branch_id': ctx['branch_id'],
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id'],
          });
        }
      }

      if (balance > 0 && customerId != null) {
        await t.rawUpdate('UPDATE customers SET balance=balance+? WHERE id=?',
            [balance, customerId]);
      }
      if (safePaid > 0) {
        final tenderRows = (tenders == null || tenders.isEmpty)
            ? <Map<String, Object?>>[
                {
                  'method': paymentMethod,
                  'amount': safePaid,
                  'tendered': safePaid,
                  'change_due': 0.0,
                  'reference': ''
                }
              ]
            : tenders;
        var remainingPaid = safePaid;
        for (final td in tenderRows) {
          if (remainingPaid <= 0.000001) break;
          final requested = (td['amount'] as num? ?? 0)
              .toDouble()
              .clamp(0, double.infinity)
              .toDouble();
          final applied = requested > remainingPaid ? remainingPaid : requested;
          if (applied <= 0) continue;
          final method = (td['method'] ?? paymentMethod).toString();
          final tendered = (td['tendered'] as num? ?? applied).toDouble();
          final changeDue = (td['change_due'] as num? ?? 0)
              .toDouble()
              .clamp(0, double.infinity)
              .toDouble();
          final ref = (td['reference'] ?? '').toString();
          final payId = _id('PAY');
          await t.insert('payments', {
            'id': payId,
            'created_at': now.toIso8601String(),
            'party_type': 'Customer',
            'party_id': customerId,
            'document_type': 'Sale',
            'document_id': id,
            'amount': applied,
            'method': method,
            'reference': ref.isEmpty ? no : ref,
            'notes': 'Payment received with sale',
            'branch_id': ctx['branch_id'],
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id'],
          });
          await t.insert('payment_allocations', {
            'payment_id': payId,
            'document_type': 'Sale',
            'document_id': id,
            'allocated_amount': applied,
            'created_at': now.toIso8601String()
          });
          await t.insert('sale_tenders', {
            'sale_id': id,
            'method': method,
            'amount': applied,
            'tendered': tendered,
            'change_due': changeDue,
            'reference': ref
          });
          remainingPaid -= applied;
        }
      }
      await _audit(t, 'Create sale', 'sale', id,
          '$no • total $total • paid $safePaid • balance $balance');
      final saleRecord = await _rowById(t, 'sales', id);
      final saleItems = await t.query('sale_items',
          where: 'sale_id=?', whereArgs: [id], orderBy: 'id');
      final saleTenders = await t.query('sale_tenders',
          where: 'sale_id=?', whereArgs: [id], orderBy: 'id');
      final paymentRows = await t.query('payments',
          where: "document_type='Sale' AND document_id=?",
          whereArgs: [id],
          orderBy: 'created_at,id');
      final paymentIds = paymentRows
          .map((e) => (e['id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final allocationRows = <Map<String, Object?>>[];
      for (final paymentId in paymentIds) {
        allocationRows.addAll(await t.query('payment_allocations',
            where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'id'));
      }
      final movements = await t.query('stock_movements',
          where: 'reference=? AND branch_id=?',
          whereArgs: [no, ctx['branch_id']],
          orderBy: 'id');
      await _enqueueSyncEventTx(t,
          entityType: 'sale_txn',
          entityId: id,
          operation: 'post',
          payload: {
            'schema': 1,
            'sale': saleRecord,
            'items': saleItems,
            'tenders': saleTenders,
            'payments': paymentRows,
            'allocations': allocationRows,
            'stock_effects': movements,
          });
    });
    return no;
  }

  Future<String> receiveCustomerPayment({
    required String customerId,
    required double amount,
    required String method,
    String reference = '',
    Map<String, double>? allocations,
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    if (amount <= 0) throw Exception('Payment must be greater than zero');
    final paymentId = _id('PAY');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final customerRows = await t.query('customers',
          where: 'id=?', whereArgs: [customerId], limit: 1);
      if (customerRows.isEmpty) throw Exception('Customer not found');
      var remaining = amount;
      var applied = 0.0;
      final openDocs = await t.rawQuery('''
        SELECT id,balance,'Sale' document_type,COALESCE(due_date,created_at) sort_date FROM sales
        WHERE customer_id=? AND balance>0.000001 AND COALESCE(status,'Completed')<>'Cancelled'
        UNION ALL
        SELECT id,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date FROM account_adjustments
        WHERE party_type='Customer' AND party_id=? AND balance>0.000001 AND status='Posted'
        ORDER BY sort_date
      ''', [customerId, customerId]);
      final requested = allocations ?? const <String, double>{};
      for (final doc in openDocs) {
        if (remaining <= 0.000001) break;
        final id = doc['id'].toString();
        final docBalance = (doc['balance'] as num? ?? 0).toDouble();
        final wanted = allocations == null ? remaining : (requested[id] ?? 0);
        if (wanted <= 0) continue;
        final allocation =
            [wanted, docBalance, remaining].reduce((a, b) => a < b ? a : b);
        if (allocation <= 0) continue;
        final docType = (doc['document_type'] ?? 'Sale').toString();
        if (docType == 'Adjustment') {
          await t.rawUpdate(
              "UPDATE account_adjustments SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Settled' ELSE status END WHERE id=?",
              [allocation, allocation, id]);
        } else {
          await t.rawUpdate(
              'UPDATE sales SET paid=paid+?,balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN ? ELSE ? END WHERE id=?',
              [allocation, allocation, allocation, 'Completed', 'Credit', id]);
        }
        await t.insert('payment_allocations', {
          'payment_id': paymentId,
          'document_type': docType,
          'document_id': id,
          'allocated_amount': allocation,
          'created_at': DateTime.now().toIso8601String()
        });
        applied += allocation;
        remaining -= allocation;
      }
      final credit = remaining.clamp(0, double.infinity).toDouble();
      await t.rawUpdate(
          'UPDATE customers SET balance=MAX(balance-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
          [applied, credit, customerId]);
      await t.insert('payments', {
        'id': paymentId,
        'created_at': DateTime.now().toIso8601String(),
        'party_type': 'Customer',
        'party_id': customerId,
        'document_type':
            credit > 0 ? 'Account Payment + Credit' : 'Account Payment',
        'document_id': '',
        'amount': amount,
        'method': method,
        'reference': reference,
        'notes': credit > 0
            ? 'Customer payment; ${credit.toStringAsFixed(3)} left as account credit'
            : 'Customer account payment',
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      await _audit(t, 'Customer payment', 'customer', customerId,
          'Amount $amount • applied $applied • credit $credit • $method');
      final payment = await _rowById(t, 'payments', paymentId);
      final allocationRows = await t.query('payment_allocations',
          where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'id');
      await _enqueueSyncEventTx(t,
          entityType: 'customer_payment_txn',
          entityId: paymentId,
          operation: 'post',
          payload: {
            'schema': 1,
            'payment': payment,
            'allocations': allocationRows,
            'party_id': customerId,
            'applied_amount': applied,
            'credit_amount': credit,
          });
    });
    return paymentId;
  }

  Future<String> holdSale(
      {required List<Map<String, Object?>> items,
      String? customerId,
      double billDiscount = 0,
      double deliveryCharge = 0,
      double otherCharge = 0,
      String notes = ''}) async {
    if (items.isEmpty) throw Exception('Cart is empty');
    final id = _id('HOLD');
    final ctx = await operationalContext();
    await db.transaction((t) async {
      await t.insert('held_sales', {
        'id': id,
        'created_at': DateTime.now().toIso8601String(),
        'customer_id': customerId,
        'bill_discount': billDiscount,
        'delivery_charge': deliveryCharge,
        'other_charge': otherCharge,
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      });
      for (final x in items) {
        await t.insert('held_sale_items', {
          'held_sale_id': id,
          'product_id': x['id'],
          'qty': x['qty'],
          'price': x['price'],
          'line_discount': x['line_discount'] ?? 0
        });
      }
      await _audit(t, 'Hold sale', 'held_sale', id, '${items.length} line(s)');
      await _enqueueSyncEventTx(t,
          entityType: 'held_sale_txn',
          entityId: id,
          operation: 'upsert',
          payload: {
            'schema': 1,
            'hold': await _rowById(t, 'held_sales', id),
            'items': await t.query('held_sale_items',
                where: 'held_sale_id=?', whereArgs: [id], orderBy: 'id')
          });
    });
    return id;
  }

  Future<List<Map<String, Object?>>> heldSales() async {
    final ctx = await operationalContext();
    return db.rawQuery(
        '''SELECT h.*,c.name customer_name,(SELECT COUNT(*) FROM held_sale_items hi WHERE hi.held_sale_id=h.id) line_count FROM held_sales h LEFT JOIN customers c ON c.id=h.customer_id WHERE h.branch_id=? ORDER BY h.created_at DESC''',
        [ctx['branch_id']]);
  }

  Future<Map<String, Object?>> heldSaleDetail(String id) async {
    final headers =
        await db.query('held_sales', where: 'id=?', whereArgs: [id], limit: 1);
    if (headers.isEmpty) throw Exception('Held sale not found');
    final items = await db.rawQuery(
        '''SELECT hi.*,p.name,p.sku,p.category,p.unit,p.cost,p.stock,p.product_type,p.tax_code,p.tax_inclusive,tp.rate tax_rate,tp.price_inclusive tax_profile_inclusive FROM held_sale_items hi JOIN products p ON p.id=hi.product_id LEFT JOIN tax_profiles tp ON tp.code=p.tax_code WHERE hi.held_sale_id=?''',
        [id]);
    return {'header': headers.first, 'items': items};
  }

  Future<void> deleteHeldSale(String id) async {
    await db.transaction((t) async {
      await t
          .delete('held_sale_items', where: 'held_sale_id=?', whereArgs: [id]);
      await t.delete('held_sales', where: 'id=?', whereArgs: [id]);
      await _enqueueSyncEventTx(t,
          entityType: 'held_sale_txn',
          entityId: id,
          operation: 'delete',
          payload: {'schema': 1, 'deleted': true});
    });
  }

  Future<String> postPurchase({
    required String supplierId,
    required List<Map<String, Object?>> items,
    String documentNo = '',
    double freight = 0,
    double otherCharges = 0,
    double paid = 0,
    String paymentMethod = 'Cash',
    String notes = '',
    String? purchaseOrderId,
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    if (items.isEmpty) throw Exception('Purchase has no items');
    if (freight < 0 || otherCharges < 0 || paid < 0) {
      throw Exception('Freight, other charges and payment cannot be negative');
    }
    final now = DateTime.now();
    final id = _id('PUR');
    final prefix = await _settingText(db, 'purchase_prefix', 'P');
    final no = '$prefix-${now.millisecondsSinceEpoch}';

    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final supplierRows = await t.query('suppliers',
          where: 'id=?', whereArgs: [supplierId], limit: 1);
      if (supplierRows.isEmpty) throw Exception('Supplier not found');

      double subtotal = 0;
      double discountTotal = 0;
      double taxTotal = 0;
      double itemsTotal = 0;
      for (final x in items) {
        final qty = (x['qty'] as num).toDouble();
        final unitCost = (x['unit_cost'] as num).toDouble();
        final discount = (x['discount'] as num? ?? 0).toDouble();
        final lineTax =
            (x['tax_amount'] as num? ?? 0).toDouble().clamp(0, double.infinity);
        final inclusive = ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        if (qty <= 0)
          throw Exception('Purchase quantity must be greater than zero');
        if (unitCost < 0 || discount < 0)
          throw Exception('Unit cost and discount cannot be negative');
        final gross = qty * unitCost;
        if (discount > gross)
          throw Exception('Line discount cannot exceed the line amount');
        subtotal += gross;
        discountTotal += discount;
        taxTotal += lineTax;
        itemsTotal += gross - discount + (inclusive ? 0 : lineTax);
      }
      final total = (itemsTotal + freight + otherCharges)
          .clamp(0, double.infinity)
          .toDouble();
      final safePaid = paid.clamp(0, total).toDouble();
      final balance = (total - safePaid).clamp(0, double.infinity).toDouble();
      final supplierTerms =
          (supplierRows.first['terms_days'] as num? ?? 0).toInt();
      final dueDate = balance > 0
          ? now.add(Duration(days: supplierTerms)).toIso8601String()
          : null;

      await t.insert('purchases', {
        'id': id,
        'no': no,
        'created_at': now.toIso8601String(),
        'due_date': dueDate,
        'supplier_id': supplierId,
        'document_no': documentNo,
        'subtotal': subtotal,
        'discount': discountTotal,
        'tax': taxTotal,
        'freight': freight,
        'other_charges': otherCharges,
        'total': total,
        'paid': safePaid,
        'balance': balance,
        'payment_method': paymentMethod,
        'status': balance > 0 ? 'Partially Paid' : 'Received',
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
        'purchase_order_id': purchaseOrderId,
      });

      for (final x in items) {
        final pid = x['id'] as String;
        final qty = (x['qty'] as num).toDouble();
        final unitCost = (x['unit_cost'] as num).toDouble();
        final discount = (x['discount'] as num? ?? 0).toDouble();
        final lineTax =
            (x['tax_amount'] as num? ?? 0).toDouble().clamp(0, double.infinity);
        final inclusive = ((x['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        final gross = qty * unitCost;
        final netBeforeTax =
            (gross - discount).clamp(0, double.infinity).toDouble();
        final netLine = (netBeforeTax + (inclusive ? 0 : lineTax))
            .clamp(0, double.infinity)
            .toDouble();
        final effectiveUnitCost = qty > 0 ? netBeforeTax / qty : unitCost;

        final productRows = await t.query(
          'products',
          columns: ['stock', 'cost', 'name', 'product_type', 'purchasable'],
          where: 'id=?',
          whereArgs: [pid],
          limit: 1,
        );
        if (productRows.isEmpty)
          throw Exception('A purchase product no longer exists');
        if ((productRows.first['purchasable'] as num? ?? 1).toInt() != 1) {
          throw Exception(
              '${productRows.first['name']} is not marked as purchasable');
        }
        final productType =
            (productRows.first['product_type'] ?? 'Stocked').toString();
        final oldStock = (productRows.first['stock'] as num? ?? 0).toDouble();
        final oldCost = (productRows.first['cost'] as num? ?? 0).toDouble();
        final newStock = oldStock + qty;
        final weightedCost = newStock <= 0
            ? effectiveUnitCost
            : ((oldStock * oldCost) + (qty * effectiveUnitCost)) / newStock;

        final purchaseItemId = await t.insert('purchase_items', {
          'purchase_id': id,
          'product_id': pid,
          'name': x['name'],
          'qty': qty,
          'unit_cost': unitCost,
          'discount': discount,
          'tax': lineTax,
          'tax_inclusive': inclusive ? 1 : 0,
          'line_total': netLine,
          'batch_no': x['batch_no'] ?? '',
          'expiry_date': x['expiry_date'],
          'purchase_order_item_id': x['purchase_order_item_id'],
        });
        if (productType == 'Stocked') {
          await t.insert('stock_lots', {
            'id': _id('LOT'),
            'product_id': pid,
            'branch_id': ctx['branch_id'],
            'purchase_item_id': purchaseItemId,
            'batch_no': (x['batch_no'] ?? '').toString(),
            'expiry_date': x['expiry_date'],
            'received_qty': qty,
            'remaining_qty': qty,
            'unit_cost': effectiveUnitCost,
            'created_at': now.toIso8601String(),
            'status': 'Open',
          });
          await _changeBranchStock(t, pid, ctx['branch_id']!, qty);
          await t.update('products',
              {'cost': weightedCost, 'updated_at': now.toIso8601String()},
              where: 'id=?', whereArgs: [pid]);
          await t.insert('stock_movements', {
            'created_at': now.toIso8601String(),
            'product_id': pid,
            'qty_change': qty,
            'type': 'Purchase',
            'reference': no,
            'reason': documentNo.isEmpty
                ? 'Purchase receipt'
                : 'Supplier invoice $documentNo',
            'branch_id': ctx['branch_id'],
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id'],
          });
        } else {
          await t.update('products',
              {'cost': effectiveUnitCost, 'updated_at': now.toIso8601String()},
              where: 'id=?', whereArgs: [pid]);
        }
      }

      if (balance > 0) {
        await t.rawUpdate('UPDATE suppliers SET balance=balance+? WHERE id=?',
            [balance, supplierId]);
      }
      if (safePaid > 0) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': now.toIso8601String(),
          'party_type': 'Supplier',
          'party_id': supplierId,
          'document_type': 'Purchase',
          'document_id': id,
          'amount': safePaid,
          'method': paymentMethod,
          'reference': no,
          'notes': 'Payment made with purchase',
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id'],
        });
      }
      if (purchaseOrderId != null && purchaseOrderId.trim().isNotEmpty) {
        for (final x in items) {
          final poItemId = (x['purchase_order_item_id'] as num?)?.toInt();
          if (poItemId == null) continue;
          final qty = (x['qty'] as num).toDouble();
          await t.rawUpdate(
            'UPDATE purchase_order_items SET received_qty=MIN(ordered_qty,received_qty+?) WHERE id=? AND purchase_order_id=?',
            [qty, poItemId, purchaseOrderId],
          );
        }
        final remainingRows = await t.rawQuery(
          'SELECT COALESCE(SUM(MAX(ordered_qty-received_qty,0)),0) remaining FROM purchase_order_items WHERE purchase_order_id=?',
          [purchaseOrderId],
        );
        final remaining =
            (remainingRows.first['remaining'] as num? ?? 0).toDouble();
        final receivedRows = await t.rawQuery(
          'SELECT COALESCE(SUM(received_qty),0) received FROM purchase_order_items WHERE purchase_order_id=?',
          [purchaseOrderId],
        );
        final received =
            (receivedRows.first['received'] as num? ?? 0).toDouble();
        final status = remaining <= 0.000001
            ? 'Received'
            : (received > 0 ? 'Partially Received' : 'Ordered');
        await t.update('purchase_orders', {'status': status},
            where: 'id=?', whereArgs: [purchaseOrderId]);
        await _enqueueSyncEventTx(t,
            entityType: 'purchase_order_state',
            entityId: purchaseOrderId,
            operation: 'receive_state',
            payload: {
              'schema': 1,
              'order': await _rowById(t, 'purchase_orders', purchaseOrderId),
              'items': await t.query('purchase_order_items',
                  where: 'purchase_order_id=?',
                  whereArgs: [purchaseOrderId],
                  orderBy: 'id')
            });
      }
      await _audit(t, 'Create purchase', 'purchase', id,
          '$no • total $total • paid $safePaid • balance $balance');
      final purchaseRecord = await _rowById(t, 'purchases', id);
      final purchaseItems = await t.query('purchase_items',
          where: 'purchase_id=?', whereArgs: [id], orderBy: 'id');
      final paymentRows = await t.query('payments',
          where: "document_type='Purchase' AND document_id=?",
          whereArgs: [id],
          orderBy: 'created_at,id');
      final paymentIds = paymentRows
          .map((e) => (e['id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
      final allocationRows = <Map<String, Object?>>[];
      for (final paymentId in paymentIds) {
        allocationRows.addAll(await t.query('payment_allocations',
            where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'id'));
      }
      final movements = await t.query('stock_movements',
          where: 'reference=? AND branch_id=?',
          whereArgs: [no, ctx['branch_id']],
          orderBy: 'id');
      final lots = <Map<String, Object?>>[];
      for (final item in purchaseItems) {
        final itemId = (item['id'] as num?)?.toInt();
        if (itemId != null)
          lots.addAll(await t.query('stock_lots',
              where: 'purchase_item_id=?',
              whereArgs: [itemId],
              orderBy: 'created_at,id'));
      }
      final productCosts = <String, double>{};
      for (final item in purchaseItems) {
        final pid = (item['product_id'] ?? '').toString();
        if (pid.isEmpty || productCosts.containsKey(pid)) continue;
        final rows = await t.query('products',
            columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
        if (rows.isNotEmpty)
          productCosts[pid] = (rows.first['cost'] as num? ?? 0).toDouble();
      }
      await _enqueueSyncEventTx(t,
          entityType: 'purchase_txn',
          entityId: id,
          operation: 'post',
          payload: {
            'schema': 1,
            'purchase': purchaseRecord,
            'items': purchaseItems,
            'payments': paymentRows,
            'allocations': allocationRows,
            'stock_effects': movements,
            'lots': lots,
            'product_costs': productCosts,
          });
    });
    return no;
  }

  Future<String> paySupplier({
    required String supplierId,
    required double amount,
    required String method,
    String reference = '',
    Map<String, double>? allocations,
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    if (amount <= 0) throw Exception('Payment must be greater than zero');
    final paymentId = _id('PAY');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final supplierRows = await t.query('suppliers',
          where: 'id=?', whereArgs: [supplierId], limit: 1);
      if (supplierRows.isEmpty) throw Exception('Supplier not found');
      var remaining = amount;
      var applied = 0.0;
      final openDocs = await t.rawQuery('''
        SELECT id,balance,'Purchase' document_type,COALESCE(due_date,created_at) sort_date FROM purchases
        WHERE supplier_id=? AND balance>0.000001 AND COALESCE(status,'Received')<>'Cancelled'
        UNION ALL
        SELECT id,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date FROM account_adjustments
        WHERE party_type='Supplier' AND party_id=? AND balance>0.000001 AND status='Posted'
        ORDER BY sort_date
      ''', [supplierId, supplierId]);
      final requested = allocations ?? const <String, double>{};
      for (final doc in openDocs) {
        if (remaining <= 0.000001) break;
        final id = doc['id'].toString();
        final docBalance = (doc['balance'] as num? ?? 0).toDouble();
        final wanted = allocations == null ? remaining : (requested[id] ?? 0);
        if (wanted <= 0) continue;
        final allocation =
            [wanted, docBalance, remaining].reduce((a, b) => a < b ? a : b);
        if (allocation <= 0) continue;
        final docType = (doc['document_type'] ?? 'Purchase').toString();
        if (docType == 'Adjustment') {
          await t.rawUpdate(
              "UPDATE account_adjustments SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Settled' ELSE status END WHERE id=?",
              [allocation, allocation, id]);
        } else {
          await t.rawUpdate(
              'UPDATE purchases SET paid=paid+?,balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN ? ELSE ? END WHERE id=?',
              [
                allocation,
                allocation,
                allocation,
                'Received',
                'Partially Paid',
                id
              ]);
        }
        await t.insert('payment_allocations', {
          'payment_id': paymentId,
          'document_type': docType,
          'document_id': id,
          'allocated_amount': allocation,
          'created_at': DateTime.now().toIso8601String()
        });
        applied += allocation;
        remaining -= allocation;
      }
      final credit = remaining.clamp(0, double.infinity).toDouble();
      await t.rawUpdate(
          'UPDATE suppliers SET balance=MAX(balance-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
          [applied, credit, supplierId]);
      await t.insert('payments', {
        'id': paymentId,
        'created_at': DateTime.now().toIso8601String(),
        'party_type': 'Supplier',
        'party_id': supplierId,
        'document_type':
            credit > 0 ? 'Account Payment + Credit' : 'Account Payment',
        'document_id': '',
        'amount': amount,
        'method': method,
        'reference': reference,
        'notes': credit > 0
            ? 'Supplier payment; ${credit.toStringAsFixed(3)} left as account credit'
            : 'Supplier account payment',
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      await _audit(t, 'Supplier payment', 'supplier', supplierId,
          'Amount $amount • applied $applied • credit $credit • $method');
      final payment = await _rowById(t, 'payments', paymentId);
      final allocationRows = await t.query('payment_allocations',
          where: 'payment_id=?', whereArgs: [paymentId], orderBy: 'id');
      await _enqueueSyncEventTx(t,
          entityType: 'supplier_payment_txn',
          entityId: paymentId,
          operation: 'post',
          payload: {
            'schema': 1,
            'payment': payment,
            'allocations': allocationRows,
            'party_id': supplierId,
            'applied_amount': applied,
            'credit_amount': credit,
          });
    });
    return paymentId;
  }

  Future<List<Map<String, Object?>>> unappliedPayments(
      {String partyType = 'All'}) async {
    final args = <Object?>[];
    var where =
        "p.amount>0 AND (p.document_type LIKE 'Account Payment%' OR p.document_type='Account Receipt')";
    if (partyType != 'All') {
      where += ' AND p.party_type=?';
      args.add(partyType);
    }
    return db.rawQuery('''
      SELECT q.* FROM (
        SELECT p.*,COALESCE(c.name,s.name,'') party_name,
          MAX(p.amount-COALESCE((SELECT SUM(pa.allocated_amount) FROM payment_allocations pa WHERE pa.payment_id=p.id),0),0) unapplied_amount
        FROM payments p
        LEFT JOIN customers c ON p.party_type='Customer' AND c.id=p.party_id
        LEFT JOIN suppliers s ON p.party_type='Supplier' AND s.id=p.party_id
        WHERE $where
      ) q
      WHERE q.unapplied_amount>0.000001
      ORDER BY q.created_at ASC,q.id
    ''', args);
  }

  Future<void> allocateUnappliedPayment(
      String paymentId, Map<String, double> allocations) async {
    await requirePermission(
        'accounting_adjustments', 'Allocate unapplied payments');
    await db.transaction((t) async {
      final paymentRows = await t.query('payments',
          where: 'id=?', whereArgs: [paymentId], limit: 1);
      if (paymentRows.isEmpty) throw Exception('Payment not found');
      final payment = paymentRows.first;
      final partyType = (payment['party_type'] ?? '').toString();
      final partyId = (payment['party_id'] ?? '').toString();
      if (partyType != 'Customer' && partyType != 'Supplier')
        throw Exception(
            'Only customer and supplier account payments can be allocated');
      final allocatedRows = await t.rawQuery(
          'SELECT COALESCE(SUM(allocated_amount),0) total FROM payment_allocations WHERE payment_id=?',
          [paymentId]);
      var remaining = ((payment['amount'] as num? ?? 0).toDouble() -
              (allocatedRows.first['total'] as num? ?? 0).toDouble())
          .clamp(0, double.infinity)
          .toDouble();
      if (remaining <= 0.000001)
        throw Exception('This payment is already fully allocated');
      var applied = 0.0;
      final docs = partyType == 'Customer' ? await t.rawQuery('''
        SELECT id,balance,'Sale' document_type FROM sales WHERE customer_id=? AND balance>0.000001 AND COALESCE(status,'Completed')<>'Cancelled'
        UNION ALL
        SELECT id,balance,'Adjustment' document_type FROM account_adjustments WHERE party_type='Customer' AND party_id=? AND balance>0.000001 AND status='Posted'
      ''', [partyId, partyId]) : await t.rawQuery('''
        SELECT id,balance,'Purchase' document_type FROM purchases WHERE supplier_id=? AND balance>0.000001 AND COALESCE(status,'Received')<>'Cancelled'
        UNION ALL
        SELECT id,balance,'Adjustment' document_type FROM account_adjustments WHERE party_type='Supplier' AND party_id=? AND balance>0.000001 AND status='Posted'
      ''', [partyId, partyId]);
      final byId = <String, Map<String, Object?>>{
        for (final d in docs) d['id'].toString(): d
      };
      for (final e in allocations.entries) {
        if (remaining <= 0.000001) break;
        final doc = byId[e.key];
        if (doc == null) continue;
        final wanted = e.value.clamp(0, double.infinity).toDouble();
        final docBalance = (doc['balance'] as num? ?? 0).toDouble();
        final amount =
            [wanted, docBalance, remaining].reduce((a, b) => a < b ? a : b);
        if (amount <= 0) continue;
        final docType = (doc['document_type'] ?? '').toString();
        if (docType == 'Sale') {
          await t.rawUpdate(
              "UPDATE sales SET paid=paid+?,balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Completed' ELSE 'Credit' END WHERE id=?",
              [amount, amount, amount, e.key]);
        } else if (docType == 'Purchase') {
          await t.rawUpdate(
              "UPDATE purchases SET paid=paid+?,balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Received' ELSE 'Partially Paid' END WHERE id=?",
              [amount, amount, amount, e.key]);
        } else {
          await t.rawUpdate(
              "UPDATE account_adjustments SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Settled' ELSE status END WHERE id=?",
              [amount, amount, e.key]);
        }
        await t.insert('payment_allocations', {
          'payment_id': paymentId,
          'document_type': docType,
          'document_id': e.key,
          'allocated_amount': amount,
          'created_at': DateTime.now().toIso8601String()
        });
        remaining -= amount;
        applied += amount;
      }
      if (applied <= 0) throw Exception('Enter an allocation amount');
      final table = partyType == 'Customer' ? 'customers' : 'suppliers';
      await t.rawUpdate(
          'UPDATE $table SET balance=MAX(COALESCE(balance,0)-?,0),credit_balance=MAX(COALESCE(credit_balance,0)-?,0) WHERE id=?',
          [applied, applied, partyId]);
      await _audit(
          t,
          'Allocate unapplied payment',
          partyType.toLowerCase(),
          partyId,
          'Payment $paymentId • allocated ${applied.toStringAsFixed(3)}');
    });
  }

  Future<List<Map<String, Object?>>> accountAdjustments(
      {String partyType = 'All', int limit = 300}) async {
    final where = partyType == 'All' ? '' : 'WHERE a.party_type=?';
    final args = <Object?>[if (partyType != 'All') partyType, limit];
    return db.rawQuery('''
      SELECT a.*,COALESCE(c.name,s.name,'') party_name,
        COALESCE((SELECT SUM(x.allocated_amount) FROM adjustment_allocations x WHERE x.adjustment_id=a.id),0) allocated_amount
      FROM account_adjustments a
      LEFT JOIN customers c ON a.party_type='Customer' AND c.id=a.party_id
      LEFT JOIN suppliers s ON a.party_type='Supplier' AND s.id=a.party_id
      $where
      ORDER BY a.created_at DESC LIMIT ?
    ''', args);
  }

  Future<String> postPartyAdjustment({
    required String partyType,
    required String partyId,
    required String kind,
    required double amount,
    String reference = '',
    String notes = '',
    DateTime? dueDate,
  }) async {
    await requirePermission(
        'accounting_adjustments', 'Post accounting adjustments');
    if (partyType != 'Customer' && partyType != 'Supplier')
      throw Exception('Choose Customer or Supplier');
    if (amount <= 0) throw Exception('Amount must be greater than zero');
    const validKinds = {
      'Opening Receivable',
      'Opening Credit',
      'Customer Credit Note',
      'Customer Debit Note',
      'Opening Payable',
      'Opening Advance',
      'Supplier Debit Note',
      'Supplier Credit Note'
    };
    if (!validKinds.contains(kind))
      throw Exception('Unsupported adjustment type');
    final customer = partyType == 'Customer';
    if (customer &&
        !{
          'Opening Receivable',
          'Opening Credit',
          'Customer Credit Note',
          'Customer Debit Note'
        }.contains(kind)) throw Exception('Choose a customer adjustment type');
    if (!customer &&
        !{
          'Opening Payable',
          'Opening Advance',
          'Supplier Debit Note',
          'Supplier Credit Note'
        }.contains(kind)) throw Exception('Choose a supplier adjustment type');
    final id = _id('ADJ');
    final no = 'AJ-${DateTime.now().millisecondsSinceEpoch}';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final table = customer ? 'customers' : 'suppliers';
      final party =
          await t.query(table, where: 'id=?', whereArgs: [partyId], limit: 1);
      if (party.isEmpty) throw Exception('$partyType not found');
      final increasesBalance = kind == 'Opening Receivable' ||
          kind == 'Customer Debit Note' ||
          kind == 'Opening Payable' ||
          kind == 'Supplier Credit Note';
      final pureCredit = kind == 'Opening Credit' || kind == 'Opening Advance';
      final adjustmentBalance = increasesBalance ? amount : 0.0;
      await t.insert('account_adjustments', {
        'id': id,
        'no': no,
        'created_at': DateTime.now().toIso8601String(),
        'due_date': dueDate?.toIso8601String(),
        'party_type': partyType,
        'party_id': partyId,
        'kind': kind,
        'amount': amount,
        'balance': adjustmentBalance,
        'reference': reference.trim(),
        'notes': notes.trim(),
        'status': increasesBalance ? 'Posted' : 'Settled',
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      if (increasesBalance) {
        await t.rawUpdate(
            'UPDATE $table SET balance=COALESCE(balance,0)+? WHERE id=?',
            [amount, partyId]);
      } else if (pureCredit) {
        await t.rawUpdate(
            'UPDATE $table SET credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
            [amount, partyId]);
      } else {
        var remaining = amount;
        var reduced = 0.0;
        final docs = customer ? await t.rawQuery('''
          SELECT id,balance,'Sale' document_type,COALESCE(due_date,created_at) sort_date FROM sales
          WHERE customer_id=? AND balance>0.000001 AND COALESCE(status,'Completed')<>'Cancelled'
          UNION ALL
          SELECT id,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date FROM account_adjustments
          WHERE party_type='Customer' AND party_id=? AND balance>0.000001 AND status='Posted' AND id<>?
          ORDER BY sort_date
        ''', [partyId, partyId, id]) : await t.rawQuery('''
          SELECT id,balance,'Purchase' document_type,COALESCE(due_date,created_at) sort_date FROM purchases
          WHERE supplier_id=? AND balance>0.000001 AND COALESCE(status,'Received')<>'Cancelled'
          UNION ALL
          SELECT id,balance,'Adjustment' document_type,COALESCE(due_date,created_at) sort_date FROM account_adjustments
          WHERE party_type='Supplier' AND party_id=? AND balance>0.000001 AND status='Posted' AND id<>?
          ORDER BY sort_date
        ''', [partyId, partyId, id]);
        for (final doc in docs) {
          if (remaining <= 0.000001) break;
          final bal = (doc['balance'] as num? ?? 0).toDouble();
          final apply = remaining < bal ? remaining : bal;
          final docType = (doc['document_type'] ?? '').toString();
          if (docType == 'Sale') {
            await t.rawUpdate(
                "UPDATE sales SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Completed' ELSE 'Credit' END WHERE id=?",
                [apply, apply, doc['id']]);
          } else if (docType == 'Purchase') {
            await t.rawUpdate(
                "UPDATE purchases SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Received' ELSE 'Partially Paid' END WHERE id=?",
                [apply, apply, doc['id']]);
          } else {
            await t.rawUpdate(
                "UPDATE account_adjustments SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0.000001 THEN 'Settled' ELSE status END WHERE id=?",
                [apply, apply, doc['id']]);
          }
          await t.insert('adjustment_allocations', {
            'adjustment_id': id,
            'document_type': docType,
            'document_id': doc['id'],
            'allocated_amount': apply,
            'created_at': DateTime.now().toIso8601String()
          });
          remaining -= apply;
          reduced += apply;
        }
        final excess = remaining.clamp(0, double.infinity).toDouble();
        await t.rawUpdate(
            'UPDATE $table SET balance=MAX(COALESCE(balance,0)-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
            [reduced, excess, partyId]);
        if (excess > 0) {
          await t.update(
              'account_adjustments',
              {
                'notes':
                    '${notes.trim()}${notes.trim().isEmpty ? '' : ' • '}Excess ${excess.toStringAsFixed(3)} carried as account credit.'
              },
              where: 'id=?',
              whereArgs: [id]);
        }
      }
      await _audit(t, kind, partyType.toLowerCase(), partyId,
          '$no • ${amount.toStringAsFixed(3)}${reference.trim().isEmpty ? '' : ' • $reference'}');
    });
    return id;
  }

  Future<Map<String, double>> accountingIntegritySummary() async {
    final rows = await db.rawQuery('''
      SELECT
        COALESCE((SELECT SUM(balance) FROM customers),0) customer_master,
        COALESCE((SELECT SUM(balance) FROM sales WHERE COALESCE(status,'Completed')<>'Cancelled'),0)+
          COALESCE((SELECT SUM(balance) FROM account_adjustments WHERE party_type='Customer' AND status='Posted'),0) customer_open,
        COALESCE((SELECT SUM(credit_balance) FROM customers),0) customer_credit,
        COALESCE((SELECT SUM(balance) FROM suppliers),0) supplier_master,
        COALESCE((SELECT SUM(balance) FROM purchases WHERE COALESCE(status,'Received')<>'Cancelled'),0)+
          COALESCE((SELECT SUM(balance) FROM account_adjustments WHERE party_type='Supplier' AND status='Posted'),0) supplier_open,
        COALESCE((SELECT SUM(credit_balance) FROM suppliers),0) supplier_credit,
        COALESCE((SELECT SUM(MAX(p.amount-COALESCE((SELECT SUM(pa.allocated_amount) FROM payment_allocations pa WHERE pa.payment_id=p.id),0),0))
          FROM payments p WHERE p.amount>0 AND (p.document_type LIKE 'Account Payment%' OR p.document_type='Account Receipt')),0) unapplied_payments
    ''');
    final r = rows.first;
    double n(String k) => (r[k] as num? ?? 0).toDouble();
    return {
      'customer_master': n('customer_master'),
      'customer_open': n('customer_open'),
      'customer_difference': n('customer_master') - n('customer_open'),
      'customer_credit': n('customer_credit'),
      'supplier_master': n('supplier_master'),
      'supplier_open': n('supplier_open'),
      'supplier_difference': n('supplier_master') - n('supplier_open'),
      'supplier_credit': n('supplier_credit'),
      'unapplied_payments': n('unapplied_payments'),
    };
  }

  Future<void> rebuildPartyBalancesFromDocuments() async {
    await requirePermission(
        'accounting_adjustments', 'Rebuild accounting balances');
    await db.transaction((t) async {
      await t.execute('''
        UPDATE customers SET balance=
          COALESCE((SELECT SUM(s.balance) FROM sales s WHERE s.customer_id=customers.id AND COALESCE(s.status,'Completed')<>'Cancelled'),0)+
          COALESCE((SELECT SUM(a.balance) FROM account_adjustments a WHERE a.party_type='Customer' AND a.party_id=customers.id AND a.status='Posted'),0)
      ''');
      await t.execute('''
        UPDATE suppliers SET balance=
          COALESCE((SELECT SUM(p.balance) FROM purchases p WHERE p.supplier_id=suppliers.id AND COALESCE(p.status,'Received')<>'Cancelled'),0)+
          COALESCE((SELECT SUM(a.balance) FROM account_adjustments a WHERE a.party_type='Supplier' AND a.party_id=suppliers.id AND a.status='Posted'),0)
      ''');
      await _audit(t, 'Rebuild party balances', 'accounting', 'party_balances',
          'Recalculated customer and supplier balances from open documents and adjustments');
    });
  }

  Future<List<Map<String, Object?>>> paymentReconciliationRows(
      {String status = 'All', String method = 'All', int limit = 500}) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (status == 'Reconciled') clauses.add('r.payment_id IS NOT NULL');
    if (status == 'Unreconciled') clauses.add('r.payment_id IS NULL');
    if (method != 'All') {
      clauses.add('p.method=?');
      args.add(method);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.rawQuery('''
      SELECT p.*,COALESCE(c.name,s.name,'') party_name,r.id reconciliation_id,r.account_type,r.statement_ref,r.reconciled_at,r.reconciled_by,r.notes reconciliation_notes
      FROM payments p
      LEFT JOIN customers c ON p.party_type='Customer' AND c.id=p.party_id
      LEFT JOIN suppliers s ON p.party_type='Supplier' AND s.id=p.party_id
      LEFT JOIN payment_reconciliations r ON r.payment_id=p.id
      $where
      ORDER BY p.created_at DESC LIMIT ?
    ''', [...args, limit]);
  }

  Future<Map<String, double>> paymentReconciliationSummary() async {
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(ABS(p.amount)),0) total,
        COALESCE(SUM(CASE WHEN r.payment_id IS NOT NULL THEN ABS(p.amount) ELSE 0 END),0) reconciled,
        COALESCE(SUM(CASE WHEN r.payment_id IS NULL THEN ABS(p.amount) ELSE 0 END),0) unreconciled
      FROM payments p LEFT JOIN payment_reconciliations r ON r.payment_id=p.id
    ''');
    final r = rows.first;
    return {
      for (final k in ['total', 'reconciled', 'unreconciled'])
        k: (r[k] as num? ?? 0).toDouble()
    };
  }

  Future<void> setPaymentReconciled({
    required String paymentId,
    required bool reconciled,
    String accountType = 'Bank',
    String statementRef = '',
    String notes = '',
  }) async {
    await requirePermission('reconciliation', 'Reconcile payments');
    await db.transaction((t) async {
      final rows = await t.query('payments',
          where: 'id=?', whereArgs: [paymentId], limit: 1);
      if (rows.isEmpty) throw Exception('Payment not found');
      if (!reconciled) {
        await t.delete('payment_reconciliations',
            where: 'payment_id=?', whereArgs: [paymentId]);
        await _audit(t, 'Unreconcile payment', 'payment', paymentId,
            'Reconciliation cleared');
        return;
      }
      final ctx = await operationalContext(t);
      await t.insert(
          'payment_reconciliations',
          {
            'id': _id('REC'),
            'payment_id': paymentId,
            'account_type': accountType,
            'statement_ref': statementRef.trim(),
            'reconciled_at': DateTime.now().toIso8601String(),
            'reconciled_by': ctx['user_id'],
            'notes': notes.trim(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _audit(t, 'Reconcile payment', 'payment', paymentId,
          '$accountType${statementRef.trim().isEmpty ? '' : ' • $statementRef'}');
    });
  }

  Future<List<Map<String, Object?>>> stockMovements() async => db.rawQuery(
        'SELECT m.*,p.name,p.sku FROM stock_movements m LEFT JOIN products p ON p.id=m.product_id ORDER BY m.id DESC LIMIT 300',
      );

  Future<List<Map<String, Object?>>> recentSales(
      {int limit = 100, bool currentBranchOnly = false}) async {
    if (!currentBranchOnly) {
      return db.rawQuery(
          '''SELECT s.*,c.name customer_name,c.phone customer_phone,c.whatsapp customer_whatsapp,c.email customer_email,c.preferred_delivery customer_preferred_delivery FROM sales s LEFT JOIN customers c ON c.id=s.customer_id ORDER BY s.created_at DESC LIMIT ?''',
          [limit]);
    }
    final ctx = await operationalContext();
    return db.rawQuery(
        '''SELECT s.*,c.name customer_name FROM sales s LEFT JOIN customers c ON c.id=s.customer_id WHERE s.branch_id=? ORDER BY s.created_at DESC LIMIT ?''',
        [ctx['branch_id'], limit]);
  }

  Future<List<Map<String, Object?>>> recentPurchases(
      {int limit = 100, bool currentBranchOnly = false}) async {
    if (!currentBranchOnly) {
      return db.rawQuery(
          '''SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id ORDER BY p.created_at DESC LIMIT ?''',
          [limit]);
    }
    final ctx = await operationalContext();
    return db.rawQuery(
        '''SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.branch_id=? ORDER BY p.created_at DESC LIMIT ?''',
        [ctx['branch_id'], limit]);
  }

  Future<Map<String, Object>> salesHistoryPage({
    int limit = 10,
    int offset = 0,
    String search = '',
    String status = 'All',
    String sort = 'Newest',
    DateTime? from,
    DateTime? to,
    bool includeProfit = true,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    final q = search.trim();
    if (q.isNotEmpty) {
      final like = '%$q%';
      clauses.add(
          "(s.no LIKE ? OR COALESCE(c.name,'') LIKE ? OR COALESCE(c.phone,'') LIKE ? OR COALESCE(c.email,'') LIKE ? OR COALESCE(s.payment_method,'') LIKE ?)");
      args.addAll([like, like, like, like, like]);
    }
    if (status == 'Paid')
      clauses.add(
          "COALESCE(s.balance,0)<=0 AND s.status NOT LIKE '%Return%' AND COALESCE(s.status,'Completed')<>'Cancelled'");
    if (status == 'Due')
      clauses.add(
          "COALESCE(s.balance,0)>0 AND COALESCE(s.status,'Completed')<>'Cancelled'");
    if (status == 'Returned') clauses.add("s.status LIKE '%Return%'");
    if (from != null) {
      clauses.add('s.created_at>=?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      clauses.add('s.created_at<?');
      args.add(DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1))
          .toIso8601String());
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final order = switch (sort) {
      'Oldest' => 's.created_at ASC',
      'Total high' => 's.total DESC,s.created_at DESC',
      'Total low' => 's.total ASC,s.created_at DESC',
      'Due high' => 's.balance DESC,s.created_at DESC',
      _ => 's.created_at DESC',
    };
    const itemRevenue =
        "COALESCE((SELECT SUM(si.line_total-si.tax) FROM sale_items si WHERE si.sale_id=s.id),0)";
    const invoiceCost =
        "COALESCE((SELECT SUM(si.cost*si.qty) FROM sale_items si WHERE si.sale_id=s.id),0)";
    const returnedRevenue =
        "COALESCE((SELECT SUM(sri.line_total-sri.tax) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.sale_id=s.id AND COALESCE(sr.status,'Posted')<>'Cancelled'),0)";
    const returnedCost =
        "COALESCE((SELECT SUM(sri.cost) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.sale_id=s.id AND COALESCE(sr.status,'Posted')<>'Cancelled'),0)";
    const netRevenue =
        "CASE WHEN COALESCE(s.status,'Completed')='Cancelled' THEN 0 ELSE ($itemRevenue-COALESCE(s.discount,0)-$returnedRevenue) END";
    const grossProfit =
        "CASE WHEN COALESCE(s.status,'Completed')='Cancelled' THEN 0 ELSE (($itemRevenue-COALESCE(s.discount,0)-$returnedRevenue)-($invoiceCost-$returnedCost)) END";

    final countRows = await db.rawQuery(
        'SELECT COUNT(*) n FROM sales s LEFT JOIN customers c ON c.id=s.customer_id $where',
        args);
    final profitColumns = includeProfit
        ? ', $netRevenue net_revenue,$grossProfit gross_profit, CASE WHEN ($netRevenue)>0 THEN (($grossProfit)/($netRevenue))*100 ELSE 0 END margin_pct'
        : '';
    final rows = await db.rawQuery('''
      SELECT s.*,c.name customer_name,u.display_name user_name,b.name branch_name,
             (SELECT cl.action FROM communication_log cl WHERE cl.document_type='Invoice' AND cl.document_id=s.id AND cl.channel='WhatsApp' ORDER BY cl.created_at DESC LIMIT 1) whatsapp_share_action,
             (SELECT cl.created_at FROM communication_log cl WHERE cl.document_type='Invoice' AND cl.document_id=s.id AND cl.channel='WhatsApp' ORDER BY cl.created_at DESC LIMIT 1) whatsapp_share_at
             $profitColumns
      FROM sales s
      LEFT JOIN customers c ON c.id=s.customer_id
      LEFT JOIN users u ON u.id=s.user_id
      LEFT JOIN branches b ON b.id=s.branch_id
      $where ORDER BY $order LIMIT ? OFFSET ?
    ''', [...args, limit, offset]);
    var summary = const <String, double>{};
    if (includeProfit) {
      final summaryRows = await db.rawQuery('''
        SELECT COALESCE(SUM($netRevenue),0) net_sales,COALESCE(SUM($grossProfit),0) gross_profit
        FROM sales s LEFT JOIN customers c ON c.id=s.customer_id $where
      ''', args);
      final netSales = (summaryRows.first['net_sales'] as num? ?? 0).toDouble();
      final profit =
          (summaryRows.first['gross_profit'] as num? ?? 0).toDouble();
      summary = <String, double>{
        'net_sales': netSales,
        'gross_profit': profit,
        'margin_pct': netSales > 0 ? profit / netSales * 100 : 0
      };
    }
    return {
      'rows': rows,
      'total': _firstIntValue(countRows) ?? 0,
      'summary': summary
    };
  }

  Future<Map<String, Object>> purchaseHistoryPage({
    int limit = 10,
    int offset = 0,
    String search = '',
    String status = 'All',
    String sort = 'Newest',
    DateTime? from,
    DateTime? to,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    final q = search.trim();
    if (q.isNotEmpty) {
      final like = '%$q%';
      clauses.add(
          "(p.no LIKE ? OR COALESCE(s.name,'') LIKE ? OR COALESCE(s.phone,'') LIKE ? OR COALESCE(s.email,'') LIKE ? OR COALESCE(p.document_no,'') LIKE ?)");
      args.addAll([like, like, like, like, like]);
    }
    if (status == 'Paid') clauses.add('COALESCE(p.balance,0)<=0');
    if (status == 'Due') clauses.add('COALESCE(p.balance,0)>0');
    if (from != null) {
      clauses.add('p.created_at>=?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      clauses.add('p.created_at<?');
      args.add(DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1))
          .toIso8601String());
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final order = switch (sort) {
      'Oldest' => 'p.created_at ASC',
      'Total high' => 'p.total DESC,p.created_at DESC',
      'Total low' => 'p.total ASC,p.created_at DESC',
      'Due high' => 'p.balance DESC,p.created_at DESC',
      _ => 'p.created_at DESC',
    };
    final countRows = await db.rawQuery(
        'SELECT COUNT(*) n FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id $where',
        args);
    final rows = await db.rawQuery('''
      SELECT p.*,s.name supplier_name,u.display_name user_name,b.name branch_name
      FROM purchases p
      LEFT JOIN suppliers s ON s.id=p.supplier_id
      LEFT JOIN users u ON u.id=p.user_id
      LEFT JOIN branches b ON b.id=p.branch_id
      $where ORDER BY $order LIMIT ? OFFSET ?
    ''', [...args, limit, offset]);
    return {'rows': rows, 'total': _firstIntValue(countRows) ?? 0};
  }

  Future<Map<String, num>> dashboard() async {
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toIso8601String();
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    final row = (await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM products) products,
        (SELECT COUNT(*) FROM products p LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=? WHERE p.active=1 AND COALESCE(p.product_type,'Stocked')='Stocked' AND COALESCE(bs.qty,0)<=p.min_stock) low_stock,
        (SELECT COALESCE(SUM(total),0) FROM sales WHERE branch_id=? AND created_at>=? AND created_at<?) today_sales,
        (SELECT COALESCE(SUM(total),0) FROM purchases WHERE branch_id=? AND created_at>=? AND created_at<?) today_purchases,
        (SELECT COALESCE(SUM(balance),0) FROM customers) receivable,
        (SELECT COALESCE(SUM(balance),0) FROM suppliers) payable,
        (SELECT COALESCE(SUM(balance),0) FROM sales WHERE balance>0 AND due_date IS NOT NULL AND due_date<?) overdue_receivable,
        (SELECT COALESCE(SUM(balance),0) FROM purchases WHERE balance>0 AND due_date IS NOT NULL AND due_date<?) overdue_payable
    ''', [
      branchId,
      branchId,
      todayStart,
      tomorrow,
      branchId,
      todayStart,
      tomorrow,
      now.toIso8601String(),
      now.toIso8601String()
    ]))
        .first;
    return {
      'products': (row['products'] as num?) ?? 0,
      'lowStock': (row['low_stock'] as num?) ?? 0,
      'todaySales': (row['today_sales'] as num?) ?? 0,
      'todayPurchases': (row['today_purchases'] as num?) ?? 0,
      'receivable': (row['receivable'] as num?) ?? 0,
      'payable': (row['payable'] as num?) ?? 0,
      'overdueReceivable': (row['overdue_receivable'] as num?) ?? 0,
      'overduePayable': (row['overdue_payable'] as num?) ?? 0,
    };
  }

  Future<Map<String, num>> reportSummary() async {
    final now = DateTime.now();
    final summary =
        await reportSummaryBetween(now.subtract(const Duration(days: 29)), now);
    return {
      'sales30': summary['sales'] ?? 0,
      'salesDue30': summary['salesDue'] ?? 0,
      'purchases30': summary['purchases'] ?? 0,
      'purchaseDue30': summary['purchaseDue'] ?? 0,
      'grossMargin30': summary['grossMargin'] ?? 0,
      'stockValue': summary['stockValue'] ?? 0
    };
  }

  String _payloadChecksum(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  Future<int> _nextEntityRevision(
      DatabaseExecutor t, String entityType, String entityId) async {
    final rows = await t.query('sync_entity_versions',
        columns: ['revision'],
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [entityType, entityId],
        limit: 1);
    return (rows.isEmpty
            ? 0
            : ((rows.first['revision'] as num?) ?? 0).toInt()) +
        1;
  }

  Future<String> _enqueueSyncEventTx(
    DatabaseExecutor t, {
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
  }) async {
    final metaRows = await t.query('app_meta',
        where:
            "k IN ('sync_company_id','sync_device_id','current_branch_id','current_terminal_id')");
    final identity = <String, String>{
      for (final r in metaRows)
        (r['k'] ?? '').toString(): (r['v'] ?? '').toString()
    };
    final sequence = await _nextSyncSequence(t);
    final now = DateTime.now().toUtc().toIso8601String();
    final eventId =
        'EVT-${identity['sync_device_id']}-$sequence-${_randomHex(4)}';
    final body = jsonEncode(payload);
    final checksum = sha256.convert(utf8.encode(body)).toString();
    await t.insert('sync_outbox', {
      'event_id': eventId,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'payload': body,
      'created_at': now,
      'updated_at': now,
      'status': 'Pending',
      'attempts': 0,
      'device_id': identity['sync_device_id'],
      'branch_id': identity['current_branch_id'],
      'sequence': sequence,
      'checksum': checksum,
    });
    return eventId;
  }

  Future<String> _queueMasterRecordTx(
    DatabaseExecutor t, {
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> record,
    Map<String, Object?> extras = const {},
  }) async {
    final revision = await _nextEntityRevision(t, entityType, entityId);
    final payload = <String, Object?>{
      'schema': 1,
      'revision': revision,
      'record': record,
      ...extras,
    };
    final checksum = _payloadChecksum(payload);
    final deviceRows = await t.query('app_meta',
        columns: ['v'], where: "k='sync_device_id'", limit: 1);
    final deviceId =
        deviceRows.isEmpty ? '' : (deviceRows.first['v'] ?? '').toString();
    await t.insert(
        'sync_entity_versions',
        {
          'entity_type': entityType,
          'entity_id': entityId,
          'revision': revision,
          'payload_checksum': checksum,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'source_device_id': deviceId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    return _enqueueSyncEventTx(t,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        payload: payload);
  }

  Future<Map<String, Object?>> _rowById(
      DatabaseExecutor t, String table, String id) async {
    final rows = await t.query(table, where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(rows.first);
  }

  Future<void> queueInitialMasterSnapshot() async {
    await db.transaction((t) async {
      for (final spec in const [
        ['branch', 'branches'],
        ['customer_group', 'customer_groups'],
        ['customer_group_rule', 'customer_group_discount_rules'],
        ['product', 'products'],
        ['customer', 'customers'],
        ['supplier', 'suppliers'],
      ]) {
        final rows = await t.query(spec[1]);
        for (final raw in rows) {
          final record = Map<String, Object?>.from(raw);
          final id = (record['id'] ?? '').toString();
          if (id.isEmpty) continue;
          if (spec[0] == 'product') record.remove('stock');
          if (spec[0] == 'customer' || spec[0] == 'supplier') {
            record.remove('balance');
            record.remove('credit_balance');
          }
          await _queueMasterRecordTx(t,
              entityType: spec[0],
              entityId: id,
              operation: 'upsert',
              record: record);
        }
      }
      final stockRows = await t.rawQuery(
          'SELECT product_id,branch_id,qty FROM branch_stock WHERE ABS(COALESCE(qty,0))>0.000001');
      for (final stock in stockRows) {
        final productId = (stock['product_id'] ?? '').toString();
        final branchId = (stock['branch_id'] ?? '').toString();
        if (productId.isEmpty || branchId.isEmpty) continue;
        final lots = await t.query('stock_lots',
            where: 'product_id=? AND branch_id=? AND remaining_qty>0.000001',
            whereArgs: [productId, branchId],
            orderBy: 'created_at,id');
        await _enqueueSyncEventTx(
          t,
          entityType: 'inventory_baseline',
          entityId: '$productId@$branchId',
          operation: 'baseline',
          payload: {
            'schema': 1,
            'product_id': productId,
            'branch_id': branchId,
            'qty': (stock['qty'] as num? ?? 0).toDouble(),
            'lots': lots,
          },
        );
      }
    });
  }

  Future<Map<String, String>> syncIdentity() async {
    final rows = await db.query('app_meta',
        where:
            "k IN ('sync_company_id','sync_device_id','current_branch_id','current_terminal_id')");
    final values = <String, String>{
      for (final r in rows) (r['k'] ?? '').toString(): (r['v'] ?? '').toString()
    };
    final deviceId = values['sync_device_id'] ?? '';
    final device = deviceId.isEmpty
        ? const <Map<String, Object?>>[]
        : await db.query('sync_devices',
            where: 'device_id=?', whereArgs: [deviceId], limit: 1);
    return {
      'company_id': values['sync_company_id'] ?? '',
      'device_id': deviceId,
      'branch_id': values['current_branch_id'] ?? '',
      'terminal_id': values['current_terminal_id'] ?? '',
      'device_name': device.isEmpty
          ? Platform.localHostname
          : (device.first['name'] ?? '').toString(),
      'platform': device.isEmpty
          ? Platform.operatingSystem
          : (device.first['platform'] ?? '').toString(),
      'server_device_id': device.isEmpty
          ? ''
          : (device.first['server_device_id'] ?? '').toString(),
      'device_status': device.isEmpty
          ? 'Local'
          : (device.first['status'] ?? 'Local').toString(),
    };
  }

  Future<int> _nextSyncSequence(DatabaseExecutor t) async {
    final rows = await t.query('sync_state',
        columns: ['v'], where: "k='outbox_sequence'", limit: 1);
    final next = (rows.isEmpty
            ? 0
            : int.tryParse((rows.first['v'] ?? '0').toString()) ?? 0) +
        1;
    await t.insert('sync_state', {'k': 'outbox_sequence', 'v': '$next'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await t.insert('app_meta', {'k': 'sync_outbox_sequence', 'v': '$next'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return next;
  }

  Future<String> enqueueSyncEvent(
      {required String entityType,
      required String entityId,
      required String operation,
      required Map<String, Object?> payload}) async {
    return db.transaction((t) => _enqueueSyncEventTx(t,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        payload: payload));
  }

  Future<List<Map<String, Object?>>> pendingSyncEvents(
      {int limit = 100}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    return db.rawQuery(
        "SELECT * FROM sync_outbox WHERE status IN ('Pending','Failed') AND (next_retry_at IS NULL OR next_retry_at<=?) ORDER BY sequence,id LIMIT ?",
        [now, limit]);
  }

  Future<void> markSyncSending(List<String> eventIds) async {
    if (eventIds.isEmpty) return;
    final q = List.filled(eventIds.length, '?').join(',');
    await db.rawUpdate(
        "UPDATE sync_outbox SET status='Sending',updated_at=?,attempts=COALESCE(attempts,0)+1 WHERE event_id IN ($q)",
        [DateTime.now().toUtc().toIso8601String(), ...eventIds]);
  }

  Future<void> markSyncAccepted(List<String> eventIds) async {
    if (eventIds.isEmpty) return;
    final q = List.filled(eventIds.length, '?').join(',');
    final now = DateTime.now().toUtc().toIso8601String();
    await db.rawUpdate(
        "UPDATE sync_outbox SET status='Synced',synced_at=?,updated_at=?,last_error=NULL,next_retry_at=NULL WHERE event_id IN ($q)",
        [now, now, ...eventIds]);
  }

  Future<void> markSyncFailed(String eventId, String error,
      {bool retryable = true}) async {
    final rows = await db.query('sync_outbox',
        columns: ['attempts'],
        where: 'event_id=?',
        whereArgs: [eventId],
        limit: 1);
    final attempts =
        rows.isEmpty ? 1 : ((rows.first['attempts'] as num?) ?? 1).toInt();
    final exponent = min(6, max(0, attempts - 1)).toInt();
    final minutes = min(60, 1 << exponent).toInt();
    final retry = retryable
        ? DateTime.now()
            .toUtc()
            .add(Duration(minutes: minutes))
            .toIso8601String()
        : null;
    await db.update(
        'sync_outbox',
        {
          'status': retryable ? 'Failed' : 'Blocked',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': error,
          'next_retry_at': retry
        },
        where: 'event_id=?',
        whereArgs: [eventId]);
  }

  Future<void> resetFailedSyncEvents() async {
    await db.rawUpdate(
        "UPDATE sync_outbox SET status='Pending',next_retry_at=NULL,last_error=NULL WHERE status IN ('Failed','Blocked')");
  }

  Future<void> stageIncomingEvents(List<Map<String, dynamic>> events) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((t) async {
      for (final event in events) {
        final eventId = (event['event_id'] ?? '').toString();
        if (eventId.isEmpty) continue;
        await t.insert(
            'sync_inbox',
            {
              'event_id': eventId,
              'entity_type': (event['entity_type'] ?? '').toString(),
              'entity_id': (event['entity_id'] ?? '').toString(),
              'operation': (event['operation'] ?? '').toString(),
              'payload': jsonEncode(event['payload'] ?? const {}),
              'received_at': now,
              'status': 'Pending',
              'source_device_id':
                  (event['device_id'] ?? event['source_device_id'] ?? '')
                      .toString(),
              'server_sequence': event['server_sequence'] is num
                  ? (event['server_sequence'] as num).toInt()
                  : int.tryParse('${event['server_sequence'] ?? ''}'),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<Map<String, int>> applyPendingIncomingEvents({int limit = 200}) async {
    final rows = await db.rawQuery(
      "SELECT * FROM sync_inbox WHERE status IN ('Pending','Failed') ORDER BY COALESCE(server_sequence,id),id LIMIT ?",
      [limit],
    );
    var applied = 0, conflicts = 0, failed = 0, ignored = 0;
    for (final raw in rows) {
      final row = Map<String, Object?>.from(raw);
      final inboxId = (row['id'] as num?)?.toInt();
      if (inboxId == null) continue;
      try {
        final outcome =
            await db.transaction((t) => _applyIncomingEventTx(t, row));
        final now = DateTime.now().toUtc().toIso8601String();
        if (outcome == 'Conflict') {
          conflicts++;
          await db.update(
              'sync_inbox',
              {
                'status': 'Conflict',
                'applied_at': now,
                'error': 'Manual conflict resolution required.'
              },
              where: 'id=?',
              whereArgs: [inboxId]);
        } else {
          if (outcome == 'Ignored')
            ignored++;
          else
            applied++;
          await db.update(
              'sync_inbox',
              {
                'status': outcome == 'Ignored' ? 'Ignored' : 'Applied',
                'applied_at': now,
                'error': null
              },
              where: 'id=?',
              whereArgs: [inboxId]);
        }
      } catch (e) {
        failed++;
        await db.update(
            'sync_inbox',
            {
              'status': 'Failed',
              'error': e.toString().replaceFirst('Exception: ', '')
            },
            where: 'id=?',
            whereArgs: [inboxId]);
      }
    }
    return {
      'applied': applied,
      'conflicts': conflicts,
      'failed': failed,
      'ignored': ignored
    };
  }

  Future<String> _applyIncomingEventTx(
      DatabaseExecutor t, Map<String, Object?> inbox) async {
    final type = (inbox['entity_type'] ?? '').toString();
    final entityId = (inbox['entity_id'] ?? '').toString();
    final eventId = (inbox['event_id'] ?? '').toString();
    final sourceDevice = (inbox['source_device_id'] ?? '').toString();
    final rawPayload = (inbox['payload'] ?? '{}').toString();
    final decoded = jsonDecode(rawPayload);
    if (decoded is! Map) throw Exception('Invalid sync payload.');
    final payload = Map<String, Object?>.from(decoded.cast<String, Object?>());

    if (type == 'sync_probe') return 'Applied';
    if (const {
      'branch',
      'product',
      'customer',
      'supplier',
      'customer_group',
      'customer_group_rule'
    }.contains(type)) {
      return _applyMasterRecordTx(
          t, type, entityId, eventId, sourceDevice, payload);
    }
    if (type == 'sale_txn') return _applyRemoteSaleTx(t, entityId, payload);
    if (type == 'purchase_txn')
      return _applyRemotePurchaseTx(t, entityId, payload);
    if (type == 'customer_payment_txn')
      return _applyRemotePartyPaymentTx(t, payload, customer: true);
    if (type == 'supplier_payment_txn')
      return _applyRemotePartyPaymentTx(t, payload, customer: false);
    if (type == 'inventory_baseline')
      return _applyInventoryBaselineTx(t, eventId, payload);
    if (type == 'stock_adjustment_txn')
      return _applyRemoteStockAdjustmentTx(t, entityId, payload);
    if (type == 'recipe_definition')
      return _applyRemoteRecipeDefinitionTx(t, entityId, payload);
    if (type == 'return_reference') {
      final purchase = payload['purchase'] == true;
      final table = purchase ? 'purchase_returns' : 'sales_returns';
      final reference = (payload['source_reference'] ?? '').toString();
      await t.update(table, {'source_reference': reference},
          where: 'id=?', whereArgs: [entityId]);
      return 'Applied';
    }
    if (type == 'sale_return_txn')
      return _applyRemoteReversalLikeTx(t, eventId, type, entityId, payload);
    if (type == 'purchase_return_txn')
      return _applyRemoteReversalLikeTx(t, eventId, type, entityId, payload);
    if (type == 'sale_void_txn')
      return _applyRemoteReversalLikeTx(t, eventId, type, entityId, payload);
    if (type == 'purchase_void_txn')
      return _applyRemoteReversalLikeTx(t, eventId, type, entityId, payload);
    if (type == 'purchase_order_txn' || type == 'purchase_order_state')
      return _applyRemotePurchaseOrderTx(t, eventId, entityId, payload);
    if (type == 'stock_transfer_txn')
      return _applyRemoteStockTransferTx(t, eventId, entityId, payload);
    if (type == 'stock_count_txn')
      return _applyRemoteStockCountTx(t, eventId, entityId, payload);
    if (type == 'held_sale_txn')
      return _applyRemoteHeldSaleTx(t, eventId, entityId, payload);
    return 'Ignored';
  }

  Future<String> _applyMasterRecordTx(
    DatabaseExecutor t,
    String entityType,
    String entityId,
    String eventId,
    String sourceDevice,
    Map<String, Object?> payload,
  ) async {
    final revision = (payload['revision'] as num?)?.toInt() ??
        int.tryParse('${payload['revision'] ?? 0}') ??
        0;
    final rawRecord = payload['record'];
    if (rawRecord is! Map)
      throw Exception('Missing $entityType record payload.');
    final record = Map<String, Object?>.from(rawRecord.cast<String, Object?>());
    if ((record['id'] ?? '').toString().isEmpty) record['id'] = entityId;
    final remoteChecksum = _payloadChecksum(payload);
    final versions = await t.query('sync_entity_versions',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [entityType, entityId],
        limit: 1);
    if (versions.isNotEmpty) {
      final localRevision = (versions.first['revision'] as num? ?? 0).toInt();
      final localChecksum =
          (versions.first['payload_checksum'] ?? '').toString();
      if (revision < localRevision) return 'Ignored';
      if (revision == localRevision) {
        if (localChecksum == remoteChecksum) return 'Applied';
        final localPayload =
            await _masterRecordSnapshot(t, entityType, entityId);
        await t.insert(
            'sync_conflicts',
            {
              'id': _id('SCF'),
              'event_id': eventId,
              'entity_type': entityType,
              'entity_id': entityId,
              'local_payload': jsonEncode(localPayload),
              'remote_payload': jsonEncode(payload),
              'detected_at': DateTime.now().toUtc().toIso8601String(),
              'status': 'Open',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        return 'Conflict';
      }
    }

    final table = switch (entityType) {
      'branch' => 'branches',
      'product' => 'products',
      'customer' => 'customers',
      'supplier' => 'suppliers',
      'customer_group' => 'customer_groups',
      'customer_group_rule' => 'customer_group_discount_rules',
      _ => throw Exception('Unsupported master entity $entityType'),
    };
    if (entityType == 'branch' && payload['deleted'] == true) {
      await t.update('branches', {'active': 0},
          where: 'id=?', whereArgs: [entityId]);
      await t.insert(
          'sync_entity_versions',
          {
            'entity_type': entityType,
            'entity_id': entityId,
            'revision': revision,
            'payload_checksum': remoteChecksum,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'source_device_id': sourceDevice
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return 'Applied';
    }
    final existing = await t.query(table,
        columns: ['id'], where: 'id=?', whereArgs: [entityId], limit: 1);
    if (entityType == 'product') record.remove('stock');
    if (entityType == 'customer' || entityType == 'supplier') {
      record.remove('balance');
      record.remove('credit_balance');
    }
    if (existing.isEmpty) {
      await t.insert(table, record);
    } else {
      final update = Map<String, Object?>.from(record)..remove('id');
      await t.update(table, update, where: 'id=?', whereArgs: [entityId]);
    }

    if (entityType == 'product') {
      final category = (record['category'] ?? '').toString().trim();
      final unit = (record['unit'] ?? '').toString().trim();
      if (category.isNotEmpty)
        await t.insert('product_categories', {'name': category, 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      if (unit.isNotEmpty)
        await t.insert('product_units', {'name': unit, 'active': 1},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      if (existing.isEmpty) {
        final opening = (payload['opening_stock'] as num?)?.toDouble() ?? 0.0;
        final branchId = (payload['opening_branch_id'] ?? '').toString();
        if (opening != 0 && branchId.isNotEmpty) {
          final lotId = 'LOT-SYNC-$entityId-$branchId';
          final lotExists = await t.query('stock_lots',
              columns: ['id'], where: 'id=?', whereArgs: [lotId], limit: 1);
          if (lotExists.isEmpty) {
            await t.insert('stock_lots', {
              'id': lotId,
              'product_id': entityId,
              'branch_id': branchId,
              'purchase_item_id': null,
              'batch_no': 'OPENING',
              'expiry_date': null,
              'received_qty': opening,
              'remaining_qty': opening,
              'unit_cost': (payload['opening_cost'] as num?)?.toDouble() ??
                  (record['cost'] as num? ?? 0).toDouble(),
              'created_at': DateTime.now().toIso8601String(),
              'status': 'Open',
            });
            await _changeBranchStock(t, entityId, branchId, opening);
            await t.insert('stock_movements', {
              'created_at': DateTime.now().toIso8601String(),
              'product_id': entityId,
              'qty_change': opening,
              'type': 'Opening Stock',
              'reference': 'SYNC-$entityId',
              'reason': 'Synced opening stock',
              'branch_id': branchId,
              'terminal_id': 'SYNC',
              'user_id': 'SYNC',
            });
          }
        }
      }
    }
    await t.insert(
        'sync_entity_versions',
        {
          'entity_type': entityType,
          'entity_id': entityId,
          'revision': revision,
          'payload_checksum': remoteChecksum,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'source_device_id': sourceDevice,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    return 'Applied';
  }

  Future<Map<String, Object?>> _masterRecordSnapshot(
      DatabaseExecutor t, String entityType, String entityId) async {
    final table = switch (entityType) {
      'branch' => 'branches',
      'product' => 'products',
      'customer' => 'customers',
      'supplier' => 'suppliers',
      'customer_group' => 'customer_groups',
      'customer_group_rule' => 'customer_group_discount_rules',
      _ => '',
    };
    if (table.isEmpty) return {};
    final rows =
        await t.query(table, where: 'id=?', whereArgs: [entityId], limit: 1);
    return rows.isEmpty ? {} : Map<String, Object?>.from(rows.first);
  }

  List<Map<String, Object?>> _payloadList(
      Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, Object?>.from(e.cast<String, Object?>()))
        .toList();
  }

  Future<String> _applyInventoryBaselineTx(
      DatabaseExecutor t, String eventId, Map<String, Object?> payload) async {
    final productId = (payload['product_id'] ?? '').toString();
    final branchId = (payload['branch_id'] ?? '').toString();
    final remoteQty = (payload['qty'] as num? ?? 0).toDouble();
    if (productId.isEmpty || branchId.isEmpty)
      throw Exception('Inventory baseline is missing product or branch.');
    final existing = await t.query('branch_stock',
        columns: ['qty'],
        where: 'product_id=? AND branch_id=?',
        whereArgs: [productId, branchId],
        limit: 1);
    final localQty = existing.isEmpty
        ? 0.0
        : (existing.first['qty'] as num? ?? 0).toDouble();
    final movements = await t.rawQuery(
        'SELECT COUNT(*) c FROM stock_movements WHERE product_id=? AND branch_id=?',
        [productId, branchId]);
    final movementCount =
        movements.isEmpty ? 0 : (movements.first['c'] as num? ?? 0).toInt();
    if (movementCount > 0 || localQty.abs() > 0.000001) {
      if ((localQty - remoteQty).abs() <= 0.000001) return 'Ignored';
      await t.insert(
          'sync_conflicts',
          {
            'id': _id('SCF'),
            'event_id': eventId,
            'entity_type': 'inventory_baseline',
            'entity_id': '$productId@$branchId',
            'local_payload': jsonEncode({
              'product_id': productId,
              'branch_id': branchId,
              'qty': localQty,
              'movement_count': movementCount
            }),
            'remote_payload': jsonEncode(payload),
            'detected_at': DateTime.now().toUtc().toIso8601String(),
            'status': 'Open',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return 'Conflict';
    }
    await t.insert('branch_stock',
        {'product_id': productId, 'branch_id': branchId, 'qty': remoteQty},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await t.rawUpdate(
        'UPDATE products SET stock=COALESCE(stock,0)+? WHERE id=?',
        [remoteQty, productId]);
    final lots = _payloadList(payload, 'lots');
    if (lots.isEmpty && remoteQty > 0) {
      await t.insert('stock_lots', {
        'id': 'LOT-BASE-${_randomHex(8)}',
        'product_id': productId,
        'branch_id': branchId,
        'purchase_item_id': null,
        'batch_no': 'SYNC-BASELINE',
        'expiry_date': null,
        'received_qty': remoteQty,
        'remaining_qty': remoteQty,
        'unit_cost': 0.0,
        'created_at': DateTime.now().toIso8601String(),
        'status': 'Open',
      });
    } else {
      for (final lot in lots) {
        final row = Map<String, Object?>.from(lot);
        row['purchase_item_id'] = null;
        await t.insert('stock_lots', row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await t.insert('stock_movements', {
      'created_at': DateTime.now().toIso8601String(),
      'product_id': productId,
      'qty_change': remoteQty,
      'type': 'Sync Baseline',
      'reference': 'SYNC-BASELINE',
      'reason': 'Initial multi-device inventory baseline',
      'branch_id': branchId,
      'terminal_id': 'SYNC',
      'user_id': 'SYNC',
    });
    return 'Applied';
  }

  Future<String> _applyRemoteStockAdjustmentTx(
      DatabaseExecutor t, String entityId, Map<String, Object?> payload) async {
    final marker = await t.query('stock_movements',
        columns: ['id'],
        where: "reference=? AND type='Synced Adjustment'",
        whereArgs: [entityId],
        limit: 1);
    if (marker.isNotEmpty) return 'Applied';
    final productId = (payload['product_id'] ?? '').toString();
    final branchId = (payload['branch_id'] ?? '').toString();
    final change = (payload['qty_change'] as num? ?? 0).toDouble();
    if (productId.isEmpty || branchId.isEmpty || change == 0)
      throw Exception('Invalid stock adjustment sync payload.');
    if (change < 0) await _consumeLots(t, productId, branchId, -change);
    if (change > 0) {
      await t.insert('stock_lots', {
        'id': 'LOT-SYNC-ADJ-${_randomHex(8)}',
        'product_id': productId,
        'branch_id': branchId,
        'purchase_item_id': null,
        'batch_no': 'ADJ',
        'expiry_date': null,
        'received_qty': change,
        'remaining_qty': change,
        'unit_cost': (payload['unit_cost'] as num? ?? 0).toDouble(),
        'created_at':
            (payload['created_at'] ?? DateTime.now().toIso8601String())
                .toString(),
        'status': 'Open',
      });
    }
    await _changeBranchStock(t, productId, branchId, change);
    await t.insert('stock_movements', {
      'created_at': (payload['created_at'] ?? DateTime.now().toIso8601String())
          .toString(),
      'product_id': productId,
      'qty_change': change,
      'type': 'Synced Adjustment',
      'reference': entityId,
      'reason': (payload['reason'] ?? 'Remote stock adjustment').toString(),
      'branch_id': branchId,
      'terminal_id': 'SYNC',
      'user_id': 'SYNC',
    });
    return 'Applied';
  }

  Future<String> _applyRemoteRecipeDefinitionTx(DatabaseExecutor t,
      String parentProductId, Map<String, Object?> payload) async {
    final components = _payloadList(payload, 'components');
    await t.delete('recipe_components',
        where: 'parent_product_id=?', whereArgs: [parentProductId]);
    for (final component in components) {
      final row = Map<String, Object?>.from(component);
      row['parent_product_id'] = parentProductId;
      await t.insert('recipe_components', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return 'Applied';
  }

  Future<String> _applyRemoteSaleTx(
      DatabaseExecutor t, String saleId, Map<String, Object?> payload) async {
    final exists = await t.query('sales',
        columns: ['id'], where: 'id=?', whereArgs: [saleId], limit: 1);
    if (exists.isNotEmpty) return 'Applied';
    final rawSale = payload['sale'];
    if (rawSale is! Map)
      throw Exception('Sale sync payload is missing the sale header.');
    final sale = Map<String, Object?>.from(rawSale.cast<String, Object?>());
    await t.insert('sales', sale);
    for (final item in _payloadList(payload, 'items')) {
      final row = Map<String, Object?>.from(item)..remove('id');
      await t.insert('sale_items', row);
    }
    for (final td in _payloadList(payload, 'tenders')) {
      final row = Map<String, Object?>.from(td)..remove('id');
      await t.insert('sale_tenders', row);
    }
    for (final pay in _payloadList(payload, 'payments')) {
      await t.insert('payments', pay,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final allocation in _payloadList(payload, 'allocations')) {
      final row = Map<String, Object?>.from(allocation)..remove('id');
      final duplicate = await t.query('payment_allocations',
          columns: ['id'],
          where:
              'payment_id=? AND document_type=? AND document_id=? AND allocated_amount=?',
          whereArgs: [
            row['payment_id'],
            row['document_type'],
            row['document_id'],
            row['allocated_amount']
          ],
          limit: 1);
      if (duplicate.isEmpty) await t.insert('payment_allocations', row);
    }
    final branchId = (sale['branch_id'] ?? '').toString();
    for (final movement in _payloadList(payload, 'stock_effects')) {
      final pid = (movement['product_id'] ?? '').toString();
      final delta = (movement['qty_change'] as num? ?? 0).toDouble();
      if (pid.isEmpty || delta == 0 || branchId.isEmpty) continue;
      if (delta < 0) await _consumeLots(t, pid, branchId, -delta);
      await _changeBranchStock(t, pid, branchId, delta);
      final row = Map<String, Object?>.from(movement)..remove('id');
      await t.insert('stock_movements', row);
    }
    final customerId = (sale['customer_id'] ?? '').toString();
    final balance = (sale['balance'] as num? ?? 0).toDouble();
    if (customerId.isNotEmpty && balance > 0) {
      await t.rawUpdate(
          'UPDATE customers SET balance=COALESCE(balance,0)+? WHERE id=?',
          [balance, customerId]);
    }
    return 'Applied';
  }

  Future<String> _applyRemotePurchaseTx(DatabaseExecutor t, String purchaseId,
      Map<String, Object?> payload) async {
    final exists = await t.query('purchases',
        columns: ['id'], where: 'id=?', whereArgs: [purchaseId], limit: 1);
    if (exists.isNotEmpty) return 'Applied';
    final rawPurchase = payload['purchase'];
    if (rawPurchase is! Map)
      throw Exception('Purchase sync payload is missing the purchase header.');
    final purchase =
        Map<String, Object?>.from(rawPurchase.cast<String, Object?>());
    await t.insert('purchases', purchase);
    final sourceToLocalItem = <int, int>{};
    for (final item in _payloadList(payload, 'items')) {
      final sourceId = (item['id'] as num?)?.toInt();
      final row = Map<String, Object?>.from(item)..remove('id');
      final localId = await t.insert('purchase_items', row);
      if (sourceId != null) sourceToLocalItem[sourceId] = localId;
    }
    for (final lot in _payloadList(payload, 'lots')) {
      final row = Map<String, Object?>.from(lot);
      final sourceItemId = (row['purchase_item_id'] as num?)?.toInt();
      if (sourceItemId != null)
        row['purchase_item_id'] = sourceToLocalItem[sourceItemId];
      await t.insert('stock_lots', row,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final pay in _payloadList(payload, 'payments')) {
      await t.insert('payments', pay,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final allocation in _payloadList(payload, 'allocations')) {
      final row = Map<String, Object?>.from(allocation)..remove('id');
      final duplicate = await t.query('payment_allocations',
          columns: ['id'],
          where:
              'payment_id=? AND document_type=? AND document_id=? AND allocated_amount=?',
          whereArgs: [
            row['payment_id'],
            row['document_type'],
            row['document_id'],
            row['allocated_amount']
          ],
          limit: 1);
      if (duplicate.isEmpty) await t.insert('payment_allocations', row);
    }
    final branchId = (purchase['branch_id'] ?? '').toString();
    for (final movement in _payloadList(payload, 'stock_effects')) {
      final pid = (movement['product_id'] ?? '').toString();
      final delta = (movement['qty_change'] as num? ?? 0).toDouble();
      if (pid.isEmpty || delta == 0 || branchId.isEmpty) continue;
      await _changeBranchStock(t, pid, branchId, delta);
      final row = Map<String, Object?>.from(movement)..remove('id');
      await t.insert('stock_movements', row);
    }
    final costsRaw = payload['product_costs'];
    if (costsRaw is Map) {
      for (final e in costsRaw.entries) {
        final cost = e.value is num
            ? (e.value as num).toDouble()
            : double.tryParse('${e.value}');
        if (cost != null)
          await t.update('products',
              {'cost': cost, 'updated_at': DateTime.now().toIso8601String()},
              where: 'id=?', whereArgs: [e.key.toString()]);
      }
    }
    final supplierId = (purchase['supplier_id'] ?? '').toString();
    final balance = (purchase['balance'] as num? ?? 0).toDouble();
    if (supplierId.isNotEmpty && balance > 0) {
      await t.rawUpdate(
          'UPDATE suppliers SET balance=COALESCE(balance,0)+? WHERE id=?',
          [balance, supplierId]);
    }
    return 'Applied';
  }

  Future<String> _applyRemotePartyPaymentTx(
      DatabaseExecutor t, Map<String, Object?> payload,
      {required bool customer}) async {
    final rawPayment = payload['payment'];
    if (rawPayment is! Map)
      throw Exception('Payment sync payload is missing the payment row.');
    final payment =
        Map<String, Object?>.from(rawPayment.cast<String, Object?>());
    final paymentId = (payment['id'] ?? '').toString();
    if (paymentId.isEmpty) throw Exception('Payment ID is missing.');
    final exists = await t.query('payments',
        columns: ['id'], where: 'id=?', whereArgs: [paymentId], limit: 1);
    if (exists.isNotEmpty) return 'Applied';
    final partyId =
        (payload['party_id'] ?? payment['party_id'] ?? '').toString();
    final allocations = _payloadList(payload, 'allocations');
    for (final allocation in allocations) {
      final documentId = (allocation['document_id'] ?? '').toString();
      final amount = (allocation['allocated_amount'] as num? ?? 0).toDouble();
      if (documentId.isEmpty || amount <= 0) continue;
      final documentType =
          (allocation['document_type'] ?? (customer ? 'Sale' : 'Purchase'))
              .toString();
      if (documentType == 'Adjustment') {
        await t.rawUpdate(
            "UPDATE account_adjustments SET balance=MAX(COALESCE(balance,0)-?,0),status=CASE WHEN COALESCE(balance,0)-?<=0.000001 THEN 'Settled' ELSE status END WHERE id=?",
            [amount, amount, documentId]);
      } else if (customer) {
        await t.rawUpdate(
            "UPDATE sales SET paid=COALESCE(paid,0)+?,balance=MAX(COALESCE(balance,0)-?,0),status=CASE WHEN COALESCE(balance,0)-?<=0.000001 THEN 'Completed' ELSE 'Credit' END WHERE id=?",
            [amount, amount, amount, documentId]);
      } else {
        await t.rawUpdate(
            "UPDATE purchases SET paid=COALESCE(paid,0)+?,balance=MAX(COALESCE(balance,0)-?,0),status=CASE WHEN COALESCE(balance,0)-?<=0.000001 THEN 'Received' ELSE 'Partially Paid' END WHERE id=?",
            [amount, amount, amount, documentId]);
      }
    }
    await t.insert('payments', payment);
    for (final allocation in allocations) {
      final row = Map<String, Object?>.from(allocation)..remove('id');
      await t.insert('payment_allocations', row);
    }
    final applied = (payload['applied_amount'] as num? ?? 0).toDouble();
    final credit = (payload['credit_amount'] as num? ?? 0).toDouble();
    if (customer) {
      await t.rawUpdate(
          'UPDATE customers SET balance=MAX(COALESCE(balance,0)-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
          [applied, credit, partyId]);
    } else {
      await t.rawUpdate(
          'UPDATE suppliers SET balance=MAX(COALESCE(balance,0)-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
          [applied, credit, partyId]);
    }
    return 'Applied';
  }

  Future<bool> _syncTxnSeen(
      DatabaseExecutor t, String entityType, String entityId) async {
    final rows = await t.query('sync_transaction_guards',
        columns: ['event_id'],
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [entityType, entityId],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> _markSyncTxnApplied(DatabaseExecutor t, String entityType,
      String entityId, String eventId) async {
    await t.insert(
        'sync_transaction_guards',
        {
          'entity_type': entityType,
          'entity_id': entityId,
          'event_id': eventId,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> _canApplyNegativeStockEffects(
      DatabaseExecutor t, List<Map<String, Object?>> effects) async {
    final needed = <String, double>{};
    for (final e in effects) {
      final delta = (e['qty_change'] as num? ?? 0).toDouble();
      if (delta >= -0.000001) continue;
      final productId = (e['product_id'] ?? '').toString();
      final branchId = (e['branch_id'] ?? '').toString();
      if (productId.isEmpty || branchId.isEmpty) continue;
      final key = '$productId@$branchId';
      needed[key] = (needed[key] ?? 0) + (-delta);
    }
    for (final e in needed.entries) {
      final split = e.key.split('@');
      final have = await _branchQty(t, split[0], split.sublist(1).join('@'));
      if (have + 0.000001 < e.value) return false;
    }
    return true;
  }

  Future<void> _recordRuntimeSyncConflict(
      DatabaseExecutor t,
      String eventId,
      String entityType,
      String entityId,
      Map<String, Object?> payload,
      String reason) async {
    await t.insert(
        'sync_conflicts',
        {
          'id': _id('SCF'),
          'event_id': eventId,
          'entity_type': entityType,
          'entity_id': entityId,
          'local_payload': jsonEncode({'reason': reason}),
          'remote_payload': jsonEncode(payload),
          'detected_at': DateTime.now().toUtc().toIso8601String(),
          'status': 'Open',
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _applySyncedStockEffects(
      DatabaseExecutor t, List<Map<String, Object?>> effects,
      {String positiveBatch = 'SYNC'}) async {
    for (final effect in effects) {
      final pid = (effect['product_id'] ?? '').toString();
      final branchId = (effect['branch_id'] ?? '').toString();
      final delta = (effect['qty_change'] as num? ?? 0).toDouble();
      if (pid.isEmpty || branchId.isEmpty || delta.abs() <= 0.000001) continue;
      if (delta < 0) {
        await _consumeLots(t, pid, branchId, -delta);
      } else {
        final pRows = await t.query('products',
            columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
        await t.insert('stock_lots', {
          'id': _id('LOT'),
          'product_id': pid,
          'branch_id': branchId,
          'purchase_item_id': null,
          'batch_no': positiveBatch,
          'expiry_date': null,
          'received_qty': delta,
          'remaining_qty': delta,
          'unit_cost': pRows.isEmpty
              ? 0.0
              : (pRows.first['cost'] as num? ?? 0).toDouble(),
          'created_at':
              (effect['created_at'] ?? DateTime.now().toIso8601String())
                  .toString(),
          'status': 'Open',
        });
      }
      await _changeBranchStock(t, pid, branchId, delta);
      final row = Map<String, Object?>.from(effect)..remove('id');
      row['terminal_id'] = 'SYNC';
      row['user_id'] = 'SYNC';
      await t.insert('stock_movements', row);
    }
  }

  Future<String> _applyRemoteReversalLikeTx(DatabaseExecutor t, String eventId,
      String type, String entityId, Map<String, Object?> payload) async {
    if (await _syncTxnSeen(t, type, entityId)) return 'Applied';
    final effects = _payloadList(payload, 'stock_effects');
    if (!await _canApplyNegativeStockEffects(t, effects)) {
      await _recordRuntimeSyncConflict(t, eventId, type, entityId, payload,
          'Remote transaction would make branch stock negative. Review simultaneous sales/returns/voids before applying.');
      return 'Conflict';
    }
    if (type == 'sale_return_txn') {
      final h = payload['return'];
      if (h is! Map) throw Exception('Sale return payload missing header.');
      final header = Map<String, Object?>.from(h.cast<String, Object?>());
      final exists = await t.query('sales_returns',
          columns: ['id'], where: 'id=?', whereArgs: [entityId], limit: 1);
      if (exists.isEmpty) await t.insert('sales_returns', header);
      for (final item in _payloadList(payload, 'items')) {
        final r = Map<String, Object?>.from(item)..remove('id');
        await t.insert('sale_return_items', r);
      }
    } else if (type == 'purchase_return_txn') {
      final h = payload['return'];
      if (h is! Map) throw Exception('Purchase return payload missing header.');
      final header = Map<String, Object?>.from(h.cast<String, Object?>());
      final exists = await t.query('purchase_returns',
          columns: ['id'], where: 'id=?', whereArgs: [entityId], limit: 1);
      if (exists.isEmpty) await t.insert('purchase_returns', header);
      for (final item in _payloadList(payload, 'items')) {
        final r = Map<String, Object?>.from(item)..remove('id');
        await t.insert('purchase_return_items', r);
      }
    }
    await _applySyncedStockEffects(t, effects,
        positiveBatch: type.contains('void') ? 'VOID-SYNC' : 'RETURN-SYNC');
    for (final pay in _payloadList(payload, 'payments'))
      await t.insert('payments', pay,
          conflictAlgorithm: ConflictAlgorithm.ignore);
    final saleAfter = payload['sale_after'];
    if (saleAfter is Map) {
      final r = Map<String, Object?>.from(saleAfter.cast<String, Object?>())
        ..remove('id');
      await t.update('sales', r, where: 'id=?', whereArgs: [saleAfter['id']]);
    }
    final purchaseAfter = payload['purchase_after'];
    if (purchaseAfter is Map) {
      final r = Map<String, Object?>.from(purchaseAfter.cast<String, Object?>())
        ..remove('id');
      await t.update('purchases', r,
          where: 'id=?', whereArgs: [purchaseAfter['id']]);
    }
    final partyId = (payload['party_id'] ?? '').toString();
    final partyDelta = (payload['party_balance_delta'] as num? ?? 0).toDouble();
    if (partyId.isNotEmpty && partyDelta.abs() > 0.000001) {
      final table = (type.startsWith('sale_')) ? 'customers' : 'suppliers';
      await t.rawUpdate(
          'UPDATE $table SET balance=MAX(COALESCE(balance,0)+?,0) WHERE id=?',
          [partyDelta, partyId]);
    }
    final creditDelta = (payload['party_credit_delta'] as num? ?? 0).toDouble();
    if (partyId.isNotEmpty && creditDelta > 0) {
      final table = type.startsWith('sale_') ? 'customers' : 'suppliers';
      await t.rawUpdate(
          'UPDATE $table SET credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
          [creditDelta, partyId]);
    }
    for (final adjustment in _payloadList(payload, 'balance_adjustments')) {
      final table = type.startsWith('sale_') ? 'sales' : 'purchases';
      await t.rawUpdate(
          'UPDATE $table SET balance=MAX(COALESCE(balance,0)-?,0) WHERE id=?',
          [adjustment['amount'], adjustment['id']]);
    }
    await _markSyncTxnApplied(t, type, entityId, eventId);
    return 'Applied';
  }

  Future<String> _applyRemotePurchaseOrderTx(DatabaseExecutor t, String eventId,
      String entityId, Map<String, Object?> payload) async {
    final raw = payload['order'];
    if (raw is! Map) throw Exception('Purchase order payload missing order.');
    final order = Map<String, Object?>.from(raw.cast<String, Object?>());
    final exists = await t.query('purchase_orders',
        columns: ['id'], where: 'id=?', whereArgs: [entityId], limit: 1);
    if (exists.isEmpty) {
      await t.insert('purchase_orders', order);
      for (final item in _payloadList(payload, 'items')) {
        final r = Map<String, Object?>.from(item)..remove('id');
        await t.insert('purchase_order_items', r);
      }
    } else {
      final update = Map<String, Object?>.from(order)..remove('id');
      await t.update('purchase_orders', update,
          where: 'id=?', whereArgs: [entityId]);
      if (payload['items'] is List) {
        await t.delete('purchase_order_items',
            where: 'purchase_order_id=?', whereArgs: [entityId]);
        for (final item in _payloadList(payload, 'items')) {
          final r = Map<String, Object?>.from(item)..remove('id');
          await t.insert('purchase_order_items', r);
        }
      }
    }
    await _markSyncTxnApplied(t, 'purchase_order_state', entityId, eventId);
    return 'Applied';
  }

  Future<String> _applyRemoteStockTransferTx(DatabaseExecutor t, String eventId,
      String entityId, Map<String, Object?> payload) async {
    final raw = payload['transfer'];
    if (raw is! Map) throw Exception('Transfer payload missing header.');
    final transfer = Map<String, Object?>.from(raw.cast<String, Object?>());
    final remoteStatus = (transfer['status'] ?? 'Requested').toString();
    final existing = await t.query('stock_transfers',
        where: 'id=?', whereArgs: [entityId], limit: 1);
    final localStatus =
        existing.isEmpty ? '' : (existing.first['status'] ?? '').toString();
    const rank = {'Requested': 1, 'Sent': 2, 'Received': 3, 'Rejected': 3};
    if (existing.isNotEmpty &&
        (rank[localStatus] ?? 0) > (rank[remoteStatus] ?? 0)) return 'Ignored';
    final effects = _payloadList(payload, 'stock_effects');
    if (!await _canApplyNegativeStockEffects(t, effects)) {
      await _recordRuntimeSyncConflict(
          t,
          eventId,
          'stock_transfer_txn',
          entityId,
          payload,
          'Transfer state requires more source stock than is available locally.');
      return 'Conflict';
    }
    if (existing.isEmpty) {
      await t.insert('stock_transfers', transfer);
      for (final item in _payloadList(payload, 'items')) {
        final r = Map<String, Object?>.from(item)..remove('id');
        await t.insert('stock_transfer_items', r);
      }
    } else {
      final update = Map<String, Object?>.from(transfer)..remove('id');
      await t.update('stock_transfers', update,
          where: 'id=?', whereArgs: [entityId]);
    }
    if (payload['lots'] is List) {
      await t.delete('stock_transfer_lots',
          where: 'transfer_id=?', whereArgs: [entityId]);
      for (final lot in _payloadList(payload, 'lots')) {
        final r = Map<String, Object?>.from(lot)..remove('id');
        await t.insert('stock_transfer_lots', r);
      }
    }
    if (effects.isNotEmpty)
      await _applySyncedStockEffects(t, effects,
          positiveBatch: 'TRANSFER-SYNC');
    await _markSyncTxnApplied(
        t, 'stock_transfer_${remoteStatus.toLowerCase()}', entityId, eventId);
    return 'Applied';
  }

  Future<String> _applyRemoteStockCountTx(DatabaseExecutor t, String eventId,
      String entityId, Map<String, Object?> payload) async {
    if (await _syncTxnSeen(t, 'stock_count_txn', entityId)) return 'Applied';
    final effects = _payloadList(payload, 'stock_effects');
    if (!await _canApplyNegativeStockEffects(t, effects)) {
      await _recordRuntimeSyncConflict(
          t,
          eventId,
          'stock_count_txn',
          entityId,
          payload,
          'Remote physical count conflicts with local stock movement after the count was taken.');
      return 'Conflict';
    }
    final raw = payload['count'];
    if (raw is! Map) throw Exception('Stock count payload missing header.');
    final count = Map<String, Object?>.from(raw.cast<String, Object?>());
    final exists = await t.query('stock_counts',
        columns: ['id'], where: 'id=?', whereArgs: [entityId], limit: 1);
    if (exists.isEmpty) {
      await t.insert('stock_counts', count);
      for (final item in _payloadList(payload, 'items')) {
        final r = Map<String, Object?>.from(item)..remove('id');
        await t.insert('stock_count_items', r);
      }
    }
    await _applySyncedStockEffects(t, effects, positiveBatch: 'COUNT-SYNC');
    await _markSyncTxnApplied(t, 'stock_count_txn', entityId, eventId);
    return 'Applied';
  }

  Future<String> _applyRemoteHeldSaleTx(DatabaseExecutor t, String eventId,
      String entityId, Map<String, Object?> payload) async {
    final deleted = payload['deleted'] == true;
    if (deleted) {
      await t.delete('held_sale_items',
          where: 'held_sale_id=?', whereArgs: [entityId]);
      await t.delete('held_sales', where: 'id=?', whereArgs: [entityId]);
      return 'Applied';
    }
    final raw = payload['hold'];
    if (raw is! Map) throw Exception('Held-sale payload missing header.');
    final hold = Map<String, Object?>.from(raw.cast<String, Object?>());
    await t.insert('held_sales', hold,
        conflictAlgorithm: ConflictAlgorithm.replace);
    await t.delete('held_sale_items',
        where: 'held_sale_id=?', whereArgs: [entityId]);
    for (final item in _payloadList(payload, 'items')) {
      final r = Map<String, Object?>.from(item)..remove('id');
      await t.insert('held_sale_items', r);
    }
    return 'Applied';
  }

  Future<
      List<
          Map<String,
              Object?>>> openSyncConflicts({int limit = 100}) => db.rawQuery(
      "SELECT * FROM sync_conflicts WHERE status='Open' ORDER BY detected_at DESC LIMIT ?",
      [limit]);

  Future<void> resolveSyncConflict(String conflictId,
      {required String resolution}) async {
    if (!const {'Keep Local', 'Accept Remote', 'Dismiss'}.contains(resolution))
      throw Exception('Unsupported conflict resolution.');
    await db.transaction((t) async {
      final rows = await t.query('sync_conflicts',
          where: 'id=? AND status=\'Open\'', whereArgs: [conflictId], limit: 1);
      if (rows.isEmpty)
        throw Exception('Conflict not found or already resolved.');
      final c = rows.first;
      if (resolution == 'Accept Remote') {
        final type = (c['entity_type'] ?? '').toString();
        if (const {
          'branch',
          'product',
          'customer',
          'supplier',
          'customer_group',
          'customer_group_rule'
        }.contains(type)) {
          await t.delete('sync_entity_versions',
              where: 'entity_type=? AND entity_id=?',
              whereArgs: [type, c['entity_id']]);
        }
        final inbox = await t.query('sync_inbox',
            where: 'event_id=?', whereArgs: [c['event_id']], limit: 1);
        if (inbox.isNotEmpty) {
          await t.update('sync_inbox',
              {'status': 'Pending', 'error': null, 'applied_at': null},
              where: 'id=?', whereArgs: [inbox.first['id']]);
        }
      }
      await t.update(
          'sync_conflicts',
          {
            'status': 'Resolved',
            'resolution': resolution,
            'resolved_at': DateTime.now().toUtc().toIso8601String()
          },
          where: 'id=?',
          whereArgs: [conflictId]);
    });
  }

  Future<Map<String, String>> syncRuntimeState() async {
    final rows = await db.query('sync_state');
    return {
      for (final r in rows) (r['k'] ?? '').toString(): (r['v'] ?? '').toString()
    };
  }

  Future<void> setSyncRuntime(Map<String, String> values) async {
    await db.transaction((t) async {
      for (final e in values.entries) {
        await t.insert('sync_state', {'k': e.key, 'v': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> saveSyncCursor(String cursor) async =>
      db.insert('sync_state', {'k': 'server_cursor', 'v': cursor},
          conflictAlgorithm: ConflictAlgorithm.replace);
  Future<String> syncCursor() async {
    final rows = await db.query('sync_state',
        columns: ['v'], where: "k='server_cursor'", limit: 1);
    return rows.isEmpty ? '' : (rows.first['v'] ?? '').toString();
  }

  Future<void> updateDeviceRegistration(
      {required String serverDeviceId, String status = 'Registered'}) async {
    final identity = await syncIdentity();
    await db.update(
        'sync_devices',
        {
          'server_device_id': serverDeviceId,
          'status': status,
          'last_seen_at': DateTime.now().toUtc().toIso8601String()
        },
        where: 'device_id=?',
        whereArgs: [identity['device_id']]);
  }

  Future<Map<String, int>> syncQueueSummary() async {
    final rows = await db
        .rawQuery("SELECT status,COUNT(*) c FROM sync_outbox GROUP BY status");
    final inbox = await db
        .rawQuery("SELECT status,COUNT(*) c FROM sync_inbox GROUP BY status");
    final result = <String, int>{
      'Pending': 0,
      'Sending': 0,
      'Failed': 0,
      'Blocked': 0,
      'Synced': 0,
      'Incoming': 0,
      'Conflicts': 0
    };
    for (final r in rows)
      result[(r['status'] ?? 'Pending').toString()] =
          ((r['c'] as num?) ?? 0).toInt();
    result['Incoming'] = inbox
        .where((r) => (r['status'] ?? '').toString() == 'Pending')
        .fold(0, (sum, r) => sum + (((r['c'] as num?) ?? 0).toInt()));
    final conflicts = await db
        .rawQuery("SELECT COUNT(*) c FROM sync_conflicts WHERE status='Open'");
    result['Conflicts'] =
        conflicts.isEmpty ? 0 : ((conflicts.first['c'] as num?) ?? 0).toInt();
    return result;
  }

  Future<List<Map<String, Object?>>> recentSyncActivity({int limit = 100}) => db
      .rawQuery("SELECT * FROM sync_outbox ORDER BY id DESC LIMIT ?", [limit]);
  Future<List<Map<String, Object?>>> stagedIncoming({int limit = 100}) =>
      db.rawQuery("SELECT * FROM sync_inbox ORDER BY id DESC LIMIT ?", [limit]);

  Future<Map<String, String>> settings() async {
    final rows = await db.query('settings');
    return {
      for (final row in rows) row['k'] as String: (row['v'] ?? '').toString()
    };
  }

  Future<void> saveSettings(Map<String, String> values) async {
    await db.transaction((t) async {
      for (final e in values.entries) {
        await t.insert('settings', {'k': e.key, 'v': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _audit(
          t, 'Update settings', 'settings', 'business', values.keys.join(', '));
    });
  }

  Future<String> integrityCheck() async {
    final rows = await db.rawQuery('PRAGMA integrity_check');
    return rows.isEmpty ? 'No result' : rows.first.values.first.toString();
  }

  Future<String> backupTo(String directory,
      {bool enforcePermission = true}) async {
    if (enforcePermission)
      await requirePermission('backup_restore', 'create backups');
    final outDir = Directory(directory);
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final target = p.join(outDir.path, 'RELIQ_Backup_$stamp.db');
    final escaped = target.replaceAll("'", "''");
    await db.execute("VACUUM INTO '$escaped'");
    return target;
  }

  Future<String?> maybeAutomaticBackup() async {
    final values = await settings();
    if (values['auto_backup_enabled'] == '0') return null;
    final days = int.tryParse(values['backup_reminder_days'] ?? '1') ?? 1;
    final retention =
        int.tryParse(values['backup_retention_count'] ?? '14') ?? 14;
    final meta = await db.query('app_meta',
        columns: ['v'], where: "k='last_auto_backup_at'", limit: 1);
    if (meta.isNotEmpty) {
      final last = DateTime.tryParse((meta.first['v'] ?? '').toString());
      if (last != null &&
          DateTime.now().difference(last).inHours < (days.clamp(1, 365) * 24))
        return null;
    }
    final dir = Directory(p.join(await dataDir, 'backups'));
    final path = await backupTo(dir.path, enforcePermission: false);
    await db.insert('app_meta',
        {'k': 'last_auto_backup_at', 'v': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final files = dir.existsSync()
        ? dir
            .listSync()
            .whereType<File>()
            .where((f) =>
                p.basename(f.path).startsWith('RELIQ_Backup_') &&
                f.path.endsWith('.db'))
            .toList()
        : <File>[];
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in files.skip(retention.clamp(1, 100).toInt())) {
      try {
        await old.delete();
      } catch (_) {}
    }
    return path;
  }

  Future<void> restoreBackup(String sourcePath) async {
    await requirePermission('backup_restore', 'restore backups');
    final source = File(sourcePath);
    if (!await source.exists()) throw Exception('Backup file not found');
    final checkDb = await databaseFactory.openDatabase(sourcePath,
        options: OpenDatabaseOptions(readOnly: true));
    try {
      final result = await checkDb.rawQuery('PRAGMA integrity_check');
      final ok = result.isNotEmpty &&
          result.first.values.first.toString().toLowerCase() == 'ok';
      if (!ok) throw Exception('Selected backup failed SQLite integrity check');
    } finally {
      await checkDb.close();
    }
    final dir = await dataDir;
    final live = File(p.join(dir, 'reliq_solutions.db'));
    final safety = File(
        p.join(dir, 'pre_restore_${DateTime.now().millisecondsSinceEpoch}.db'));
    await db.execute('PRAGMA wal_checkpoint(FULL)');
    await _db?.close();
    _db = null;
    if (await live.exists()) await live.copy(safety.path);
    await source.copy(live.path);
    await open();
    await db.insert(
        'app_meta', {'k': 'last_restore_safety_backup', 'v': safety.path},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> expenseCategories(
      {bool activeOnly = true}) async {
    await _bootstrapMasterData(db);
    return db.query('expense_categories',
        where: activeOnly ? 'active=1' : null, orderBy: 'name COLLATE NOCASE');
  }

  Future<void> addExpenseCategory(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Category name is required');
    await db.insert('expense_categories', {'name': clean, 'active': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> setExpenseCategoryActive(int id, bool active) async {
    await db.update('expense_categories', {'active': active ? 1 : 0},
        where: 'id=?', whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> taxProfiles(
      {bool activeOnly = true}) async {
    await _bootstrapMasterData(db);
    return db.query('tax_profiles',
        where: activeOnly ? 'active=1' : null,
        orderBy: 'is_default DESC,name COLLATE NOCASE');
  }

  Future<void> saveTaxProfile(
      {required String code,
      required String name,
      required double rate,
      required bool inclusive,
      bool active = true,
      bool makeDefault = false}) async {
    final c = code.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_-]'), '_');
    if (c.isEmpty || name.trim().isEmpty)
      throw Exception('Tax code and name are required');
    if (rate < 0 || rate > 100)
      throw Exception('Tax rate must be between 0 and 100');
    await db.transaction((t) async {
      if (makeDefault) await t.update('tax_profiles', {'is_default': 0});
      await t.insert(
          'tax_profiles',
          {
            'code': c,
            'name': name.trim(),
            'rate': rate,
            'price_inclusive': inclusive ? 1 : 0,
            'active': active ? 1 : 0,
            'is_default': makeDefault ? 1 : 0
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _audit(t, 'Save tax profile', 'tax_profile', c,
          '${name.trim()} • ${rate.toStringAsFixed(3)}%');
    });
  }

  Future<void> setTaxProfileActive(String code, bool active) async {
    if (code == 'NONE' && !active)
      throw Exception('The No Tax profile must remain active');
    await db.update('tax_profiles', {'active': active ? 1 : 0},
        where: 'code=?', whereArgs: [code]);
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  Future<Map<String, Object?>> cashSummary(DateTime day) async {
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final key = _dateKey(day);
    final start = DateTime(day.year, day.month, day.day).toIso8601String();
    final end = DateTime(day.year, day.month, day.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    final sessions = await db.query('cash_sessions',
        where: 'session_date=? AND branch_id=?',
        whereArgs: [key, branchId],
        orderBy: 'opened_at DESC',
        limit: 1);
    final session = sessions.isEmpty ? <String, Object?>{} : sessions.first;
    final cashSales = await db.rawQuery(
        "SELECT COALESCE(SUM(paid),0) v FROM sales WHERE branch_id=? AND created_at>=? AND created_at<? AND LOWER(COALESCE(payment_method,''))='cash'",
        [branchId, start, end]);
    final customerCash = await db.rawQuery(
        "SELECT COALESCE(SUM(amount),0) v FROM payments WHERE branch_id=? AND party_type='Customer' AND COALESCE(document_type,'')<>'Sale' AND amount>0 AND created_at>=? AND created_at<? AND LOWER(COALESCE(method,''))='cash'",
        [branchId, start, end]);
    final supplierCash = await db.rawQuery(
        "SELECT COALESCE(SUM(amount),0) v FROM payments WHERE branch_id=? AND party_type='Supplier' AND amount>0 AND created_at>=? AND created_at<? AND LOWER(COALESCE(method,''))='cash'",
        [branchId, start, end]);
    final cashExpenses = await db.rawQuery(
        "SELECT COALESCE(SUM(amount+tax_amount),0) v FROM expenses WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<? AND LOWER(COALESCE(payment_method,''))='cash'",
        [branchId, start, end]);
    final moves = await db.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN kind IN ('Cash Added','Bank Withdrawal') THEN amount ELSE 0 END),0) cash_in, COALESCE(SUM(CASE WHEN kind IN ('Cash Removed','Bank Deposit') THEN amount ELSE 0 END),0) cash_out FROM cash_movements WHERE branch_id=? AND session_date=?",
        [branchId, key]);
    final opening = (session['opening_cash'] as num? ?? 0).toDouble();
    final inflow = (cashSales.first['v'] as num? ?? 0).toDouble() +
        (customerCash.first['v'] as num? ?? 0).toDouble() +
        (moves.first['cash_in'] as num? ?? 0).toDouble();
    final outflow = (supplierCash.first['v'] as num? ?? 0).toDouble() +
        (cashExpenses.first['v'] as num? ?? 0).toDouble() +
        (moves.first['cash_out'] as num? ?? 0).toDouble();
    final expected = opening + inflow - outflow;
    final actual = (session['closing_cash'] as num?)?.toDouble();
    return {
      ...session,
      'session_date': key,
      'cash_sales': (cashSales.first['v'] as num? ?? 0).toDouble(),
      'customer_cash': (customerCash.first['v'] as num? ?? 0).toDouble(),
      'supplier_cash': (supplierCash.first['v'] as num? ?? 0).toDouble(),
      'cash_expenses': (cashExpenses.first['v'] as num? ?? 0).toDouble(),
      'cash_added': (moves.first['cash_in'] as num? ?? 0).toDouble(),
      'cash_removed': (moves.first['cash_out'] as num? ?? 0).toDouble(),
      'expected_cash': expected,
      'variance': actual == null ? null : actual - expected
    };
  }

  Future<void> openCashDay(DateTime day, double openingCash,
      {String notes = ''}) async {
    if (openingCash < 0) throw Exception('Opening cash cannot be negative');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final key = _dateKey(day);
      final existing = await t.query('cash_sessions',
          where: 'session_date=? AND branch_id=?',
          whereArgs: [key, ctx['branch_id']],
          limit: 1);
      final id =
          existing.isEmpty ? _id('CASH') : existing.first['id'].toString();
      final values = <String, Object?>{
        'session_date': key,
        'opening_cash': openingCash,
        'opened_at': existing.isEmpty
            ? DateTime.now().toIso8601String()
            : existing.first['opened_at'],
        'notes': notes.trim(),
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      };
      if (existing.isEmpty) {
        await t.insert('cash_sessions', {'id': id, ...values});
      } else {
        await t.update('cash_sessions', values, where: 'id=?', whereArgs: [id]);
      }
      await _audit(
          t, 'Set opening cash', 'cash_session', id, '$key • $openingCash');
    });
  }

  Future<void> closeCashDay(DateTime day, double closingCash,
      {String notes = ''}) async {
    if (closingCash < 0) throw Exception('Closing cash cannot be negative');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final key = _dateKey(day);
      final existing = await t.query('cash_sessions',
          where: 'session_date=? AND branch_id=?',
          whereArgs: [key, ctx['branch_id']],
          limit: 1);
      if (existing.isEmpty)
        throw Exception('Enter opening cash before closing the day');
      final id = existing.first['id'].toString();
      await t.update(
          'cash_sessions',
          {
            'closing_cash': closingCash,
            'closed_at': DateTime.now().toIso8601String(),
            'notes': notes.trim()
          },
          where: 'id=?',
          whereArgs: [id]);
      await _audit(
          t, 'Close cash day', 'cash_session', id, '$key • $closingCash');
    });
  }

  Future<void> addCashMovement(
      {required DateTime day,
      required String kind,
      required double amount,
      String reference = '',
      String notes = ''}) async {
    if (amount <= 0) throw Exception('Amount must be greater than zero');
    const allowed = {
      'Cash Added',
      'Cash Removed',
      'Bank Withdrawal',
      'Bank Deposit'
    };
    if (!allowed.contains(kind)) throw Exception('Unsupported cash movement');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final id = _id('CMV');
      await t.insert('cash_movements', {
        'id': id,
        'created_at': DateTime.now().toIso8601String(),
        'session_date': _dateKey(day),
        'kind': kind,
        'amount': amount,
        'method': 'Cash',
        'reference': reference.trim(),
        'notes': notes.trim(),
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      });
      await _audit(
          t, kind, 'cash_movement', id, '$amount • ${reference.trim()}');
    });
  }

  Future<List<Map<String, Object?>>> cashMovements(DateTime day) async {
    final ctx = await operationalContext();
    return db.query('cash_movements',
        where: 'session_date=? AND branch_id=?',
        whereArgs: [_dateKey(day), ctx['branch_id']],
        orderBy: 'created_at DESC');
  }

  Future<Map<String, Object>> expensesPage(
      {int limit = 10,
      int offset = 0,
      String search = '',
      String category = 'All',
      String method = 'All',
      String sort = 'Newest',
      DateTime? from,
      DateTime? to}) async {
    final ctx = await operationalContext();
    final clauses = <String>["e.status='Active'", 'e.branch_id=?'];
    final args = <Object?>[ctx['branch_id']];
    if (search.trim().isNotEmpty) {
      final q = '%${search.trim()}%';
      clauses.add(
          '(e.description LIKE ? OR e.reference_no LIKE ? OR e.notes LIKE ?)');
      args.addAll([q, q, q]);
    }
    if (category != 'All') {
      clauses.add('e.category=?');
      args.add(category);
    }
    if (method != 'All') {
      clauses.add('e.payment_method=?');
      args.add(method);
    }
    if (from != null) {
      clauses.add('e.expense_date>=?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      clauses.add('e.expense_date<?');
      args.add(DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1))
          .toIso8601String());
    }
    final where = clauses.join(' AND ');
    final order = switch (sort) {
      'Oldest' => 'e.expense_date ASC',
      'Amount high' => 'e.amount DESC',
      'Amount low' => 'e.amount ASC',
      'Category' => 'e.category COLLATE NOCASE ASC, e.expense_date DESC',
      _ => 'e.expense_date DESC'
    };
    final count = await db.rawQuery(
        'SELECT COUNT(*) c FROM expenses e WHERE $where', args);
    final rows = await db.rawQuery(
        'SELECT e.* FROM expenses e WHERE $where ORDER BY $order LIMIT ? OFFSET ?',
        [...args, limit, offset]);
    return {'total': _firstIntValue(count) ?? 0, 'rows': rows};
  }

  Future<List<Map<String, Object?>>> reportDailySeries(
      DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id'];
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    return db.rawQuery('''
      WITH RECURSIVE dates(d) AS (
        SELECT date(?)
        UNION ALL
        SELECT date(d,'+1 day') FROM dates WHERE d<date(?,'-1 day')
      ),
      sales_daily AS (
        SELECT date(created_at) d,SUM(total) total,SUM(discount) discount
        FROM sales
        WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Completed')<>'Cancelled'
        GROUP BY date(created_at)
      ),
      sales_return_daily AS (
        SELECT date(created_at) d,SUM(total) total
        FROM sales_returns
        WHERE branch_id=? AND created_at>=? AND created_at<?
        GROUP BY date(created_at)
      ),
      purchase_daily AS (
        SELECT date(created_at) d,SUM(total) total
        FROM purchases
        WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Received')<>'Cancelled'
        GROUP BY date(created_at)
      ),
      purchase_return_daily AS (
        SELECT date(created_at) d,SUM(total) total
        FROM purchase_returns
        WHERE branch_id=? AND created_at>=? AND created_at<?
        GROUP BY date(created_at)
      ),
      expense_daily AS (
        SELECT date(expense_date) d,SUM(amount+tax_amount) total
        FROM expenses
        WHERE branch_id=? AND expense_date>=? AND expense_date<? AND status='Active'
        GROUP BY date(expense_date)
      ),
      margin_daily AS (
        SELECT date(s.created_at) d,SUM(si.line_total-si.tax-(si.cost*si.qty)) margin
        FROM sales s JOIN sale_items si ON si.sale_id=s.id
        WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'
        GROUP BY date(s.created_at)
      ),
      return_margin_daily AS (
        SELECT date(sr.created_at) d,SUM(sri.line_total-sri.tax-sri.cost) margin
        FROM sales_returns sr JOIN sale_return_items sri ON sri.return_id=sr.id
        WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<?
        GROUP BY date(sr.created_at)
      )
      SELECT dates.d day,
        COALESCE(sd.total,0)-COALESCE(srd.total,0) sales,
        COALESCE(pd.total,0)-COALESCE(prd.total,0) purchases,
        COALESCE(ed.total,0) expenses,
        COALESCE(md.margin,0)-COALESCE(sd.discount,0)-COALESCE(rmd.margin,0) gross_margin
      FROM dates
      LEFT JOIN sales_daily sd ON sd.d=dates.d
      LEFT JOIN sales_return_daily srd ON srd.d=dates.d
      LEFT JOIN purchase_daily pd ON pd.d=dates.d
      LEFT JOIN purchase_return_daily prd ON prd.d=dates.d
      LEFT JOIN expense_daily ed ON ed.d=dates.d
      LEFT JOIN margin_daily md ON md.d=dates.d
      LEFT JOIN return_margin_daily rmd ON rmd.d=dates.d
      ORDER BY dates.d
    ''', [
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
    ]);
  }

  Future<List<Map<String, Object?>>> reportDailySeriesFast(
      DateTime from, DateTime to,
      {String? branchIdOverride, bool forceRefresh = false}) async {
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id']!;
    final key = 'report:daily:v1:$branchId:${_dateKey(from)}:${_dateKey(to)}';
    if (!forceRefresh) {
      final snapshot = await _analyticsSnapshot(key);
      final cached = _decodeAnalyticsList(snapshot);
      if (cached != null) {
        if (_snapshotNeedsRefresh(snapshot!)) {
          unawaited(() async {
            try {
              final fresh =
                  await reportDailySeries(from, to, branchIdOverride: branchId);
              await _writeAnalyticsSnapshot(key, fresh);
            } catch (_) {}
          }());
        }
        return cached;
      }
    }
    final fresh = await reportDailySeries(from, to, branchIdOverride: branchId);
    await _writeAnalyticsSnapshot(key, fresh);
    return fresh;
  }

  Future<Map<String, num>> taxSummaryBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final branchId = (branchIdOverride ?? ctx['branch_id']!);
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    // One aggregate round-trip instead of five sequential queries.
    final rows = await db.rawQuery(r'''
      SELECT
        COALESCE((SELECT SUM(si.line_total-si.tax) FROM sale_items si JOIN sales s ON s.id=si.sale_id WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'),0) taxable_sales,
        COALESCE((SELECT SUM(si.tax) FROM sale_items si JOIN sales s ON s.id=si.sale_id WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'),0) output_tax,
        COALESCE((SELECT SUM(pi.line_total-pi.tax) FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id WHERE p.branch_id=? AND p.created_at>=? AND p.created_at<? AND COALESCE(p.status,'Received')<>'Cancelled'),0) taxable_purchases,
        COALESCE((SELECT SUM(pi.tax) FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id WHERE p.branch_id=? AND p.created_at>=? AND p.created_at<? AND COALESCE(p.status,'Received')<>'Cancelled'),0) purchase_input_tax,
        COALESCE((SELECT SUM(amount) FROM expenses WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?),0) taxable_expenses,
        COALESCE((SELECT SUM(tax_amount) FROM expenses WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?),0) expense_tax,
        COALESCE((SELECT SUM(sri.line_total-sri.tax) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<?),0) taxable_sales_returns,
        COALESCE((SELECT SUM(sri.tax) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<?),0) returned_output_tax,
        COALESCE((SELECT SUM(pri.line_total-pri.tax) FROM purchase_return_items pri JOIN purchase_returns pr ON pr.id=pri.return_id WHERE pr.branch_id=? AND pr.created_at>=? AND pr.created_at<?),0) taxable_purchase_returns,
        COALESCE((SELECT SUM(pri.tax) FROM purchase_return_items pri JOIN purchase_returns pr ON pr.id=pri.return_id WHERE pr.branch_id=? AND pr.created_at>=? AND pr.created_at<?),0) returned_purchase_tax
    ''', [
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
    ]);
    final r = rows.first;
    double n(String k) => (r[k] as num? ?? 0).toDouble();
    final output = n('output_tax') - n('returned_output_tax');
    final purchaseTax = n('purchase_input_tax') - n('returned_purchase_tax');
    final expenseTax = n('expense_tax');
    final input = purchaseTax + expenseTax;
    return {
      'taxableSales': n('taxable_sales') - n('taxable_sales_returns'),
      'outputTax': output,
      'taxablePurchases':
          n('taxable_purchases') - n('taxable_purchase_returns'),
      'taxableExpenses': n('taxable_expenses'),
      'purchaseInputTax': purchaseTax,
      'expenseInputTax': expenseTax,
      'inputTax': input,
      'netTax': output - input,
    };
  }

  Future<bool> canEditTransactions() async =>
      currentUserHasPermission('edit_posted_transactions');

  Future<Map<String, Object?>> saleCorrectionData(String id) async {
    final h = await db.rawQuery(
        'SELECT s.*,c.name customer_name,c.phone customer_phone,c.whatsapp customer_whatsapp,c.email customer_email,c.preferred_delivery customer_preferred_delivery FROM sales s LEFT JOIN customers c ON c.id=s.customer_id WHERE s.id=? LIMIT 1',
        [id]);
    if (h.isEmpty) throw Exception('Sale not found');
    final lines = await db.query('sale_items',
        where: 'sale_id=?', whereArgs: [id], orderBy: 'id');
    return {'header': h.first, 'lines': lines};
  }

  Future<Map<String, Object?>> purchaseCorrectionData(String id) async {
    final h = await db.rawQuery(
        'SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.id=? LIMIT 1',
        [id]);
    if (h.isEmpty) throw Exception('Purchase not found');
    final lines = await db.query('purchase_items',
        where: 'purchase_id=?', whereArgs: [id], orderBy: 'id');
    return {'header': h.first, 'lines': lines};
  }

  Future<Map<String, Object?>> purchaseDataByNo(String no) async {
    final h = await db.rawQuery(
        'SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.no=? LIMIT 1',
        [no]);
    if (h.isEmpty) throw Exception('Purchase not found');
    final id = h.first['id'].toString();
    final lines = await db.query('purchase_items',
        where: 'purchase_id=?', whereArgs: [id], orderBy: 'id');
    return {'header': h.first, 'lines': lines};
  }

  Future<void> reviseSaleFinancials(
      {required String saleId,
      required List<Map<String, Object?>> lines,
      required double invoiceDiscount,
      required double deliveryCharge,
      required double otherCharge,
      required String notes}) async {
    await requirePermission('edit_posted_transactions', 'edit posted invoices');
    await db.transaction((t) async {
      final existing =
          await t.query('sales', where: 'id=?', whereArgs: [saleId], limit: 1);
      if (existing.isEmpty) throw Exception('Sale not found');
      if ((existing.first['returned_total'] as num? ?? 0).toDouble() > 0)
        throw Exception(
            'Invoices with posted returns cannot be financially edited. Reverse the return first.');
      double subtotal = 0, itemDiscount = 0, tax = 0, exclusiveTax = 0;
      for (final line in lines) {
        final id = (line['id'] as num).toInt();
        final old = await t.query('sale_items',
            where: 'id=? AND sale_id=?', whereArgs: [id, saleId], limit: 1);
        if (old.isEmpty) continue;
        final qty = (old.first['qty'] as num? ?? 0).toDouble();
        final price = (line['unit_price'] as num? ?? 0).toDouble();
        final discount = (line['discount'] as num? ?? 0).toDouble();
        final lineTax = (line['tax'] as num? ?? 0).toDouble();
        final inclusive =
            ((old.first['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        if (price < 0 || discount < 0 || lineTax < 0 || discount > qty * price)
          throw Exception('Invalid line correction');
        final lineTotal = (qty * price - discount + (inclusive ? 0 : lineTax))
            .clamp(0, double.infinity)
            .toDouble();
        await t.update(
            'sale_items',
            {
              'unit_price': price,
              'discount': discount,
              'tax': lineTax,
              'line_total': lineTotal
            },
            where: 'id=?',
            whereArgs: [id]);
        subtotal += qty * price;
        itemDiscount += discount;
        tax += lineTax;
        if (!inclusive) exclusiveTax += lineTax;
      }
      final total = (subtotal -
              itemDiscount -
              invoiceDiscount +
              exclusiveTax +
              deliveryCharge +
              otherCharge)
          .clamp(0, double.infinity)
          .toDouble();
      final paid = (existing.first['paid'] as num? ?? 0).toDouble();
      if (total + 0.000001 < paid)
        throw Exception(
            'Corrected total cannot be lower than payments already recorded. Adjust/refund the payment first.');
      final oldBalance = (existing.first['balance'] as num? ?? 0).toDouble();
      final newBalance = (total - paid).clamp(0, double.infinity).toDouble();
      final customerId = (existing.first['customer_id'] ?? '').toString();
      if (customerId.isNotEmpty && (newBalance - oldBalance).abs() > 0.000001)
        await t.rawUpdate(
            'UPDATE customers SET balance=MAX(0,balance+?) WHERE id=?',
            [newBalance - oldBalance, customerId]);
      final ctx = await operationalContext(t);
      await t.update(
          'sales',
          {
            'subtotal': subtotal,
            'discount': invoiceDiscount,
            'tax': tax,
            'delivery_charge': deliveryCharge,
            'other_charge': otherCharge,
            'total': total,
            'paid': paid,
            'balance': newBalance,
            'status': newBalance > 0 ? 'Credit' : 'Completed',
            'notes': notes.trim(),
            'revision': ((existing.first['revision'] as num?) ?? 0).toInt() + 1,
            'edited_at': DateTime.now().toIso8601String(),
            'edited_by': ctx['user_id']
          },
          where: 'id=?',
          whereArgs: [saleId]);
      await _audit(t, 'Edit posted sale', 'sale', saleId,
          'Financial correction • total $total • quantities unchanged');
    });
  }

  Future<void> revisePurchaseFinancials(
      {required String purchaseId,
      required List<Map<String, Object?>> lines,
      required double freight,
      required double otherCharges,
      required String notes}) async {
    await requirePermission(
        'edit_posted_transactions', 'edit posted purchases');
    await db.transaction((t) async {
      final existing = await t.query('purchases',
          where: 'id=?', whereArgs: [purchaseId], limit: 1);
      if (existing.isEmpty) throw Exception('Purchase not found');
      double subtotal = 0, discount = 0, tax = 0, exclusiveTax = 0;
      for (final line in lines) {
        final id = (line['id'] as num).toInt();
        final old = await t.query('purchase_items',
            where: 'id=? AND purchase_id=?',
            whereArgs: [id, purchaseId],
            limit: 1);
        if (old.isEmpty) continue;
        final qty = (old.first['qty'] as num? ?? 0).toDouble();
        final cost = (line['unit_cost'] as num? ?? 0).toDouble();
        final lineDiscount = (line['discount'] as num? ?? 0).toDouble();
        final lineTax = (line['tax'] as num? ?? 0).toDouble();
        final inclusive =
            ((old.first['tax_inclusive'] as num?) ?? 0).toInt() == 1;
        if (cost < 0 ||
            lineDiscount < 0 ||
            lineTax < 0 ||
            lineDiscount > qty * cost)
          throw Exception('Invalid line correction');
        final lineTotal =
            (qty * cost - lineDiscount + (inclusive ? 0 : lineTax))
                .clamp(0, double.infinity)
                .toDouble();
        await t.update(
            'purchase_items',
            {
              'unit_cost': cost,
              'discount': lineDiscount,
              'tax': lineTax,
              'line_total': lineTotal
            },
            where: 'id=?',
            whereArgs: [id]);
        subtotal += qty * cost;
        discount += lineDiscount;
        tax += lineTax;
        if (!inclusive) exclusiveTax += lineTax;
      }
      final total =
          (subtotal - discount + exclusiveTax + freight + otherCharges)
              .clamp(0, double.infinity)
              .toDouble();
      final paid = (existing.first['paid'] as num? ?? 0).toDouble();
      if (total + 0.000001 < paid)
        throw Exception(
            'Corrected total cannot be lower than payments already recorded. Adjust the supplier payment first.');
      final oldBalance = (existing.first['balance'] as num? ?? 0).toDouble();
      final newBalance = (total - paid).clamp(0, double.infinity).toDouble();
      final supplierId = (existing.first['supplier_id'] ?? '').toString();
      if (supplierId.isNotEmpty && (newBalance - oldBalance).abs() > 0.000001)
        await t.rawUpdate(
            'UPDATE suppliers SET balance=MAX(0,balance+?) WHERE id=?',
            [newBalance - oldBalance, supplierId]);
      final ctx = await operationalContext(t);
      await t.update(
          'purchases',
          {
            'subtotal': subtotal,
            'discount': discount,
            'tax': tax,
            'freight': freight,
            'other_charges': otherCharges,
            'total': total,
            'paid': paid,
            'balance': newBalance,
            'status': newBalance > 0 ? 'Partially Paid' : 'Received',
            'notes': notes.trim(),
            'revision': ((existing.first['revision'] as num?) ?? 0).toInt() + 1,
            'edited_at': DateTime.now().toIso8601String(),
            'edited_by': ctx['user_id']
          },
          where: 'id=?',
          whereArgs: [purchaseId]);
      await _audit(t, 'Edit posted purchase', 'purchase', purchaseId,
          'Financial correction • total $total • quantities unchanged');
    });
  }

  Future<void> voidSale(String saleId, {String reason = 'Admin void'}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('void_transactions', 'void posted sales');
    await db.transaction((t) async {
      final saleRows =
          await t.query('sales', where: 'id=?', whereArgs: [saleId], limit: 1);
      if (saleRows.isEmpty) throw Exception('Sale not found');
      final sale = saleRows.first;
      if ((sale['status'] ?? '').toString() == 'Cancelled')
        throw Exception('Sale is already cancelled');
      final returns = _firstIntValue(await t.rawQuery(
              'SELECT COUNT(*) FROM sales_returns WHERE sale_id=?',
              [saleId])) ??
          0;
      if (returns > 0)
        throw Exception(
            'A sale with posted returns cannot be voided. Reverse/correct the return first.');
      final paid = (sale['paid'] as num? ?? 0).toDouble();
      final directPaidRows = await t.rawQuery(
          "SELECT COALESCE(SUM(amount),0) AS total FROM payments WHERE document_type='Sale' AND document_id=? AND amount>0",
          [saleId]);
      final directPaid =
          (directPaidRows.first['total'] as num? ?? 0).toDouble();
      if (paid > directPaid + 0.000001) {
        throw Exception(
            'This sale includes account-level payment allocation that cannot be safely auto-reversed. Use a financial correction/return instead.');
      }
      final ctx = await operationalContext(t);
      final lines =
          await t.query('sale_items', where: 'sale_id=?', whereArgs: [saleId]);
      for (final line in lines) {
        final pid = (line['product_id'] ?? '').toString();
        if (pid.isEmpty) continue;
        final qty = (line['qty'] as num? ?? 0).toDouble();
        final typeRows = await t.query('products',
            columns: ['product_type'],
            where: 'id=?',
            whereArgs: [pid],
            limit: 1);
        final type = typeRows.isEmpty
            ? 'Stocked'
            : (typeRows.first['product_type'] ?? 'Stocked').toString();
        if (type == 'Recipe' || type == 'Combo') {
          final components = await t.query('recipe_components',
              where: 'parent_product_id=?', whereArgs: [pid]);
          for (final c in components) {
            final cid = c['component_product_id'].toString();
            final restored = qty *
                (c['qty'] as num? ?? 0).toDouble() *
                (c['multiplier'] as num? ?? 1).toDouble();
            final lotProductRows = await t.query('products',
                columns: ['cost'], where: 'id=?', whereArgs: [cid], limit: 1);
            await t.insert('stock_lots', {
              'id': _id('LOT'),
              'product_id': cid,
              'branch_id': ctx['branch_id'],
              'purchase_item_id': null,
              'batch_no': 'VOID-RETURN',
              'expiry_date': null,
              'received_qty': restored,
              'remaining_qty': restored,
              'unit_cost': lotProductRows.isEmpty
                  ? 0.0
                  : (lotProductRows.first['cost'] as num? ?? 0).toDouble(),
              'created_at': DateTime.now().toIso8601String(),
              'status': 'Open'
            });
            await _changeBranchStock(t, cid, ctx['branch_id']!, restored);
            await t.insert('stock_movements', {
              'created_at': DateTime.now().toIso8601String(),
              'product_id': cid,
              'qty_change': restored,
              'type': 'Void Sale Restore',
              'reference': sale['no'],
              'reason': reason,
              'branch_id': ctx['branch_id'],
              'terminal_id': ctx['terminal_id'],
              'user_id': ctx['user_id']
            });
          }
        } else {
          final lotProductRows = await t.query('products',
              columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
          await t.insert('stock_lots', {
            'id': _id('LOT'),
            'product_id': pid,
            'branch_id': ctx['branch_id'],
            'purchase_item_id': null,
            'batch_no': 'VOID-RETURN',
            'expiry_date': null,
            'received_qty': qty,
            'remaining_qty': qty,
            'unit_cost': lotProductRows.isEmpty
                ? 0.0
                : (lotProductRows.first['cost'] as num? ?? 0).toDouble(),
            'created_at': DateTime.now().toIso8601String(),
            'status': 'Open'
          });
          await _changeBranchStock(t, pid, ctx['branch_id']!, qty);
          await t.insert('stock_movements', {
            'created_at': DateTime.now().toIso8601String(),
            'product_id': pid,
            'qty_change': qty,
            'type': 'Void Sale Restore',
            'reference': sale['no'],
            'reason': reason,
            'branch_id': ctx['branch_id'],
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id']
          });
        }
      }
      final customerId = (sale['customer_id'] ?? '').toString();
      final balance = (sale['balance'] as num? ?? 0).toDouble();
      if (customerId.isNotEmpty && balance > 0)
        await t.rawUpdate(
            'UPDATE customers SET balance=MAX(balance-?,0) WHERE id=?',
            [balance, customerId]);
      final payments = await t.query('payments',
          where: "document_type='Sale' AND document_id=? AND amount>0",
          whereArgs: [saleId]);
      for (final pay in payments) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': DateTime.now().toIso8601String(),
          'party_type': 'Customer',
          'party_id': customerId,
          'document_type': 'Sale Void',
          'document_id': saleId,
          'amount': -(pay['amount'] as num? ?? 0).toDouble(),
          'method': pay['method'],
          'reference': sale['no'],
          'notes': 'Reversal: $reason',
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await t.update(
          'sales',
          {
            'status': 'Cancelled',
            'balance': 0.0,
            'paid': 0.0,
            'notes': '${sale['notes'] ?? ''}\nVOID: $reason',
            'revision': ((sale['revision'] as num?) ?? 0).toInt() + 1,
            'edited_at': DateTime.now().toIso8601String(),
            'edited_by': ctx['user_id']
          },
          where: 'id=?',
          whereArgs: [saleId]);
      await _audit(t, 'Void sale', 'sale', saleId,
          '${sale['no']} • $reason • stock/payment/balance reversed');
      await _enqueueSyncEventTx(t,
          entityType: 'sale_void_txn',
          entityId: saleId,
          operation: 'void',
          payload: {
            'schema': 1,
            'sale_after': await _rowById(t, 'sales', saleId),
            'payments': await t.query('payments',
                where: "document_type='Sale Void' AND document_id=?",
                whereArgs: [saleId],
                orderBy: 'created_at,id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Void Sale Restore'",
                whereArgs: [sale['no']],
                orderBy: 'id'),
            'party_id': customerId,
            'party_balance_delta': -balance,
            'reason': reason
          });
    });
  }

  Future<void> voidPurchase(String purchaseId,
      {String reason = 'Admin void'}) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    await requirePermission('void_transactions', 'void posted purchases');
    await db.transaction((t) async {
      final rows = await t.query('purchases',
          where: 'id=?', whereArgs: [purchaseId], limit: 1);
      if (rows.isEmpty) throw Exception('Purchase not found');
      final purchase = rows.first;
      if ((purchase['status'] ?? '').toString() == 'Cancelled')
        throw Exception('Purchase is already cancelled');
      final returns = _firstIntValue(await t.rawQuery(
              'SELECT COUNT(*) FROM purchase_returns WHERE purchase_id=?',
              [purchaseId])) ??
          0;
      if (returns > 0)
        throw Exception(
            'A purchase with posted supplier returns cannot be voided.');
      final paid = (purchase['paid'] as num? ?? 0).toDouble();
      final directPaidRows = await t.rawQuery(
          "SELECT COALESCE(SUM(amount),0) AS total FROM payments WHERE document_type='Purchase' AND document_id=? AND amount>0",
          [purchaseId]);
      final directPaid =
          (directPaidRows.first['total'] as num? ?? 0).toDouble();
      if (paid > directPaid + 0.000001) {
        throw Exception(
            'This purchase includes account-level payment allocation that cannot be safely auto-reversed. Use a financial correction/supplier return instead.');
      }
      final ctx = await operationalContext(t);
      final lines = await t.query('purchase_items',
          where: 'purchase_id=?', whereArgs: [purchaseId]);
      for (final line in lines) {
        final pid = (line['product_id'] ?? '').toString();
        final qty = (line['qty'] as num? ?? 0).toDouble();
        final stocks = await t.query('branch_stock',
            columns: ['qty'],
            where: 'product_id=? AND branch_id=?',
            whereArgs: [pid, ctx['branch_id']],
            limit: 1);
        final available = stocks.isEmpty
            ? 0.0
            : (stocks.first['qty'] as num? ?? 0).toDouble();
        if (available + 0.000001 < qty)
          throw Exception(
              'Cannot void: ${line['name']} has only ${available.toStringAsFixed(2)} in stock but this purchase added ${qty.toStringAsFixed(2)}. Use a supplier return/correction instead.');
      }
      for (final line in lines) {
        final pid = (line['product_id'] ?? '').toString();
        final qty = (line['qty'] as num? ?? 0).toDouble();
        await _consumePurchaseItemLots(
            t, (line['id'] as num).toInt(), pid, ctx['branch_id']!, qty);
        await _changeBranchStock(t, pid, ctx['branch_id']!, -qty);
        await t.insert('stock_movements', {
          'created_at': DateTime.now().toIso8601String(),
          'product_id': pid,
          'qty_change': -qty,
          'type': 'Void Purchase',
          'reference': purchase['no'],
          'reason': reason,
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      final supplierId = (purchase['supplier_id'] ?? '').toString();
      final balance = (purchase['balance'] as num? ?? 0).toDouble();
      if (supplierId.isNotEmpty && balance > 0)
        await t.rawUpdate(
            'UPDATE suppliers SET balance=MAX(balance-?,0) WHERE id=?',
            [balance, supplierId]);
      final payments = await t.query('payments',
          where: "document_type='Purchase' AND document_id=? AND amount>0",
          whereArgs: [purchaseId]);
      for (final pay in payments) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': DateTime.now().toIso8601String(),
          'party_type': 'Supplier',
          'party_id': supplierId,
          'document_type': 'Purchase Void',
          'document_id': purchaseId,
          'amount': -(pay['amount'] as num? ?? 0).toDouble(),
          'method': pay['method'],
          'reference': purchase['no'],
          'notes': 'Reversal: $reason',
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await t.update(
          'purchases',
          {
            'status': 'Cancelled',
            'balance': 0.0,
            'paid': 0.0,
            'notes': '${purchase['notes'] ?? ''}\nVOID: $reason',
            'revision': ((purchase['revision'] as num?) ?? 0).toInt() + 1,
            'edited_at': DateTime.now().toIso8601String(),
            'edited_by': ctx['user_id']
          },
          where: 'id=?',
          whereArgs: [purchaseId]);
      await _audit(t, 'Void purchase', 'purchase', purchaseId,
          '${purchase['no']} • $reason • stock/payment/balance reversed');
      await _enqueueSyncEventTx(t,
          entityType: 'purchase_void_txn',
          entityId: purchaseId,
          operation: 'void',
          payload: {
            'schema': 1,
            'purchase_after': await _rowById(t, 'purchases', purchaseId),
            'payments': await t.query('payments',
                where: "document_type='Purchase Void' AND document_id=?",
                whereArgs: [purchaseId],
                orderBy: 'created_at,id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Void Purchase'",
                whereArgs: [purchase['no']],
                orderBy: 'id'),
            'party_id': supplierId,
            'party_balance_delta': -balance,
            'reason': reason
          });
    });
  }

  Future<void> createExpense({
    required DateTime date,
    required String category,
    required String description,
    required double amount,
    double taxAmount = 0,
    String taxCode = 'NONE',
    String paymentMethod = 'Cash',
    String reference = '',
    String notes = '',
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('expenses', 'record expenses');
    if (category.trim().isEmpty)
      throw Exception('Expense category is required');
    if (amount <= 0)
      throw Exception('Expense amount must be greater than zero');
    if (taxAmount < 0) throw Exception('Tax amount cannot be negative');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final id = _id('EXP');
      await t.insert('expenses', {
        'id': id,
        'expense_date': date.toIso8601String(),
        'category': category.trim(),
        'description': description.trim(),
        'amount': amount,
        'tax_amount': taxAmount,
        'tax_code': taxCode.trim().isEmpty ? 'NONE' : taxCode.trim(),
        'payment_method': paymentMethod,
        'reference_no': reference.trim(),
        'notes': notes.trim(),
        'status': 'Active',
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      await _audit(
          t, 'Create expense', 'expense', id, '${category.trim()} • $amount');
    });
  }

  Future<List<Map<String, Object?>>> expenses({int limit = 300}) => db.query(
        'expenses',
        where: "status='Active'",
        orderBy: 'expense_date DESC',
        limit: limit,
      );

  Future<Map<String, num>> reportSummaryBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final branchId = (branchIdOverride ?? ctx['branch_id']!);
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();

    // V2.2.3: one SQLite round-trip for the report header instead of a chain
    // of independent aggregate queries. This matters on multi-year databases.
    final rows = await db.rawQuery(r'''
      WITH
      sales_agg AS (
        SELECT COALESCE(SUM(total),0) total, COALESCE(SUM(balance),0) balance,
               COUNT(*) count, COALESCE(AVG(total),0) avg_invoice, COALESCE(SUM(discount),0) discounts
        FROM sales WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Completed')<>'Cancelled'
      ),
      purchase_agg AS (
        SELECT COALESCE(SUM(total),0) total, COALESCE(SUM(balance),0) balance,
               COUNT(*) count, COALESCE(SUM(discount),0) discounts
        FROM purchases WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Received')<>'Cancelled'
      ),
      margin_agg AS (
        SELECT COALESCE(SUM(si.line_total-si.tax-(si.cost*si.qty)),0) margin
        FROM sale_items si JOIN sales s ON s.id=si.sale_id
        WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'
      ),
      expense_agg AS (
        SELECT COALESCE(SUM(amount+tax_amount),0) value FROM expenses
        WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?
      ),
      stock_agg AS (
        SELECT COALESCE(SUM(bs.qty*p.cost),0) value FROM branch_stock bs JOIN products p ON p.id=bs.product_id WHERE bs.branch_id=?
      ),
      sales_return_agg AS (
        SELECT COALESCE(SUM(total),0) value FROM sales_returns WHERE branch_id=? AND created_at>=? AND created_at<?
      ),
      purchase_return_agg AS (
        SELECT COALESCE(SUM(total),0) value FROM purchase_returns WHERE branch_id=? AND created_at>=? AND created_at<?
      ),
      return_margin_agg AS (
        SELECT COALESCE(SUM(sri.line_total-sri.tax-sri.cost),0) value
        FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id
        WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<?
      ),
      overdue_receivable AS (
        SELECT COALESCE(SUM(balance),0) value FROM sales
        WHERE branch_id=? AND balance>0 AND due_date IS NOT NULL AND datetime(due_date)<datetime('now')
      ),
      overdue_payable AS (
        SELECT COALESCE(SUM(balance),0) value FROM purchases
        WHERE branch_id=? AND balance>0 AND due_date IS NOT NULL AND datetime(due_date)<datetime('now')
      )
      SELECT sa.total sales_total,sa.balance sales_balance,sa.count sales_count,sa.avg_invoice,sa.discounts sales_discounts,
             pa.total purchase_total,pa.balance purchase_balance,pa.count purchase_count,pa.discounts purchase_discounts,
             ma.margin raw_margin,ea.value expenses,st.value stock_value,sr.value sales_returns,pr.value purchase_returns,
             rm.value return_margin,ore.value overdue_receivable,opa.value overdue_payable
      FROM sales_agg sa,purchase_agg pa,margin_agg ma,expense_agg ea,stock_agg st,sales_return_agg sr,
           purchase_return_agg pr,return_margin_agg rm,overdue_receivable ore,overdue_payable opa
    ''', [
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      branchId,
    ]);
    final row = rows.first;
    double n(String key) => (row[key] as num? ?? 0).toDouble();
    final grossMargin =
        n('raw_margin') - n('sales_discounts') - n('return_margin');
    final expensesValue = n('expenses');
    return {
      'sales': n('sales_total') - n('sales_returns'),
      'salesDue': n('sales_balance'),
      'purchases': n('purchase_total') - n('purchase_returns'),
      'purchaseDue': n('purchase_balance'),
      'grossMargin': grossMargin,
      'expenses': expensesValue,
      'netAfterExpenses': grossMargin - expensesValue,
      'stockValue': n('stock_value'),
      'overdueReceivable': n('overdue_receivable'),
      'overduePayable': n('overdue_payable'),
      'salesCount': n('sales_count'),
      'avgInvoice': n('avg_invoice'),
      'salesDiscounts': n('sales_discounts'),
      'purchaseCount': n('purchase_count'),
      'purchaseDiscounts': n('purchase_discounts'),
      'salesReturns': n('sales_returns'),
      'purchaseReturns': n('purchase_returns'),
    };
  }

  Future<Map<String, num>> reportSummaryFast(DateTime from, DateTime to,
      {String? branchIdOverride, bool forceRefresh = false}) async {
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id']!;
    final startKey = _dateKey(from);
    final endKey = _dateKey(to);
    final key = 'report:summary:v1:$branchId:$startKey:$endKey';
    if (!forceRefresh) {
      final snapshot = await _analyticsSnapshot(key);
      final decoded = _decodeAnalyticsMap(snapshot);
      if (decoded != null) {
        final cached = <String, num>{
          for (final e in decoded.entries) e.key: (e.value as num? ?? 0)
        };
        if (_snapshotNeedsRefresh(snapshot!)) {
          unawaited(() async {
            try {
              final fresh = await reportSummaryBetween(from, to,
                  branchIdOverride: branchId);
              await _writeAnalyticsSnapshot(key, fresh);
            } catch (_) {}
          }());
        }
        return cached;
      }
    }
    final fresh =
        await reportSummaryBetween(from, to, branchIdOverride: branchId);
    await _writeAnalyticsSnapshot(key, fresh);
    return fresh;
  }

  Future<List<Map<String, Object?>>> profitLossBetween(
      DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id']!;
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    num value(List<Map<String, Object?>> rows, String key) =>
        rows.isEmpty ? 0 : (rows.first[key] as num? ?? 0);

    final financialRows = await db.rawQuery(r'''
      SELECT
        COALESCE((SELECT SUM(si.line_total-si.tax) FROM sale_items si JOIN sales s ON s.id=si.sale_id WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'),0) gross_sales,
        COALESCE((SELECT SUM(si.cost*si.qty) FROM sale_items si JOIN sales s ON s.id=si.sale_id WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? AND COALESCE(s.status,'Completed')<>'Cancelled'),0) cogs,
        COALESCE((SELECT SUM(discount) FROM sales WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Completed')<>'Cancelled'),0) discounts,
        COALESCE((SELECT SUM(delivery_charge) FROM sales WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Completed')<>'Cancelled'),0) delivery_charges,
        COALESCE((SELECT SUM(other_charge) FROM sales WHERE branch_id=? AND created_at>=? AND created_at<? AND COALESCE(status,'Completed')<>'Cancelled'),0) other_charges,
        COALESCE((SELECT SUM(sri.line_total-sri.tax) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<? AND COALESCE(sr.status,'Posted')<>'Cancelled'),0) returned_sales,
        COALESCE((SELECT SUM(sri.cost) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sr.branch_id=? AND sr.created_at>=? AND sr.created_at<? AND COALESCE(sr.status,'Posted')<>'Cancelled'),0) returned_cogs
    ''', [
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
      branchId,
      start,
      end,
    ]);
    final expenseRows = await db.rawQuery('''
      SELECT COALESCE(NULLIF(TRIM(category),''),'Other') category,COALESCE(SUM(amount),0) amount
      FROM expenses
      WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?
      GROUP BY COALESCE(NULLIF(TRIM(category),''),'Other') ORDER BY amount DESC,category
    ''', [branchId, start, end]);

    final grossSales = value(financialRows, 'gross_sales').toDouble();
    final discounts = value(financialRows, 'discounts').toDouble();
    final salesReturns = value(financialRows, 'returned_sales').toDouble();
    final deliveryCharges = value(financialRows, 'delivery_charges').toDouble();
    final otherCharges = value(financialRows, 'other_charges').toDouble();
    final netProductSales = grossSales - discounts - salesReturns;
    final otherOperatingIncome = deliveryCharges + otherCharges;
    final operatingRevenue = netProductSales + otherOperatingIncome;
    final cogs = value(financialRows, 'cogs').toDouble();
    final returnedCogs = value(financialRows, 'returned_cogs').toDouble();
    final netCogs = cogs - returnedCogs;
    final grossProfit = netProductSales - netCogs;
    final operatingProfitBeforeExpenses = grossProfit + otherOperatingIncome;
    final operatingExpenses = expenseRows.fold<double>(
        0, (sum, row) => sum + (row['amount'] as num? ?? 0).toDouble());
    final netProfit = operatingProfitBeforeExpenses - operatingExpenses;
    final grossMarginPct =
        netProductSales > 0 ? grossProfit / netProductSales * 100 : 0.0;
    final netMarginPct =
        operatingRevenue > 0 ? netProfit / operatingRevenue * 100 : 0.0;

    return <Map<String, Object?>>[
      {
        'section': 'Revenue',
        'metric': 'Gross product sales',
        'value': grossSales,
        'kind': 'money'
      },
      {
        'section': 'Revenue',
        'metric': 'Less: invoice discounts',
        'value': -discounts,
        'kind': 'money'
      },
      {
        'section': 'Revenue',
        'metric': 'Less: sales returns',
        'value': -salesReturns,
        'kind': 'money'
      },
      {
        'section': 'Revenue',
        'metric': 'Net product sales',
        'value': netProductSales,
        'kind': 'total'
      },
      {
        'section': 'Cost of Goods Sold',
        'metric': 'COGS on sales',
        'value': cogs,
        'kind': 'money'
      },
      {
        'section': 'Cost of Goods Sold',
        'metric': 'Less: COGS reversed on returns',
        'value': -returnedCogs,
        'kind': 'money'
      },
      {
        'section': 'Cost of Goods Sold',
        'metric': 'Net cost of goods sold',
        'value': netCogs,
        'kind': 'total'
      },
      {
        'section': 'Gross Profit',
        'metric': 'Gross profit',
        'value': grossProfit,
        'kind': 'total'
      },
      {
        'section': 'Gross Profit',
        'metric': 'Gross margin %',
        'value': grossMarginPct,
        'kind': 'percent'
      },
      {
        'section': 'Other Operating Income',
        'metric': 'Delivery charges',
        'value': deliveryCharges,
        'kind': 'money'
      },
      {
        'section': 'Other Operating Income',
        'metric': 'Other sales charges',
        'value': otherCharges,
        'kind': 'money'
      },
      {
        'section': 'Other Operating Income',
        'metric': 'Total other operating income',
        'value': otherOperatingIncome,
        'kind': 'total'
      },
      for (final row in expenseRows)
        {
          'section': 'Operating Expenses',
          'metric': '${row['category']}',
          'value': (row['amount'] as num? ?? 0).toDouble(),
          'kind': 'money'
        },
      {
        'section': 'Operating Expenses',
        'metric': 'Total operating expenses',
        'value': operatingExpenses,
        'kind': 'total'
      },
      {
        'section': 'Net Profit / Loss',
        'metric': 'Net profit / loss',
        'value': netProfit,
        'kind': 'grand_total'
      },
      {
        'section': 'Net Profit / Loss',
        'metric': 'Net margin %',
        'value': netMarginPct,
        'kind': 'percent'
      },
    ];
  }

  Future<List<Map<String, Object?>>> salesBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    return db.rawQuery(
        'SELECT s.*,c.name customer_name FROM sales s LEFT JOIN customers c ON c.id=s.customer_id WHERE s.branch_id=? AND s.created_at>=? AND s.created_at<? ORDER BY s.created_at DESC',
        [branchIdOverride ?? ctx['branch_id'], start, end]);
  }

  Future<List<Map<String, Object?>>> purchasesBetween(
      DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    return db.rawQuery(
        'SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.branch_id=? AND p.created_at>=? AND p.created_at<? ORDER BY p.created_at DESC',
        [branchIdOverride ?? ctx['branch_id'], start, end]);
  }

  Future<List<Map<String, Object?>>> expensesBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final start = DateTime(from.year, from.month, from.day).toIso8601String();
    final end = DateTime(to.year, to.month, to.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    return db.query('expenses',
        where:
            "branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?",
        whereArgs: [branchIdOverride ?? ctx['branch_id'], start, end],
        orderBy: 'expense_date DESC');
  }

  Future<List<Map<String, Object?>>> returnsBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final start = from.toIso8601String();
    final end = to.add(const Duration(days: 1)).toIso8601String();
    final branchId =
        (branchIdOverride ?? (await operationalContext())['branch_id']);
    return db.rawQuery('''
      SELECT r.no,r.created_at,r.total,r.refund_amount,r.refund_method,r.status,r.notes,
             'Customer Return' return_type,COALESCE(s.no,r.source_reference,'No invoice linked') source_no,r.id return_id,r.sale_id original_id,r.party_id,COALESCE(c.name,'Walk-in customer') counterparty
      FROM sales_returns r
      LEFT JOIN sales s ON s.id=r.sale_id
      LEFT JOIN customers c ON c.id=COALESCE(s.customer_id,r.party_id)
      WHERE r.branch_id=? AND r.created_at>=? AND r.created_at<?
      UNION ALL
      SELECT pr.no,pr.created_at,pr.total,pr.refund_amount,pr.refund_method,pr.status,pr.notes,
             'Supplier Return' return_type,COALESCE(p.no,pr.source_reference,'No invoice linked') source_no,pr.id return_id,pr.purchase_id original_id,pr.party_id,COALESCE(sp.name,'Supplier') counterparty
      FROM purchase_returns pr
      LEFT JOIN purchases p ON p.id=pr.purchase_id
      LEFT JOIN suppliers sp ON sp.id=COALESCE(p.supplier_id,pr.party_id)
      WHERE pr.branch_id=? AND pr.created_at>=? AND pr.created_at<?
      ORDER BY 2 DESC
    ''', [branchId, start, end, branchId, start, end]);
  }

  Future<List<Map<String, Object?>>> receivablesBetween(
      DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final start = from.toIso8601String();
    final end = to.add(const Duration(days: 1)).toIso8601String();
    return db.rawQuery('''
      SELECT s.*,c.name customer_name,
             CASE WHEN s.due_date IS NOT NULL AND datetime(s.due_date)<datetime('now') THEN 1 ELSE 0 END overdue
      FROM sales s
      LEFT JOIN customers c ON c.id=s.customer_id
      WHERE s.branch_id=? AND s.balance>0 AND s.created_at>=? AND s.created_at<?
      ORDER BY s.due_date ASC,s.created_at DESC
    ''', [
      (branchIdOverride ?? (await operationalContext())['branch_id']),
      start,
      end
    ]);
  }

  Future<List<Map<String, Object?>>> payablesBetween(DateTime from, DateTime to,
      {String? branchIdOverride}) async {
    final start = from.toIso8601String();
    final end = to.add(const Duration(days: 1)).toIso8601String();
    return db.rawQuery('''
      SELECT p.*,s.name supplier_name,
             CASE WHEN p.due_date IS NOT NULL AND datetime(p.due_date)<datetime('now') THEN 1 ELSE 0 END overdue
      FROM purchases p
      LEFT JOIN suppliers s ON s.id=p.supplier_id
      WHERE p.branch_id=? AND p.balance>0 AND p.created_at>=? AND p.created_at<?
      ORDER BY p.due_date ASC,p.created_at DESC
    ''', [
      (branchIdOverride ?? (await operationalContext())['branch_id']),
      start,
      end
    ]);
  }

  Future<List<Map<String, Object?>>> inventoryReport(
      {String? branchIdOverride}) async {
    final ctx = await operationalContext();
    final branchId = (branchIdOverride ?? ctx['branch_id']!);
    return db.rawQuery('''
      SELECT p.*,COALESCE(bs.qty,0) branch_stock,
             CASE
               WHEN COALESCE(bs.qty,0)<=0 THEN 'Out of Stock'
               WHEN COALESCE(bs.qty,0)<=p.min_stock THEN 'Low Stock'
               ELSE 'Healthy'
             END stock_status,
             (COALESCE(bs.qty,0)*p.cost) inventory_value
      FROM products p
      LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=?
      WHERE COALESCE(p.product_type,'Stocked')='Stocked'
      ORDER BY p.name COLLATE NOCASE
    ''', [branchId]);
  }

  Future<List<Map<String, Object?>>> inventoryIntelligence({
    int lookbackDays = 30,
    String? branchIdOverride,
    bool forceRefresh = false,
  }) async {
    final days = lookbackDays <= 0 ? 30 : lookbackDays;
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id']!;
    final key = 'inventory:v3:$branchId:$days';
    if (!forceRefresh) {
      final row = await _analyticsSnapshot(key);
      final cached = _decodeAnalyticsList(row);
      if (cached != null) {
        if (_snapshotNeedsRefresh(row!))
          unawaited(_refreshInventorySnapshot(key, days, branchId));
        return cached;
      }
    }
    return _refreshInventorySnapshot(key, days, branchId);
  }

  Future<List<Map<String, Object?>>> _refreshInventorySnapshot(
      String key, int days, String branchId) {
    final running = _inventoryRefreshes[key];
    if (running != null) return running;
    final future = () async {
      try {
        final value = await _calculateInventoryIntelligence(
            lookbackDays: days, branchIdOverride: branchId);
        await _writeAnalyticsSnapshot(key, value);
        return value;
      } finally {
        _inventoryRefreshes.remove(key);
      }
    }();
    _inventoryRefreshes[key] = future;
    return future;
  }

  Future<List<Map<String, Object?>>> _calculateInventoryIntelligence(
      {int lookbackDays = 30, String? branchIdOverride}) async {
    final days = lookbackDays <= 0 ? 30 : lookbackDays;
    final ctx = await operationalContext();
    final branchId = branchIdOverride ?? ctx['branch_id']!;
    final config = await settings();
    final autoFillLevels = config['forecast_auto_fill_stock_levels'] != '0';
    final useLastYearSeasonality =
        config['forecast_use_last_year_seasonality'] != '0';
    final targetCoverageDays =
        (int.tryParse(config['target_coverage_days'] ?? '21') ?? 21)
            .clamp(1, 365);

    final rows = await db.rawQuery('''
      WITH sold AS (
        SELECT si.product_id,
               COALESCE(SUM(si.qty),0) sold_qty,
               COALESCE(SUM(si.line_total),0) sales_value,
               COUNT(DISTINCT si.sale_id) sale_transactions,
               MAX(s.created_at) last_sale_at
        FROM sale_items si
        JOIN sales s ON s.id=si.sale_id
        WHERE s.branch_id=? AND s.created_at>=datetime('now', ?)
          AND COALESCE(s.status,'Completed')<>'Cancelled'
        GROUP BY si.product_id
      ),
      previous_sold AS (
        SELECT si.product_id,
               COALESCE(SUM(si.qty),0) previous_sold_qty,
               COUNT(DISTINCT si.sale_id) previous_sale_transactions
        FROM sale_items si
        JOIN sales s ON s.id=si.sale_id
        WHERE s.branch_id=?
          AND s.created_at>=datetime('now', ?)
          AND s.created_at<datetime('now', ?)
          AND COALESCE(s.status,'Completed')<>'Cancelled'
        GROUP BY si.product_id
      ),
      all_sales AS (
        SELECT si.product_id,MAX(s.created_at) last_sale_at
        FROM sale_items si
        JOIN sales s ON s.id=si.sale_id
        WHERE s.branch_id=? AND COALESCE(s.status,'Completed')<>'Cancelled'
        GROUP BY si.product_id
      ),
      bought AS (
        SELECT pi.product_id,
               COALESCE(SUM(pi.qty),0) bought_qty,
               MAX(p.created_at) last_purchase_at
        FROM purchase_items pi
        JOIN purchases p ON p.id=pi.purchase_id
        WHERE p.branch_id=? AND p.created_at>=datetime('now', ?)
          AND COALESCE(p.status,'Received')<>'Cancelled'
        GROUP BY pi.product_id
      ),
      lot_expiry_base AS (
        SELECT sl.product_id,sl.expiry_date,SUM(sl.remaining_qty) expiry_qty
        FROM stock_lots sl
        WHERE sl.branch_id=? AND sl.remaining_qty>0.000001
          AND sl.expiry_date IS NOT NULL AND TRIM(sl.expiry_date)<>''
        GROUP BY sl.product_id,sl.expiry_date
      ),
      expiry AS (
        SELECT b.product_id,b.expiry_date nearest_expiry,b.expiry_qty nearest_expiry_qty
        FROM lot_expiry_base b
        WHERE b.expiry_date=(SELECT MIN(x.expiry_date) FROM lot_expiry_base x WHERE x.product_id=b.product_id)
      ),
      incoming AS (
        SELECT poi.product_id,
               COALESCE(SUM(MAX(poi.ordered_qty-poi.received_qty,0)),0) incoming_qty
        FROM purchase_order_items poi
        JOIN purchase_orders po ON po.id=poi.purchase_order_id
        WHERE po.branch_id=? AND po.status IN ('Ordered','Partially Received')
        GROUP BY poi.product_id
      )
      SELECT p.id,p.name,p.sku,p.internal_barcode,p.external_barcode,p.category,p.unit,
             p.cost,p.price,p.min_stock,p.target_stock,p.supplier,p.track_expiry,p.expiry_date,
             p.purchase_moq,p.order_multiple,p.case_pack,p.purchasable,p.lifecycle_status,p.replacement_product_id,
             COALESCE(bs.qty,0) stock,
             COALESCE(incoming.incoming_qty,0) incoming_qty,
             COALESCE(sold.sold_qty,0) sold_qty,
             COALESCE(sold.sales_value,0) sales_value,
             COALESCE(sold.sale_transactions,0) sale_transactions,
             COALESCE(previous_sold.previous_sold_qty,0) previous_sold_qty,
             COALESCE(previous_sold.previous_sale_transactions,0) previous_sale_transactions,
             all_sales.last_sale_at,
             sold.last_sale_at recent_last_sale_at,
             COALESCE(bought.bought_qty,0) bought_qty,
             bought.last_purchase_at,
             COALESCE(expiry.nearest_expiry,p.expiry_date) nearest_expiry,
             COALESCE(expiry.nearest_expiry_qty,CASE WHEN p.expiry_date IS NOT NULL THEN COALESCE(bs.qty,0) ELSE 0 END) nearest_expiry_qty,
             COALESCE((SELECT lead_days FROM suppliers sp WHERE sp.name=p.supplier AND sp.active=1 LIMIT 1),7) lead_days
      FROM products p
      LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=?
      LEFT JOIN sold ON sold.product_id=p.id
      LEFT JOIN previous_sold ON previous_sold.product_id=p.id
      LEFT JOIN all_sales ON all_sales.product_id=p.id
      LEFT JOIN bought ON bought.product_id=p.id
      LEFT JOIN expiry ON expiry.product_id=p.id
      LEFT JOIN incoming ON incoming.product_id=p.id
      WHERE p.active=1 AND COALESCE(p.product_type,'Stocked')='Stocked'
      ORDER BY p.name COLLATE NOCASE
    ''', [
      branchId,
      '-$days day',
      branchId,
      '-${days * 2} day',
      '-$days day',
      branchId,
      branchId,
      '-$days day',
      branchId,
      branchId,
      branchId
    ]);

    final dailyRows = await db.rawQuery('''
      SELECT si.product_id,date(s.created_at) sale_day,
             COALESCE(SUM(si.qty),0) qty,
             COUNT(DISTINCT si.sale_id) tx
      FROM sale_items si
      JOIN sales s ON s.id=si.sale_id
      WHERE s.branch_id=? AND s.created_at>=datetime('now','-460 day')
        AND COALESCE(s.status,'Completed')<>'Cancelled'
      GROUP BY si.product_id,date(s.created_at)
      ORDER BY sale_day
    ''', [branchId]);

    final dailyByProduct = <String, Map<String, double>>{};
    final transactionsByProduct = <String, int>{};
    for (final row in dailyRows) {
      final productId = '${row['product_id']}';
      final day = '${row['sale_day']}';
      dailyByProduct.putIfAbsent(productId, () => <String, double>{})[day] =
          (row['qty'] as num? ?? 0).toDouble();
      transactionsByProduct[productId] =
          (transactionsByProduct[productId] ?? 0) +
              (row['tx'] as num? ?? 0).toInt();
    }

    final lifecycleRows = await db.query('products', columns: [
      'id',
      'replacement_product_id',
      'demand_family',
      'inherit_predecessor_history',
      'lifecycle_status',
      'active'
    ]);
    final lifecycleById = <String, Map<String, Object?>>{
      for (final row in lifecycleRows) '${row['id']}': row
    };
    final predecessorsByReplacement = <String, List<String>>{};
    final familyMembers = <String, List<String>>{};
    for (final row in lifecycleRows) {
      final id = '${row['id']}';
      final replacement = (row['replacement_product_id'] ?? '').toString();
      final inherit =
          ((row['inherit_predecessor_history'] as num?) ?? 1).toInt() == 1;
      final status = (row['lifecycle_status'] ?? 'Active').toString();
      if (replacement.isNotEmpty && inherit && status != 'Active') {
        predecessorsByReplacement.putIfAbsent(replacement, () => []).add(id);
      }
      final family =
          (row['demand_family'] ?? '').toString().trim().toLowerCase();
      if (family.isNotEmpty)
        familyMembers.putIfAbsent(family, () => []).add(id);
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String dayKey(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    double qtyOn(Map<String, double> history, DateTime d) =>
        history[dayKey(d)] ?? 0.0;
    double sumPeriod(Map<String, double> history, DateTime start, int length) {
      var total = 0.0;
      for (var i = 0; i < length; i++)
        total += qtyOn(history, start.add(Duration(days: i)));
      return total;
    }

    double mean(List<double> values) =>
        values.isEmpty ? 0.0 : values.reduce((a, b) => a + b) / values.length;
    double stdDev(List<double> values) {
      if (values.length < 2) return 0.0;
      final m = mean(values);
      final variance =
          values.fold<double>(0, (sum, v) => sum + pow(v - m, 2).toDouble()) /
              (values.length - 1);
      return sqrt(variance);
    }

    double clampFactor(double value, double low, double high) =>
        value.clamp(low, high).toDouble();
    List<double>? solveRidge(List<List<double>> x, List<double> y,
        {double lambda = .35}) {
      if (x.isEmpty || y.length != x.length) return null;
      final k = x.first.length;
      final a = List.generate(k, (_) => List<double>.filled(k + 1, 0));
      for (var r = 0; r < x.length; r++) {
        for (var i = 0; i < k; i++) {
          for (var j = 0; j < k; j++) a[i][j] += x[r][i] * x[r][j];
          a[i][k] += x[r][i] * y[r];
        }
      }
      for (var i = 1; i < k; i++) a[i][i] += lambda;
      for (var col = 0; col < k; col++) {
        var pivot = col;
        for (var r = col + 1; r < k; r++) {
          if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
        }
        if (a[pivot][col].abs() < 1e-9) return null;
        if (pivot != col) {
          final tmp = a[col];
          a[col] = a[pivot];
          a[pivot] = tmp;
        }
        final divisor = a[col][col];
        for (var j = col; j <= k; j++) a[col][j] /= divisor;
        for (var r = 0; r < k; r++) {
          if (r == col) continue;
          final factor = a[r][col];
          for (var j = col; j <= k; j++) a[r][j] -= factor * a[col][j];
        }
      }
      return List<double>.generate(k, (i) => a[i][k]);
    }

    final base = rows.map((r) {
      final productId = '${r['id']}';
      final ownHistory = dailyByProduct[productId] ?? const <String, double>{};
      final ownTransactions = transactionsByProduct[productId] ?? 0;
      final history = <String, double>{...ownHistory};
      final predecessorIds =
          predecessorsByReplacement[productId] ?? const <String>[];
      final predecessorWeight = ownTransactions < 5
          ? .85
          : ownTransactions < 15
              ? .60
              : ownTransactions < 30
                  ? .35
                  : .15;
      for (final predecessorId in predecessorIds) {
        final predecessorHistory =
            dailyByProduct[predecessorId] ?? const <String, double>{};
        for (final entry in predecessorHistory.entries) {
          history.putIfAbsent(entry.key, () => entry.value * predecessorWeight);
        }
      }
      final family = (lifecycleById[productId]?['demand_family'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      var familySupportUsed = false;
      if (family.isNotEmpty && ownTransactions < 12 && predecessorIds.isEmpty) {
        final siblings =
            (familyMembers[family] ?? const <String>[]).where((id) {
          if (id == productId) return false;
          final row = lifecycleById[id];
          final status = (row?['lifecycle_status'] ?? 'Active').toString();
          return status != 'Active';
        }).toList();
        if (siblings.isNotEmpty) {
          final dayTotals = <String, double>{};
          for (final siblingId in siblings) {
            for (final entry
                in (dailyByProduct[siblingId] ?? const <String, double>{})
                    .entries) {
              dayTotals[entry.key] = (dayTotals[entry.key] ?? 0) + entry.value;
            }
          }
          final familyWeight = ownTransactions == 0 ? .30 : .15;
          for (final entry in dayTotals.entries) {
            history.putIfAbsent(entry.key, () => entry.value * familyWeight);
          }
          familySupportUsed = dayTotals.isNotEmpty;
        }
      }
      final stock = (r['stock'] as num? ?? 0).toDouble();
      final previousSold = (r['previous_sold_qty'] as num? ?? 0).toDouble();
      final transactions = (r['sale_transactions'] as num? ?? 0).toInt();
      final configuredMin = (r['min_stock'] as num? ?? 0)
          .toDouble()
          .clamp(0, double.infinity)
          .toDouble();
      final configuredTarget = (r['target_stock'] as num? ?? 0)
          .toDouble()
          .clamp(0, double.infinity)
          .toDouble();

      final last7 =
          sumPeriod(history, today.subtract(const Duration(days: 7)), 7);
      final last14 =
          sumPeriod(history, today.subtract(const Duration(days: 14)), 14);
      final prior14 =
          sumPeriod(history, today.subtract(const Duration(days: 28)), 14);
      final last30 =
          sumPeriod(history, today.subtract(const Duration(days: 30)), 30);
      final prior30 =
          sumPeriod(history, today.subtract(const Duration(days: 60)), 30);
      final last90 =
          sumPeriod(history, today.subtract(const Duration(days: 90)), 90);
      final last365 =
          sumPeriod(history, today.subtract(const Duration(days: 365)), 365);
      final yearRecent30 =
          sumPeriod(history, today.subtract(const Duration(days: 395)), 30);
      final sellingDays90 = List<double>.generate(
          90, (i) => qtyOn(history, today.subtract(Duration(days: 90 - i))));
      final nonZero90 = sellingDays90.where((v) => v > 0).length;
      final variability = stdDev(sellingDays90);
      final recent30Daily = last30 / 30.0;
      final recent7Daily = last7 / 7.0;
      final recent90Daily = last90 / 90.0;

      final nonZeroIndexes = <int>[];
      final nonZeroQty = <double>[];
      for (var i = 0; i < sellingDays90.length; i++) {
        if (sellingDays90[i] > 0) {
          nonZeroIndexes.add(i);
          nonZeroQty.add(sellingDays90[i]);
        }
      }
      var crostonDaily = 0.0;
      if (nonZeroIndexes.length >= 2) {
        final intervals = <double>[];
        for (var i = 1; i < nonZeroIndexes.length; i++)
          intervals.add((nonZeroIndexes[i] - nonZeroIndexes[i - 1]).toDouble());
        final avgInterval = mean(intervals).clamp(1.0, 90.0).toDouble();
        crostonDaily = mean(nonZeroQty) / avgInterval;
      } else if (nonZeroIndexes.length == 1) {
        crostonDaily = nonZeroQty.first / 90.0;
      }

      var baseDaily = recent30Daily * .42 +
          recent7Daily * .28 +
          recent90Daily * .20 +
          crostonDaily * .10;
      if (last90 <= 0 && last30 > 0) baseDaily = recent30Daily;
      final trendRatio =
          prior14 > 0 ? last14 / prior14 : (last14 > 0 ? 1.15 : 1.0);
      final trendFactor = clampFactor(trendRatio, .70, 1.35);
      baseDaily *= (.72 + .28 * trendFactor);

      final weekdayTotals = List<double>.filled(7, 0);
      final weekdayCounts = List<int>.filled(7, 0);
      for (var i = 0; i < 90; i++) {
        final d = today.subtract(Duration(days: 90 - i));
        final idx = d.weekday - 1;
        weekdayTotals[idx] += sellingDays90[i];
        weekdayCounts[idx]++;
      }
      final weekdayAverages = List<double>.generate(
          7,
          (i) =>
              weekdayCounts[i] == 0 ? 0 : weekdayTotals[i] / weekdayCounts[i]);
      final overallWeekdayAverage =
          mean(weekdayAverages.where((v) => v > 0).toList());

      final firstSaleDay =
          history.keys.isEmpty ? null : (history.keys.toList()..sort()).first;
      final firstSaleDate =
          firstSaleDay == null ? null : DateTime.tryParse(firstSaleDay);
      final historySpanDays = firstSaleDate == null
          ? 0
          : today.difference(firstSaleDate).inDays.clamp(0, 460);
      final inheritedTransactions = predecessorIds.fold<int>(
          0, (sum, id) => sum + (transactionsByProduct[id] ?? 0));
      final allTransactions = max(
          transactions,
          ownTransactions +
              (inheritedTransactions * predecessorWeight).round());
      final hasYearHistory = useLastYearSeasonality && historySpanDays >= 330;
      final annualDaily = last365 / 365.0;

      double regressionForecast(int horizon) {
        if (historySpanDays < 120 || horizon <= 0) return 0.0;
        final trainDays = min(historySpanDays, 365).toInt();
        final start = today.subtract(Duration(days: trainDays));
        final x = <List<double>>[];
        final y = <double>[];
        for (var i = 0; i < trainDays; i++) {
          final d = start.add(Duration(days: i));
          final t = i / max(trainDays - 1, 1);
          x.add([
            1.0,
            t,
            sin(2 * pi * d.weekday / 7.0),
            cos(2 * pi * d.weekday / 7.0),
            sin(2 * pi * d.difference(DateTime(d.year, 1, 1)).inDays / 365.25),
            cos(2 * pi * d.difference(DateTime(d.year, 1, 1)).inDays / 365.25),
          ]);
          y.add(qtyOn(history, d));
        }
        final beta = solveRidge(x, y);
        if (beta == null) return 0.0;
        var total = 0.0;
        for (var i = 0; i < horizon; i++) {
          final d = today.add(Duration(days: i));
          final t = (trainDays + i) / max(trainDays - 1, 1);
          final features = [
            1.0,
            t,
            sin(2 * pi * d.weekday / 7.0),
            cos(2 * pi * d.weekday / 7.0),
            sin(2 * pi * d.difference(DateTime(d.year, 1, 1)).inDays / 365.25),
            cos(2 * pi * d.difference(DateTime(d.year, 1, 1)).inDays / 365.25),
          ];
          var prediction = 0.0;
          for (var j = 0; j < beta.length; j++)
            prediction += beta[j] * features[j];
          total += prediction.clamp(0, double.infinity).toDouble();
        }
        return total;
      }

      double forecastFor(int horizon) {
        if (horizon <= 0) return 0.0;
        var weekdayFactor = 1.0;
        if (overallWeekdayAverage > 0 && nonZero90 >= 4) {
          var weekdayExpected = 0.0;
          for (var i = 0; i < horizon; i++)
            weekdayExpected +=
                weekdayAverages[today.add(Duration(days: i)).weekday - 1];
          final neutral = overallWeekdayAverage * horizon;
          if (neutral > 0)
            weekdayFactor = clampFactor(weekdayExpected / neutral, .78, 1.22);
        }
        var currentPattern = baseDaily * horizon * weekdayFactor;
        final regression = regressionForecast(horizon);
        if (regression > 0)
          currentPattern = currentPattern * .78 + regression * .22;
        if (!hasYearHistory)
          return currentPattern.clamp(0, double.infinity).toDouble();

        final lastYearStart = today.subtract(const Duration(days: 365));
        final lastYearEquivalent = sumPeriod(history, lastYearStart, horizon);
        var growthFactor = 1.0;
        if (yearRecent30 > 0 && last30 > 0)
          growthFactor = clampFactor(last30 / yearRecent30, .60, 1.60);
        final seasonalProjection = lastYearEquivalent * growthFactor;
        if (lastYearEquivalent <= 0)
          return currentPattern.clamp(0, double.infinity).toDouble();
        final seasonalWeight = horizon <= 7
            ? .22
            : horizon <= 30
                ? .34
                : .42;
        return (currentPattern * (1 - seasonalWeight) +
                seasonalProjection * seasonalWeight)
            .clamp(0, double.infinity)
            .toDouble();
      }

      final forecast7 = forecastFor(7);
      final forecast30 = forecastFor(30);
      final forecast60 = forecastFor(60);
      final forecast90 = forecastFor(90);
      final forecastDaily = forecast30 > 0 ? forecast30 / 30.0 : baseDaily;
      final samePeriodLastYear30 = hasYearHistory
          ? sumPeriod(history, today.subtract(const Duration(days: 365)), 30)
          : 0.0;
      final seasonalityFactor = annualDaily > 0 && samePeriodLastYear30 > 0
          ? clampFactor((samePeriodLastYear30 / 30.0) / annualDaily, .50, 1.80)
          : 1.0;

      final confidenceScore = (min(historySpanDays / 365.0, 1.0) * 34 +
              min(allTransactions / 24.0, 1.0) * 28 +
              min(nonZero90 / 18.0, 1.0) * 20 +
              (hasYearHistory ? 18 : 0))
          .clamp(0, 100)
          .round();
      String confidence = 'Insufficient';
      if (confidenceScore >= 75)
        confidence = 'High';
      else if (confidenceScore >= 48)
        confidence = 'Medium';
      else if (confidenceScore >= 22) confidence = 'Low';

      double? trendPct;
      String demandSignal = 'No demand data';
      if (last30 <= 0 && prior30 <= 0)
        demandSignal = 'No recent sales';
      else if (prior30 <= 0 && last30 > 0)
        demandSignal = confidence == 'Low' ? 'Demand emerging' : 'New demand';
      else if (last30 <= 0 && prior30 > 0) {
        trendPct = -100;
        demandSignal = 'Demand stopped';
      } else {
        trendPct = ((last30 - prior30) / prior30) * 100.0;
        if (trendPct >= 25)
          demandSignal = 'Demand rising';
        else if (trendPct <= -25)
          demandSignal = 'Demand falling';
        else
          demandSignal = 'Demand stable';
      }

      int? daysSinceSale;
      final lastSale = DateTime.tryParse((r['last_sale_at'] ?? '').toString());
      if (lastSale != null)
        daysSinceSale = DateTime.now().difference(lastSale).inDays;

      final lifecycleStatus = (r['lifecycle_status'] ?? 'Active').toString();
      final purchasable = (r['purchasable'] as num? ?? 1).toInt() == 1;
      final stockDiscrepancy = stock < -0.001;
      final usableOnHand = max(stock, 0.0);
      final seasonalEvidence = hasYearHistory &&
          samePeriodLastYear30 > 0 &&
          seasonalityFactor >= 1.15;
      String demandState;
      if (lifecycleStatus != 'Active') {
        demandState = 'Discontinued / replaced';
      } else if (daysSinceSale == null) {
        demandState = ownTransactions == 0
            ? 'New / insufficient history'
            : 'No recent demand';
      } else if (daysSinceSale > 365) {
        demandState = 'Dormant';
      } else if (daysSinceSale > 180) {
        demandState = seasonalEvidence ? 'Seasonal review' : 'Dormant';
      } else if (daysSinceSale > 90) {
        demandState =
            seasonalEvidence ? 'Seasonal review' : 'Declining / review';
      } else if (last90 > 0 && nonZero90 <= 3) {
        demandState = 'Intermittent';
      } else if (trendPct != null && trendPct <= -25) {
        demandState = 'Declining';
      } else {
        demandState = 'Active demand';
      }
      final autoPurchaseEligible = purchasable &&
          lifecycleStatus == 'Active' &&
          !stockDiscrepancy &&
          daysSinceSale != null &&
          (daysSinceSale <= 90 || (seasonalEvidence && daysSinceSale <= 180));

      final leadDays = (r['lead_days'] as num? ?? 7).toDouble();
      final effectiveLead = leadDays <= 0 ? 7.0 : leadDays;
      final leadHorizon = effectiveLead.ceil().clamp(1, 365).toInt();
      final leadDemand = forecastFor(leadHorizon);
      final safetyStock =
          max(leadDemand * .15, 1.65 * variability * sqrt(effectiveLead))
              .clamp(0, double.infinity)
              .toDouble();
      final autoMinStock = (leadDemand + safetyStock).ceilToDouble();
      final autoTargetStock = max(
              autoMinStock,
              forecastFor((leadHorizon + targetCoverageDays)
                      .clamp(1, 365)
                      .toInt()) +
                  safetyStock)
          .ceilToDouble();
      final reliableForecast = confidence == 'High' || confidence == 'Medium';
      final effectiveMin = reliableForecast ? autoMinStock : configuredMin;
      final effectiveTarget = reliableForecast
          ? autoTargetStock
          : max(configuredTarget, configuredMin);
      final recommendedStock =
          effectiveTarget > 0 ? effectiveTarget : autoTargetStock;
      final targetSource = reliableForecast
          ? (hasYearHistory
              ? 'Adaptive forecast + last-year seasonality'
              : 'Adaptive forecast')
          : configuredTarget > 0
              ? 'Configured target (limited history)'
              : configuredMin > 0
                  ? 'Configured minimum (limited history)'
                  : 'Limited demand estimate';

      final incoming = (r['incoming_qty'] as num? ?? 0)
          .toDouble()
          .clamp(0, double.infinity)
          .toDouble();
      final inventoryPosition = usableOnHand + incoming;
      final coverage = forecastDaily > 0 ? usableOnHand / forecastDaily : -1.0;
      final rawSuggested = (recommendedStock - inventoryPosition)
          .clamp(0, double.infinity)
          .toDouble();
      final moq = (r['purchase_moq'] as num? ?? 0).toDouble();
      final configuredMultiple = (r['order_multiple'] as num? ?? 1).toDouble();
      final casePack = (r['case_pack'] as num? ?? 1).toDouble();
      final multiple = configuredMultiple > 1
          ? configuredMultiple
          : (casePack > 1 ? casePack : 1.0);
      final suggested = autoPurchaseEligible && rawSuggested > 0.001
          ? _roundOrderQuantity(rawSuggested, moq, multiple)
          : 0.0;
      final stockValue = usableOnHand * (r['cost'] as num? ?? 0).toDouble();
      final needsManualReview =
          (!autoPurchaseEligible && (stock <= 0 || rawSuggested > 0.001)) ||
              (stock <= 0 && confidence == 'Insufficient');

      final stockoutDays =
          forecastDaily > 0 ? (usableOnHand / forecastDaily).floor() : null;
      final expectedStockoutDate = stockoutDays == null
          ? null
          : dayKey(
              today.add(Duration(days: stockoutDays.clamp(0, 3650).toInt())));
      int? reorderInDays;
      if (forecastDaily > 0)
        reorderInDays = usableOnHand <= autoMinStock
            ? 0
            : ((usableOnHand - autoMinStock) / forecastDaily)
                .floor()
                .clamp(0, 3650)
                .toInt();
      final recommendedReorderDate = reorderInDays == null
          ? null
          : dayKey(today.add(Duration(days: reorderInDays)));

      int? daysToExpiry;
      double projectedAtExpiry = 0;
      double projectedExpiryValue = 0;
      final expiryText = (r['nearest_expiry'] ?? '').toString();
      if (expiryText.isNotEmpty) {
        final expiry = DateTime.tryParse(expiryText);
        if (expiry != null) {
          final expDay = DateTime(expiry.year, expiry.month, expiry.day);
          daysToExpiry = expDay.difference(today).inDays;
          final expiringLotQty =
              (r['nearest_expiry_qty'] as num? ?? stock).toDouble();
          if (daysToExpiry >= 0) {
            final expiryForecast =
                forecastFor(daysToExpiry.clamp(0, 365).toInt());
            projectedAtExpiry = (expiringLotQty - expiryForecast)
                .clamp(0, double.infinity)
                .toDouble();
            projectedExpiryValue =
                projectedAtExpiry * (r['cost'] as num? ?? 0).toDouble();
          } else {
            projectedAtExpiry = expiringLotQty;
            projectedExpiryValue =
                expiringLotQty * (r['cost'] as num? ?? 0).toDouble();
          }
        }
      }

      final simpleBacktestExpected = prior30;
      final backtestError = max(last30, simpleBacktestExpected) <= 0
          ? null
          : (last30 - simpleBacktestExpected).abs() /
              max(max(last30, simpleBacktestExpected), 1.0);
      final recentFitAccuracy = backtestError == null
          ? null
          : ((1 - backtestError) * 100).clamp(0, 100).toDouble();

      return <String, Object?>{
        ...r,
        'configured_min_stock': configuredMin,
        'configured_target_stock': configuredTarget,
        'min_stock': effectiveMin,
        'target_stock': effectiveTarget,
        'velocity': forecastDaily,
        'previous_velocity': previousSold / days,
        'demand_trend_pct': trendPct,
        'demand_signal': demandSignal,
        'confidence': confidence,
        'forecast_confidence_score': confidenceScore,
        'history_span_days': historySpanDays,
        'selling_days_90': nonZero90,
        'demand_variability': variability,
        'seasonality_available': hasYearHistory ? 1 : 0,
        'seasonality_factor': seasonalityFactor,
        'same_period_last_year_30': samePeriodLastYear30,
        'forecast_7_days': forecast7,
        'forecast_30_days': forecast30,
        'forecast_60_days': forecast60,
        'forecast_90_days': forecast90,
        'regression_component_30': regressionForecast(30),
        'forecast_model':
            'Adaptive ensemble: ridge regression + trend + weekday + last-year seasonality + intermittent demand + lifecycle transfer',
        'forecast_recent_fit_accuracy': recentFitAccuracy,
        'forecast_own_transactions': ownTransactions,
        'forecast_predecessor_ids': predecessorIds.join(','),
        'forecast_predecessor_weight':
            predecessorIds.isEmpty ? 0.0 : predecessorWeight,
        'forecast_family_support_used': familySupportUsed ? 1 : 0,
        'forecast_history_source': predecessorIds.isNotEmpty
            ? 'Own history + ${predecessorIds.length} predecessor${predecessorIds.length == 1 ? '' : 's'}'
            : familySupportUsed
                ? 'Own history + discontinued demand-family support'
                : 'Own product history',
        'lead_time_demand': leadDemand,
        'safety_stock': safetyStock,
        'auto_min_stock': autoMinStock,
        'reorder_point': autoMinStock,
        'auto_target_stock': autoTargetStock,
        'recommended_reorder_date': recommendedReorderDate,
        'expected_stockout_date': expectedStockoutDate,
        'days_since_sale': daysSinceSale,
        'coverage_days': coverage,
        'incoming_qty': incoming,
        'inventory_position': inventoryPosition,
        'demand_target': autoTargetStock,
        'dynamic_target': recommendedStock,
        'target_source': targetSource,
        'usable_on_hand': usableOnHand,
        'stock_discrepancy': stockDiscrepancy ? 1 : 0,
        'demand_state': demandState,
        'seasonal_evidence': seasonalEvidence ? 1 : 0,
        'auto_purchase_eligible': autoPurchaseEligible ? 1 : 0,
        'suggested_order': suggested,
        'raw_purchase_need': rawSuggested,
        'needs_manual_review': needsManualReview ? 1 : 0,
        'stock_value': stockValue,
        'days_to_expiry': daysToExpiry,
        'projected_stock_at_expiry': projectedAtExpiry,
        'projected_expiry_value': projectedExpiryValue,
      };
    }).toList();

    if (autoFillLevels && branchIdOverride == null) {
      await db.transaction((t) async {
        var changed = 0;
        for (final r in base) {
          final confidence = '${r['confidence']}';
          if (confidence != 'High' && confidence != 'Medium') continue;
          if ((r['auto_purchase_eligible'] as num? ?? 0).toInt() != 1) continue;
          final newMin = (r['auto_min_stock'] as num? ?? 0).toDouble();
          final newTarget = (r['auto_target_stock'] as num? ?? 0).toDouble();
          final oldMin = (r['configured_min_stock'] as num? ?? 0).toDouble();
          final oldTarget =
              (r['configured_target_stock'] as num? ?? 0).toDouble();
          if ((newMin - oldMin).abs() < .01 &&
              (newTarget - oldTarget).abs() < .01) continue;
          await t.update(
              'products',
              {
                'min_stock': newMin,
                'target_stock': newTarget,
                'updated_at': DateTime.now().toIso8601String(),
              },
              where: 'id=?',
              whereArgs: ['${r['id']}']);
          changed++;
        }
        if (changed > 0) {
          await t.insert(
              'app_meta',
              {
                'k': 'last_forecast_stock_level_update',
                'v': DateTime.now().toIso8601String()
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          await _audit(t, 'Auto forecast stock levels', 'products', branchId,
              '$changed product min/target levels updated from demand forecast');
        }
      });
    }

    final positiveVelocities = base
        .map((r) => (r['velocity'] as num? ?? 0).toDouble())
        .where((v) => v > 0)
        .toList();
    final avgVelocity = positiveVelocities.isEmpty
        ? 0.0
        : positiveVelocities.reduce((a, b) => a + b) /
            positiveVelocities.length;

    return base.map((r) {
      final stock = (r['stock'] as num? ?? 0).toDouble();
      final minStock = (r['min_stock'] as num? ?? 0).toDouble();
      final velocity = (r['velocity'] as num? ?? 0).toDouble();
      final coverage = (r['coverage_days'] as num? ?? -1).toDouble();
      final target = (r['dynamic_target'] as num? ?? 0).toDouble();
      final rawOrder = (r['suggested_order'] as num? ?? 0).toDouble();
      final daysToExpiry = r['days_to_expiry'] as int?;
      final expiryRisk = (r['projected_expiry_value'] as num? ?? 0).toDouble();
      final trendPct = (r['demand_trend_pct'] as num?)?.toDouble();
      final daysSinceSale = r['days_since_sale'] as int?;
      final confidence = '${r['confidence']}';
      final needsManualReview = (r['needs_manual_review'] as num? ?? 0) != 0;

      final outOfStock = stock <= 0;
      final lowStock = !outOfStock && stock <= minStock;
      final deadStock = stock > 0 && velocity <= 0;
      final fastMoving = velocity > 0 &&
          confidence != 'Insufficient' &&
          (avgVelocity <= 0 ||
              velocity >= (avgVelocity * 1.5).clamp(0.10, double.infinity));
      final slowMoving = stock > 0 &&
          velocity > 0 &&
          (coverage > 60 || (avgVelocity > 0 && velocity < avgVelocity * 0.5));
      final overstock =
          stock > 0 && target > 0 && stock > target * 1.5 && coverage > 45;
      final expiringSoon = stock > 0 &&
          daysToExpiry != null &&
          daysToExpiry >= 0 &&
          daysToExpiry <= 30;
      final projectedExpiryRisk = expiryRisk > 0.001;
      final reliableTrend = confidence == 'High' || confidence == 'Medium';
      final demandDropping =
          reliableTrend && trendPct != null && trendPct <= -25 && velocity > 0;
      final demandRising =
          reliableTrend && trendPct != null && trendPct >= 25 && velocity > 0;
      final demandState =
          '${r['demand_state'] ?? 'New / insufficient history'}';
      final stockDiscrepancy =
          (r['stock_discrepancy'] as num? ?? 0).toInt() == 1;
      final autoPurchaseEligible =
          (r['auto_purchase_eligible'] as num? ?? 0).toInt() == 1;
      final purchasable = (r['purchasable'] as num? ?? 1).toInt() == 1;
      final lifecycleStatus = '${r['lifecycle_status'] ?? 'Active'}';
      final notSoldRecently = daysSinceSale == null || daysSinceSale > 90;
      final purchaseBlocked = !autoPurchaseEligible ||
          projectedExpiryRisk ||
          overstock ||
          demandDropping;
      final order = purchaseBlocked ? 0.0 : rawOrder;
      final needsAttention = outOfStock ||
          lowStock ||
          order > 0.001 ||
          projectedExpiryRisk ||
          deadStock ||
          demandDropping ||
          notSoldRecently ||
          needsManualReview ||
          stockDiscrepancy ||
          !purchasable ||
          lifecycleStatus != 'Active';

      String movement = 'Normal';
      if (deadStock)
        movement = 'Dead';
      else if (fastMoving)
        movement = 'Fast';
      else if (slowMoving) movement = 'Slow';

      String health = 'Healthy';
      if (stockDiscrepancy)
        health = 'Stock Discrepancy';
      else if (!purchasable || lifecycleStatus != 'Active')
        health = 'Do Not Buy';
      else if (demandState == 'Dormant')
        health = 'Dormant';
      else if (demandState.contains('review') ||
          demandState == 'New / insufficient history')
        health = 'Review';
      else if (outOfStock && order > 0.001)
        health = 'Out of Stock';
      else if (outOfStock)
        health = 'Review';
      else if (projectedExpiryRisk)
        health = 'Expiry Risk';
      else if (deadStock || notSoldRecently)
        health = 'Dead Stock';
      else if (overstock)
        health = 'Overstock';
      else if (lowStock || order > 0.001) health = 'Reorder';

      String recommendation = 'Keep monitoring';
      String explanation =
          'Stock and forecast demand are within the current working range.';
      if (stockDiscrepancy) {
        recommendation = 'Count / correct stock';
        explanation =
            'Recorded stock is negative. RELIQ keeps the product in intelligence but will not turn a stock discrepancy into purchase demand.';
      } else if (!purchasable || lifecycleStatus != 'Active') {
        recommendation = 'Do not buy';
        explanation = !purchasable
            ? 'This product is not marked as purchasable.'
            : 'Lifecycle status is $lifecycleStatus, so replenishment is blocked while history remains available.';
      } else if (demandState == 'Dormant') {
        recommendation = 'Dormant — do not buy';
        explanation = daysSinceSale == null
            ? 'No sale history was found. Review the product before stocking it.'
            : 'Last sale was $daysSinceSale days ago. Forecast remains visible, but automatic replenishment is blocked.';
      } else if (demandState.contains('review') ||
          demandState == 'New / insufficient history') {
        recommendation = 'Review before buying';
        explanation = daysSinceSale == null
            ? 'There is not enough sale history to authorize an automatic purchase.'
            : 'Last sale was $daysSinceSale days ago. Review seasonality or business need before replenishing.';
      } else if (outOfStock && order > 0.001) {
        recommendation = confidence == 'Insufficient'
            ? 'Review then replenish'
            : 'Buy / replenish';
        explanation =
            'This product is out of stock. RELIQ used ${r['target_source']} to estimate the next order.';
      } else if (outOfStock && needsManualReview) {
        recommendation = 'Set target / review reorder';
        explanation =
            'This product is out of stock but does not yet have enough demand history for a reliable forecast.';
      } else if (lowStock || order > 0.001) {
        recommendation = 'Buy / replenish';
        explanation =
            'Current stock is below the forecast target of ${target.toStringAsFixed(2)} ${r['unit'] ?? ''}. Suggested order still respects the existing MOQ/order multiple.';
      } else if (projectedExpiryRisk) {
        recommendation = 'Sell through / reduce buying';
        explanation =
            'Forecast demand suggests stock may remain when the nearest expiry is reached.';
      } else if (deadStock || notSoldRecently) {
        recommendation = 'Promote, bundle, markdown or return';
        explanation = daysSinceSale == null
            ? 'Stock is on hand but RELIQ cannot find a recent sale.'
            : 'This product has not sold for $daysSinceSale days.';
      } else if (overstock) {
        recommendation = 'Pause buying / reduce stock';
        explanation = coverage > 0
            ? 'Current stock may last about ${coverage.toStringAsFixed(0)} days at the forecast demand rate.'
            : 'Current stock is well above the forecast target.';
      } else if (demandDropping) {
        recommendation = 'Demand falling — monitor closely';
        explanation =
            'Demand is meaningfully lower than the preceding comparison period.';
      } else if (demandRising || fastMoving) {
        recommendation = 'High demand — protect availability';
        explanation =
            'The adaptive forecast detects stronger demand and recommends tighter stock coverage.';
      } else if (confidence == 'Low' || confidence == 'Insufficient') {
        recommendation = 'Monitor — limited history';
        explanation =
            'There is not enough transaction history for a high-confidence forecast yet.';
      }

      return <String, Object?>{
        ...r,
        'movement': movement,
        'health': health,
        'recommendation': recommendation,
        'explanation': explanation,
        'demand_dropping': demandDropping ? 1 : 0,
        'demand_rising': demandRising ? 1 : 0,
        'not_sold_recently': notSoldRecently ? 1 : 0,
        'out_of_stock': outOfStock ? 1 : 0,
        'low_stock': lowStock ? 1 : 0,
        'dead_stock': deadStock ? 1 : 0,
        'purchase_blocked': purchaseBlocked ? 1 : 0,
        'purchase_block_reason': purchaseBlocked
            ? (stockDiscrepancy
                ? 'Stock discrepancy'
                : !purchasable
                    ? 'Not purchasable'
                    : lifecycleStatus != 'Active'
                        ? 'Lifecycle: $lifecycleStatus'
                        : demandState == 'Dormant'
                            ? 'Dormant demand'
                            : demandState.contains('review') ||
                                    demandState == 'New / insufficient history'
                                ? 'Manual demand review'
                                : projectedExpiryRisk
                                    ? 'Expiry risk'
                                    : overstock
                                        ? 'Overstock'
                                        : demandDropping
                                            ? 'Demand falling'
                                            : 'Purchase policy review')
            : '',
        'suggested_order': order,
        'fast_moving': fastMoving ? 1 : 0,
        'slow_moving': slowMoving ? 1 : 0,
        'overstock': overstock ? 1 : 0,
        'expiring_soon': expiringSoon ? 1 : 0,
        'projected_expiry_risk': projectedExpiryRisk ? 1 : 0,
        'needs_attention': needsAttention ? 1 : 0,
      };
    }).toList();
  }

  Future<Map<String, num>> morningBriefDetail(
      {bool forceAnalytics = false}) async {
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toIso8601String();
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    final inventory = await inventoryIntelligence(
        lookbackDays: 30, forceRefresh: forceAnalytics);
    final cashRows = await db.rawQuery('''
      SELECT
        (SELECT COALESCE(SUM(amount),0) FROM payments WHERE branch_id=? AND party_type='Customer' AND amount>0 AND created_at>=? AND created_at<?) today_collected,
        (SELECT COALESCE(SUM(amount+tax_amount),0) FROM expenses WHERE branch_id=? AND status='Active' AND expense_date>=? AND expense_date<?) today_expenses
    ''', [branchId, todayStart, tomorrow, branchId, todayStart, tomorrow]);
    final row = cashRows.first;
    final outOfStock = inventory
        .where((r) => (r['out_of_stock'] as num? ?? 0).toInt() == 1)
        .length;
    final belowMin = inventory
        .where((r) =>
            (r['low_stock'] as num? ?? 0).toInt() == 1 &&
            (r['purchase_blocked'] as num? ?? 0).toInt() == 0)
        .length;
    final reorder = inventory
        .where((r) => (r['suggested_order'] as num? ?? 0).toDouble() > 0.001)
        .length;
    final expiring = inventory
        .where((r) => (r['expiring_soon'] as num? ?? 0).toInt() == 1)
        .length;
    final today = await reportSummaryBetween(now, now);
    final yesterday = await reportSummaryBetween(
        now.subtract(const Duration(days: 1)),
        now.subtract(const Duration(days: 1)));
    final cash = await cashSummary(now);
    final dead = inventory
        .where((r) =>
            (r['dead_stock'] as num? ?? 0).toInt() == 1 ||
            (r['health']?.toString() == 'Dead Stock'))
        .length;
    final dormant =
        inventory.where((r) => '${r['demand_state']}' == 'Dormant').length;
    final discrepancies = inventory
        .where((r) => (r['stock_discrepancy'] as num? ?? 0).toInt() == 1)
        .length;
    final overdueCustomerRows = await db.rawQuery(
        "SELECT COUNT(DISTINCT customer_id) c FROM sales WHERE branch_id=? AND customer_id IS NOT NULL AND balance>0.001 AND due_date IS NOT NULL AND due_date<datetime('now') AND COALESCE(status,'Completed')<>'Cancelled'",
        [branchId]);
    final quoteFollowupRows = await db.rawQuery(
        "SELECT COUNT(*) c FROM quotations WHERE branch_id=? AND status='Sent' AND created_at<datetime('now','-3 day') AND (valid_until IS NULL OR valid_until>=datetime('now'))",
        [branchId]);
    return {
      'todayNetSales': today['sales'] ?? 0,
      'yesterdaySales': yesterday['sales'] ?? 0,
      'todayGrossMargin': today['grossMargin'] ?? 0,
      'expectedCash': cash['expected_cash'] as num? ?? 0,
      'expiredProducts': inventory
          .where((r) =>
              (r['days_to_expiry'] as num? ?? 1) < 0 &&
              (r['stock'] as num? ?? 0) > 0)
          .length,
      'lowStockProducts':
          inventory.where((r) => (r['low_stock'] as num? ?? 0) != 0).length,
      'todayCollected': (row['today_collected'] as num?) ?? 0,
      'todayExpenses': (row['today_expenses'] as num?) ?? 0,
      'outOfStock': outOfStock,
      'belowMinStock': belowMin,
      'reorderProducts': reorder,
      'expiring30': expiring,
      'deadStock': dead,
      'dormantProducts': dormant,
      'stockDiscrepancies': discrepancies,
      'overdueCustomers': (overdueCustomerRows.first['c'] as num? ?? 0),
      'quotationFollowups': (quoteFollowupRows.first['c'] as num? ?? 0),
    };
  }

  Future<Map<String, double>> receivablesAging() async =>
      _agingBuckets('sales');

  Future<Map<String, double>> payablesAging() async =>
      _agingBuckets('purchases');

  Future<Map<String, double>> _agingBuckets(String table) async {
    if (table != 'sales' && table != 'purchases')
      throw ArgumentError('Unsupported aging table');
    final partyType = table == 'sales' ? 'Customer' : 'Supplier';
    final statusFilter = table == 'sales'
        ? "COALESCE(status,'Completed')<>'Cancelled'"
        : "COALESCE(status,'Received')<>'Cancelled'";
    final rows = await db.rawQuery('''
      WITH open_docs AS (
        SELECT balance,due_date,created_at FROM $table WHERE balance>0.000001 AND $statusFilter
        UNION ALL
        SELECT balance,due_date,created_at FROM account_adjustments
        WHERE party_type=? AND balance>0.000001 AND status='Posted'
      )
      SELECT
        COALESCE(SUM(CASE WHEN julianday('now')-julianday(COALESCE(due_date,created_at))<=0 THEN balance ELSE 0 END),0) current_amount,
        COALESCE(SUM(CASE WHEN julianday('now')-julianday(COALESCE(due_date,created_at))>0 AND julianday('now')-julianday(COALESCE(due_date,created_at))<=30 THEN balance ELSE 0 END),0) d1_30,
        COALESCE(SUM(CASE WHEN julianday('now')-julianday(COALESCE(due_date,created_at))>30 AND julianday('now')-julianday(COALESCE(due_date,created_at))<=60 THEN balance ELSE 0 END),0) d31_60,
        COALESCE(SUM(CASE WHEN julianday('now')-julianday(COALESCE(due_date,created_at))>60 AND julianday('now')-julianday(COALESCE(due_date,created_at))<=90 THEN balance ELSE 0 END),0) d61_90,
        COALESCE(SUM(CASE WHEN julianday('now')-julianday(COALESCE(due_date,created_at))>90 THEN balance ELSE 0 END),0) d90_plus
      FROM open_docs
    ''', [partyType]);
    final r = rows.first;
    return {
      'Current': (r['current_amount'] as num? ?? 0).toDouble(),
      '1–30 days': (r['d1_30'] as num? ?? 0).toDouble(),
      '31–60 days': (r['d31_60'] as num? ?? 0).toDouble(),
      '61–90 days': (r['d61_90'] as num? ?? 0).toDouble(),
      '90+ days': (r['d90_plus'] as num? ?? 0).toDouble(),
    };
  }

  Future<List<Map<String, Object?>>> paymentLedger(
      {int limit = 100,
      int offset = 0,
      String search = '',
      String partyType = 'All',
      String method = 'All',
      String direction = 'All',
      String branchId = 'All',
      String documentType = 'All',
      String sort = 'Newest',
      DateTime? from,
      DateTime? to,
      double? minimum,
      double? maximum}) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (search.trim().isNotEmpty) {
      clauses.add(
          "(COALESCE(c.name,s.name,'') LIKE ? OR p.reference LIKE ? OR p.document_type LIKE ? OR p.method LIKE ?)");
      args.addAll(List.filled(4, '%${search.trim()}%'));
    }
    for (final field in <String, String>{
      'party_type': partyType,
      'method': method,
      'branch_id': branchId,
      'document_type': documentType
    }.entries) {
      if (field.value != 'All') {
        clauses.add('p.${field.key}=?');
        args.add(field.value);
      }
    }
    final outgoing =
        "((p.party_type='Supplier' AND p.amount>0) OR (p.party_type='Customer' AND p.amount<0))";
    if (direction == 'Paid') clauses.add(outgoing);
    if (direction == 'Received') clauses.add('NOT $outgoing');
    if (from != null) {
      clauses.add('p.created_at>=?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      clauses.add('p.created_at<?');
      args.add(DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1))
          .toIso8601String());
    }
    if (minimum != null) {
      clauses.add('ABS(p.amount)>=?');
      args.add(minimum);
    }
    if (maximum != null) {
      clauses.add('ABS(p.amount)<=?');
      args.add(maximum);
    }
    final order = switch (sort) {
      'Oldest' => 'p.created_at ASC,p.id',
      'Highest Amount' => 'ABS(p.amount) DESC,p.id',
      'Lowest Amount' => 'ABS(p.amount) ASC,p.id',
      _ => 'p.created_at DESC,p.id'
    };
    return db.rawQuery(
        '''SELECT p.*,b.name branch_name,COALESCE(c.name,s.name,'') party_name,
      COALESCE(c.whatsapp,s.whatsapp,c.phone,s.phone,'') party_whatsapp,
      COALESCE(c.phone,s.phone,'') party_phone,
      COALESCE(c.email,s.email,'') party_email,
      COALESCE(c.balance,s.balance,0) party_balance,
      COALESCE((SELECT COUNT(*) FROM payment_allocations pa WHERE pa.payment_id=p.id),0) allocation_count,
      COALESCE((SELECT SUM(pa.allocated_amount) FROM payment_allocations pa WHERE pa.payment_id=p.id),0) allocated_amount,
      (SELECT cl.created_at FROM communication_log cl WHERE cl.document_type=CASE WHEN p.party_type='Customer' THEN 'Payment Receipt' ELSE 'Supplier Payment Advice' END AND cl.document_id=p.id AND cl.channel='WhatsApp' ORDER BY cl.created_at DESC LIMIT 1) whatsapp_share_at
      FROM payments p LEFT JOIN customers c ON p.party_type='Customer' AND c.id=p.party_id
      LEFT JOIN suppliers s ON p.party_type='Supplier' AND s.id=p.party_id LEFT JOIN branches b ON b.id=p.branch_id
      ${clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}'} ORDER BY $order LIMIT ? OFFSET ?''',
        [...args, limit, offset]);
  }

  Future<List<Map<String, Object?>>> paymentAllocationsFor(
          String paymentId) async =>
      db.rawQuery('''
    SELECT pa.document_type,pa.document_id,pa.allocated_amount amount,
           COALESCE(sa.no,pu.no,aa.no,pa.document_id) document_no
    FROM payment_allocations pa
    LEFT JOIN sales sa ON pa.document_type='Sale' AND sa.id=pa.document_id
    LEFT JOIN purchases pu ON pa.document_type='Purchase' AND pu.id=pa.document_id
    LEFT JOIN account_adjustments aa ON pa.document_type='Adjustment' AND aa.id=pa.document_id
    WHERE pa.payment_id=? ORDER BY pa.id
  ''', [paymentId]);

  Future<List<Map<String, Object?>>> dayBook(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day).toIso8601String();
    final end = DateTime(day.year, day.month, day.day)
        .add(const Duration(days: 1))
        .toIso8601String();
    final result = <Map<String, Object?>>[];

    final salesRows = await db.rawQuery(
        'SELECT s.*,c.name customer_name FROM sales s LEFT JOIN customers c ON c.id=s.customer_id WHERE s.created_at>=? AND s.created_at<?',
        [start, end]);
    for (final r in salesRows) {
      result.add({
        'type': 'Sale',
        'created_at': r['created_at'],
        'title': r['no'],
        'detail': r['customer_name'] ?? 'Walk-in customer',
        'amount': r['total']
      });
    }
    final purchaseRows = await db.rawQuery(
        'SELECT p.*,s.name supplier_name FROM purchases p LEFT JOIN suppliers s ON s.id=p.supplier_id WHERE p.created_at>=? AND p.created_at<?',
        [start, end]);
    for (final r in purchaseRows) {
      result.add({
        'type': 'Purchase',
        'created_at': r['created_at'],
        'title': r['no'],
        'detail': r['supplier_name'] ?? 'Supplier',
        'amount': r['total']
      });
    }
    final expenseRows = await db.query('expenses',
        where: "status='Active' AND expense_date>=? AND expense_date<?",
        whereArgs: [start, end]);
    for (final r in expenseRows) {
      result.add({
        'type': 'Expense',
        'created_at': r['expense_date'],
        'title': r['category'],
        'detail': r['description'] ?? '',
        'amount': ((r['amount'] as num? ?? 0).toDouble() +
            (r['tax_amount'] as num? ?? 0).toDouble())
      });
    }
    final paymentRows = await db.rawQuery('''
      SELECT p.*,CASE WHEN p.party_type='Customer' THEN c.name WHEN p.party_type='Supplier' THEN s.name ELSE '' END party_name
      FROM payments p
      LEFT JOIN customers c ON p.party_type='Customer' AND c.id=p.party_id
      LEFT JOIN suppliers s ON p.party_type='Supplier' AND s.id=p.party_id
      WHERE p.created_at>=? AND p.created_at<?
    ''', [start, end]);
    for (final r in paymentRows) {
      final amount = (r['amount'] as num? ?? 0).toDouble();
      String type;
      if (amount < 0) {
        type = 'Customer Refund';
      } else if (r['party_type'] == 'Supplier') {
        type = 'Supplier Payment';
      } else {
        type = 'Customer Payment';
      }
      result.add({
        'type': type,
        'created_at': r['created_at'],
        'title': r['party_name'] ?? r['reference'] ?? '',
        'detail': '${r['method'] ?? ''} • ${r['document_type'] ?? ''}',
        'amount': amount.abs()
      });
    }
    final adjustmentRows = await db.rawQuery('''
      SELECT a.*,COALESCE(c.name,s.name,'') party_name
      FROM account_adjustments a
      LEFT JOIN customers c ON a.party_type='Customer' AND c.id=a.party_id
      LEFT JOIN suppliers s ON a.party_type='Supplier' AND s.id=a.party_id
      WHERE a.created_at>=? AND a.created_at<?
    ''', [start, end]);
    for (final r in adjustmentRows) {
      result.add({
        'type': 'Account Adjustment',
        'created_at': r['created_at'],
        'title': r['kind'] ?? 'Adjustment',
        'detail':
            '${r['party_name'] ?? ''}${('${r['reference'] ?? ''}').isEmpty ? '' : ' • ${r['reference']}'}',
        'amount': (r['amount'] as num? ?? 0).toDouble()
      });
    }
    result.sort((a, b) =>
        '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}'));
    return result;
  }

  Future<List<Map<String, Object?>>> returnableSaleItems(String saleId) async {
    return db.rawQuery('''
      SELECT si.*,
             COALESCE((SELECT SUM(sri.qty) FROM sale_return_items sri WHERE sri.sale_item_id=si.id),0) returned_qty,
             si.qty-COALESCE((SELECT SUM(sri.qty) FROM sale_return_items sri WHERE sri.sale_item_id=si.id),0) returnable_qty
      FROM sale_items si
      WHERE si.sale_id=?
        AND si.qty-COALESCE((SELECT SUM(sri.qty) FROM sale_return_items sri WHERE sri.sale_item_id=si.id),0)>0.000001
      ORDER BY si.id
    ''', [saleId]);
  }

  Future<String> postSaleReturn({
    required String saleId,
    required List<Map<String, Object?>> items,
    required String refundMethod,
    String notes = '',
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('returns', 'post customer returns');
    if (items.isEmpty) throw Exception('Enter at least one return quantity');
    final now = DateTime.now();
    final returnId = _id('RET');
    final returnNo = 'R-${now.millisecondsSinceEpoch}';

    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final saleRows =
          await t.query('sales', where: 'id=?', whereArgs: [saleId], limit: 1);
      if (saleRows.isEmpty) throw Exception('Sale not found');
      final sale = saleRows.first;
      final allSaleItems =
          await t.query('sale_items', where: 'sale_id=?', whereArgs: [saleId]);
      final invoiceDiscount = (sale['discount'] as num? ?? 0).toDouble();
      final originalLinePool = allSaleItems.fold<double>(
          0, (v, row) => v + (row['line_total'] as num? ?? 0).toDouble());
      double returnTotal = 0;
      final validLines = <Map<String, Object?>>[];

      for (final requested in items) {
        final saleItemId = (requested['sale_item_id'] as num).toInt();
        final qty = (requested['qty'] as num).toDouble();
        if (qty <= 0) continue;
        final row = await t.rawQuery('''
          SELECT si.*,
                 COALESCE((SELECT SUM(sri.qty) FROM sale_return_items sri WHERE sri.sale_item_id=si.id),0) returned_qty
          FROM sale_items si WHERE si.id=? AND si.sale_id=? LIMIT 1
        ''', [saleItemId, saleId]);
        if (row.isEmpty)
          throw Exception('A return line no longer matches this sale');
        final si = row.first;
        final sold = (si['qty'] as num? ?? 0).toDouble();
        final already = (si['returned_qty'] as num? ?? 0).toDouble();
        if (qty > sold - already + 0.000001)
          throw Exception(
              'Return quantity exceeds the remaining sold quantity for ${si['name']}');
        if (sold <= 0) continue;
        final ratio = qty / sold;
        final baseLineReturn =
            (si['line_total'] as num? ?? 0).toDouble() * ratio;
        final lineDiscountReturn =
            (si['discount'] as num? ?? 0).toDouble() * ratio;
        final taxReturn = (si['tax'] as num? ?? 0).toDouble() * ratio;
        final costReturn = (si['cost'] as num? ?? 0).toDouble() * qty;
        final invoiceDiscountShare = originalLinePool > 0
            ? invoiceDiscount * (baseLineReturn / originalLinePool)
            : 0.0;
        final financialLineReturn = (baseLineReturn - invoiceDiscountShare)
            .clamp(0, double.infinity)
            .toDouble();
        returnTotal += financialLineReturn;
        validLines.add({
          ...si,
          'return_qty': qty,
          'return_line_total': financialLineReturn,
          'return_discount': lineDiscountReturn,
          'return_invoice_discount': invoiceDiscountShare,
          'return_tax': taxReturn,
          'return_cost': costReturn,
        });
      }
      if (validLines.isEmpty || returnTotal <= 0)
        throw Exception('Enter at least one valid return quantity');

      final originalTotal = (sale['total'] as num? ?? 0).toDouble();
      final oldBalance = (sale['balance'] as num? ?? 0).toDouble();
      final alreadyReturned = (sale['returned_total'] as num? ?? 0).toDouble();
      final alreadyRefunded = (sale['refunded_total'] as num? ?? 0).toDouble();
      final financialReturn = returnTotal
          .clamp(0, (originalTotal - alreadyReturned).clamp(0, double.infinity))
          .toDouble();
      if (financialReturn <= 0)
        throw Exception('This sale has already been fully returned');
      final balanceReduction =
          financialReturn < oldBalance ? financialReturn : oldBalance;
      final refundAmount = (financialReturn - balanceReduction)
          .clamp(0, double.infinity)
          .toDouble();
      final newBalance =
          (oldBalance - balanceReduction).clamp(0, double.infinity).toDouble();
      final newReturned = alreadyReturned + financialReturn;
      final newRefunded = alreadyRefunded + refundAmount;
      final status = newReturned + 0.000001 >= originalTotal
          ? 'Returned'
          : 'Partially Returned';

      await t.insert('sales_returns', {
        'id': returnId,
        'no': returnNo,
        'sale_id': saleId,
        'created_at': now.toIso8601String(),
        'total': financialReturn,
        'refund_amount': refundAmount,
        'refund_method': refundMethod,
        'status': 'Posted',
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });

      for (final line in validLines) {
        final qty = (line['return_qty'] as num).toDouble();
        final productId = line['product_id'] as String?;
        await t.insert('sale_return_items', {
          'return_id': returnId,
          'sale_item_id': line['id'],
          'product_id': productId,
          'name': line['name'],
          'qty': qty,
          'unit_price': line['unit_price'],
          'discount': line['return_discount'],
          'invoice_discount': line['return_invoice_discount'],
          'tax': line['return_tax'],
          'cost': line['return_cost'],
          'line_total': line['return_line_total'],
        });
        if (productId != null && productId.isNotEmpty) {
          final pTypeRows = await t.query('products',
              columns: ['product_type'],
              where: 'id=?',
              whereArgs: [productId],
              limit: 1);
          final pType = pTypeRows.isEmpty
              ? 'Stocked'
              : (pTypeRows.first['product_type'] ?? 'Stocked').toString();
          if (pType == 'Recipe' || pType == 'Combo') {
            final components = await t.query('recipe_components',
                where: 'parent_product_id=?', whereArgs: [productId]);
            for (final c in components) {
              final componentId = c['component_product_id'].toString();
              final restored = qty *
                  (c['qty'] as num? ?? 0).toDouble() *
                  (c['multiplier'] as num? ?? 1).toDouble();
              final componentRows = await t.query('products',
                  columns: ['cost'],
                  where: 'id=?',
                  whereArgs: [componentId],
                  limit: 1);
              await t.insert('stock_lots', {
                'id': _id('LOT'),
                'product_id': componentId,
                'branch_id': ctx['branch_id'],
                'purchase_item_id': null,
                'batch_no': 'RETURN',
                'expiry_date': null,
                'received_qty': restored,
                'remaining_qty': restored,
                'unit_cost': componentRows.isEmpty
                    ? 0.0
                    : (componentRows.first['cost'] as num? ?? 0).toDouble(),
                'created_at': now.toIso8601String(),
                'status': 'Open',
              });
              await _changeBranchStock(
                  t, componentId, ctx['branch_id']!, restored);
              await t.insert('stock_movements', {
                'created_at': now.toIso8601String(),
                'product_id': componentId,
                'qty_change': restored,
                'type': '$pType Return Restore',
                'reference': returnNo,
                'reason':
                    notes.isEmpty ? 'Customer return component restore' : notes,
                'branch_id': ctx['branch_id'],
                'terminal_id': ctx['terminal_id'],
                'user_id': ctx['user_id'],
              });
            }
          } else {
            final returnProductRows = await t.query('products',
                columns: ['cost'],
                where: 'id=?',
                whereArgs: [productId],
                limit: 1);
            await t.insert('stock_lots', {
              'id': _id('LOT'),
              'product_id': productId,
              'branch_id': ctx['branch_id'],
              'purchase_item_id': null,
              'batch_no': 'RETURN',
              'expiry_date': null,
              'received_qty': qty,
              'remaining_qty': qty,
              'unit_cost': returnProductRows.isEmpty
                  ? 0.0
                  : (returnProductRows.first['cost'] as num? ?? 0).toDouble(),
              'created_at': now.toIso8601String(),
              'status': 'Open',
            });
            await _changeBranchStock(t, productId, ctx['branch_id']!, qty);
            await t.insert('stock_movements', {
              'created_at': now.toIso8601String(),
              'product_id': productId,
              'qty_change': qty,
              'type': 'Sale Return',
              'reference': returnNo,
              'reason': notes.isEmpty ? 'Customer return' : notes,
              'branch_id': ctx['branch_id'],
              'terminal_id': ctx['terminal_id'],
              'user_id': ctx['user_id'],
            });
          }
        }
      }

      await t.rawUpdate(
          'UPDATE sales SET balance=?,returned_total=?,refunded_total=?,status=? WHERE id=?',
          [newBalance, newReturned, newRefunded, status, saleId]);
      final customerId = sale['customer_id'] as String?;
      if (customerId != null && balanceReduction > 0) {
        await t.rawUpdate(
            'UPDATE customers SET balance=MAX(balance-?,0) WHERE id=?',
            [balanceReduction, customerId]);
      }
      if (refundAmount > 0) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': now.toIso8601String(),
          'party_type': 'Customer',
          'party_id': customerId,
          'document_type': 'Sale Return',
          'document_id': returnId,
          'amount': -refundAmount,
          'method': refundMethod,
          'reference': returnNo,
          'notes': notes.isEmpty ? 'Refund for ${sale['no']}' : notes,
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id'],
        });
      }
      final reversedTax = validLines.fold<double>(
          0, (v, x) => v + (x['return_tax'] as num? ?? 0).toDouble());
      await _audit(t, 'Sale return', 'sale_return', returnId,
          '$returnNo • sale ${sale['no']} • net return $financialReturn • tax reversed $reversedTax • refund $refundAmount');
      await _enqueueSyncEventTx(t,
          entityType: 'sale_return_txn',
          entityId: returnId,
          operation: 'post',
          payload: {
            'schema': 1,
            'return': await _rowById(t, 'sales_returns', returnId),
            'items': await t.query('sale_return_items',
                where: 'return_id=?', whereArgs: [returnId], orderBy: 'id'),
            'payments': await t.query('payments',
                where: "document_type='Sale Return' AND document_id=?",
                whereArgs: [returnId],
                orderBy: 'created_at,id'),
            'stock_effects': await t.query('stock_movements',
                where: 'reference=?', whereArgs: [returnNo], orderBy: 'id'),
            'sale_after': await _rowById(t, 'sales', saleId),
            'party_id': customerId ?? '',
            'party_balance_delta': -balanceReduction
          });
    });
    return returnNo;
  }

  Future<List<Map<String, Object?>>> returnablePurchaseItems(
      String purchaseId) async {
    return db.rawQuery('''
      SELECT pi.*,
             COALESCE((SELECT SUM(pri.qty) FROM purchase_return_items pri WHERE pri.purchase_item_id=pi.id),0) returned_qty,
             pi.qty-COALESCE((SELECT SUM(pri.qty) FROM purchase_return_items pri WHERE pri.purchase_item_id=pi.id),0) returnable_qty
      FROM purchase_items pi
      WHERE pi.purchase_id=?
        AND pi.qty-COALESCE((SELECT SUM(pri.qty) FROM purchase_return_items pri WHERE pri.purchase_item_id=pi.id),0)>0.000001
      ORDER BY pi.id
    ''', [purchaseId]);
  }

  Future<String> postPurchaseReturn({
    required String purchaseId,
    required List<Map<String, Object?>> items,
    required String refundMethod,
    String notes = '',
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    await requirePermission('returns', 'post supplier returns');
    if (items.isEmpty) throw Exception('Enter at least one return quantity');
    final now = DateTime.now();
    final returnId = _id('PRET');
    final returnNo = 'PR-${now.millisecondsSinceEpoch}';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final rows = await t.query('purchases',
          where: 'id=?', whereArgs: [purchaseId], limit: 1);
      if (rows.isEmpty) throw Exception('Purchase not found');
      final purchase = rows.first;
      double total = 0;
      final valid = <Map<String, Object?>>[];
      for (final requested in items) {
        final itemId = (requested['purchase_item_id'] as num).toInt();
        final qty = (requested['qty'] as num).toDouble();
        if (qty <= 0) continue;
        final q = await t.rawQuery('''
          SELECT pi.*,COALESCE((SELECT SUM(pri.qty) FROM purchase_return_items pri WHERE pri.purchase_item_id=pi.id),0) returned_qty
          FROM purchase_items pi WHERE pi.id=? AND pi.purchase_id=? LIMIT 1
        ''', [itemId, purchaseId]);
        if (q.isEmpty)
          throw Exception('A return line no longer matches this purchase');
        final pi = q.first;
        final bought = (pi['qty'] as num? ?? 0).toDouble();
        final already = (pi['returned_qty'] as num? ?? 0).toDouble();
        if (qty > bought - already + 0.000001)
          throw Exception(
              'Return quantity exceeds remaining purchased quantity for ${pi['name']}');
        if (bought <= 0) continue;
        final ratio = qty / bought;
        final lineTotal = (pi['line_total'] as num? ?? 0).toDouble() * ratio;
        total += lineTotal;
        valid.add({
          ...pi,
          'return_qty': qty,
          'return_line_total': lineTotal,
          'return_discount': (pi['discount'] as num? ?? 0).toDouble() * ratio,
          'return_tax': (pi['tax'] as num? ?? 0).toDouble() * ratio
        });
      }
      if (valid.isEmpty || total <= 0)
        throw Exception('Enter at least one valid return quantity');
      final oldBalance = (purchase['balance'] as num? ?? 0).toDouble();
      final balanceReduction = total < oldBalance ? total : oldBalance;
      final refund =
          (total - balanceReduction).clamp(0, double.infinity).toDouble();
      final supplierId = (purchase['supplier_id'] ?? '').toString();
      await t.insert('purchase_returns', {
        'id': returnId,
        'no': returnNo,
        'purchase_id': purchaseId,
        'created_at': now.toIso8601String(),
        'total': total,
        'refund_amount': refund,
        'refund_method': refundMethod,
        'status': 'Posted',
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      });
      for (final line in valid) {
        final qty = (line['return_qty'] as num).toDouble();
        final pid = (line['product_id'] ?? '').toString();
        final currentRows = await t.query('branch_stock',
            columns: ['qty'],
            where: 'product_id=? AND branch_id=?',
            whereArgs: [pid, ctx['branch_id']],
            limit: 1);
        final available = currentRows.isEmpty
            ? 0.0
            : (currentRows.first['qty'] as num? ?? 0).toDouble();
        if (available + 0.000001 < qty)
          throw Exception(
              'Not enough stock to return ${line['name']}. Available ${available.toStringAsFixed(2)}');
        await t.insert('purchase_return_items', {
          'return_id': returnId,
          'purchase_item_id': line['id'],
          'product_id': pid,
          'name': line['name'],
          'qty': qty,
          'unit_cost': line['unit_cost'],
          'discount': line['return_discount'],
          'tax': line['return_tax'],
          'line_total': line['return_line_total']
        });
        await _consumePurchaseItemLots(
            t, (line['id'] as num).toInt(), pid, ctx['branch_id']!, qty);
        await _changeBranchStock(t, pid, ctx['branch_id']!, -qty);
        await t.insert('stock_movements', {
          'created_at': now.toIso8601String(),
          'product_id': pid,
          'qty_change': -qty,
          'type': 'Purchase Return',
          'reference': returnNo,
          'reason': notes.isEmpty ? 'Return to supplier' : notes,
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      if (balanceReduction > 0 && supplierId.isNotEmpty) {
        await t.rawUpdate(
            'UPDATE suppliers SET balance=MAX(balance-?,0) WHERE id=?',
            [balanceReduction, supplierId]);
      }
      await t.rawUpdate(
          "UPDATE purchases SET balance=MAX(balance-?,0),status=CASE WHEN balance-?<=0 THEN 'Received' ELSE 'Partially Paid' END WHERE id=?",
          [balanceReduction, balanceReduction, purchaseId]);
      if (refund > 0) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': now.toIso8601String(),
          'party_type': 'Supplier',
          'party_id': supplierId,
          'document_type': 'Purchase Return',
          'document_id': returnId,
          'amount': -refund,
          'method': refundMethod,
          'reference': returnNo,
          'notes': notes.isEmpty
              ? 'Supplier refund / credit for ${purchase['no']}'
              : notes,
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await _audit(t, 'Purchase return', 'purchase_return', returnId,
          '$returnNo • purchase ${purchase['no']} • return $total • supplier refund/credit $refund');
      await _enqueueSyncEventTx(t,
          entityType: 'purchase_return_txn',
          entityId: returnId,
          operation: 'post',
          payload: {
            'schema': 1,
            'return': await _rowById(t, 'purchase_returns', returnId),
            'items': await t.query('purchase_return_items',
                where: 'return_id=?', whereArgs: [returnId], orderBy: 'id'),
            'payments': await t.query('payments',
                where: "document_type='Purchase Return' AND document_id=?",
                whereArgs: [returnId],
                orderBy: 'created_at,id'),
            'stock_effects': await t.query('stock_movements',
                where: 'reference=?', whereArgs: [returnNo], orderBy: 'id'),
            'purchase_after': await _rowById(t, 'purchases', purchaseId),
            'party_id': supplierId,
            'party_balance_delta': -balanceReduction
          });
    });
    return returnNo;
  }

  Future<void> _consumeLots(
    DatabaseExecutor t,
    String productId,
    String branchId,
    double qty,
  ) async {
    var remaining = qty;
    if (remaining <= 0) return;
    final lots = await t.rawQuery('''
      SELECT id,remaining_qty FROM stock_lots
      WHERE product_id=? AND branch_id=? AND remaining_qty>0.000001
      ORDER BY
        CASE WHEN expiry_date IS NULL OR TRIM(expiry_date)='' THEN 1 ELSE 0 END,
        expiry_date ASC,
        created_at ASC
    ''', [productId, branchId]);
    for (final lot in lots) {
      if (remaining <= 0.000001) break;
      final available = (lot['remaining_qty'] as num? ?? 0).toDouble();
      final used = available < remaining ? available : remaining;
      final next = (available - used).clamp(0, double.infinity).toDouble();
      await t.update(
        'stock_lots',
        {
          'remaining_qty': next,
          'status': next <= 0.000001 ? 'Depleted' : 'Open'
        },
        where: 'id=?',
        whereArgs: [lot['id']],
      );
      remaining -= used;
    }
  }

  Future<void> _moveLotsBetweenBranches(
    DatabaseExecutor t,
    String productId,
    String fromBranchId,
    String toBranchId,
    double qty,
  ) async {
    var remaining = qty;
    final lots = await t.rawQuery('''
      SELECT * FROM stock_lots
      WHERE product_id=? AND branch_id=? AND remaining_qty>0.000001
      ORDER BY
        CASE WHEN expiry_date IS NULL OR TRIM(expiry_date)='' THEN 1 ELSE 0 END,
        expiry_date ASC,created_at ASC
    ''', [productId, fromBranchId]);
    for (final lot in lots) {
      if (remaining <= 0.000001) break;
      final available = (lot['remaining_qty'] as num? ?? 0).toDouble();
      final moved = available < remaining ? available : remaining;
      final left = (available - moved).clamp(0, double.infinity).toDouble();
      await t.update(
          'stock_lots',
          {
            'remaining_qty': left,
            'status': left <= 0.000001 ? 'Depleted' : 'Open',
          },
          where: 'id=?',
          whereArgs: [lot['id']]);
      await t.insert('stock_lots', {
        'id': _id('LOT'),
        'product_id': productId,
        'branch_id': toBranchId,
        'purchase_item_id': lot['purchase_item_id'],
        'batch_no': lot['batch_no'],
        'expiry_date': lot['expiry_date'],
        'received_qty': moved,
        'remaining_qty': moved,
        'unit_cost': lot['unit_cost'],
        'created_at': DateTime.now().toIso8601String(),
        'status': 'Open',
      });
      remaining -= moved;
    }
    if (remaining > 0.000001) {
      final productRows = await t.query('products',
          columns: ['cost'], where: 'id=?', whereArgs: [productId], limit: 1);
      final cost = productRows.isEmpty
          ? 0.0
          : (productRows.first['cost'] as num? ?? 0).toDouble();
      await t.insert('stock_lots', {
        'id': _id('LOT'),
        'product_id': productId,
        'branch_id': toBranchId,
        'purchase_item_id': null,
        'batch_no': 'TRANSFER',
        'expiry_date': null,
        'received_qty': remaining,
        'remaining_qty': remaining,
        'unit_cost': cost,
        'created_at': DateTime.now().toIso8601String(),
        'status': 'Open',
      });
    }
  }

  Future<void> _consumePurchaseItemLots(
    DatabaseExecutor t,
    int purchaseItemId,
    String productId,
    String branchId,
    double qty,
  ) async {
    var remaining = qty;
    final preferred = await t.rawQuery('''
      SELECT id,remaining_qty FROM stock_lots
      WHERE purchase_item_id=? AND product_id=? AND branch_id=? AND remaining_qty>0.000001
      ORDER BY created_at ASC
    ''', [purchaseItemId, productId, branchId]);
    for (final lot in preferred) {
      if (remaining <= 0.000001) break;
      final available = (lot['remaining_qty'] as num? ?? 0).toDouble();
      final used = available < remaining ? available : remaining;
      final next = (available - used).clamp(0, double.infinity).toDouble();
      await t.update(
          'stock_lots',
          {
            'remaining_qty': next,
            'status': next <= 0.000001 ? 'Depleted' : 'Open'
          },
          where: 'id=?',
          whereArgs: [lot['id']]);
      remaining -= used;
    }
    if (remaining > 0.000001) {
      await _consumeLots(t, productId, branchId, remaining);
    }
  }

  Future<List<Map<String, Object?>>> purchaseOrders({
    String status = '',
    int limit = 300,
  }) async {
    final ctx = await operationalContext();
    final clauses = <String>['po.branch_id=?'];
    final args = <Object?>[ctx['branch_id']];
    if (status.trim().isNotEmpty) {
      clauses.add('po.status=?');
      args.add(status.trim());
    }
    args.add(limit);
    return db.rawQuery('''
      SELECT po.*,s.name supplier_name,
             COUNT(poi.id) line_count,
             COALESCE(SUM(poi.ordered_qty),0) ordered_qty,
             COALESCE(SUM(poi.received_qty),0) received_qty,
             COALESCE(SUM(MAX(poi.ordered_qty-poi.received_qty,0)),0) incoming_qty
      FROM purchase_orders po
      LEFT JOIN suppliers s ON s.id=po.supplier_id
      LEFT JOIN purchase_order_items poi ON poi.purchase_order_id=po.id
      WHERE ${clauses.join(' AND ')}
      GROUP BY po.id
      ORDER BY po.created_at DESC
      LIMIT ?
    ''', args);
  }

  Future<List<Map<String, Object?>>> purchaseOrderItems(
          String purchaseOrderId) async =>
      db.rawQuery('''
        SELECT poi.*,p.sku,p.unit,p.track_batch,p.track_expiry,p.purchase_moq,p.order_multiple,p.case_pack,
               MAX(poi.ordered_qty-poi.received_qty,0) remaining_qty
        FROM purchase_order_items poi
        LEFT JOIN products p ON p.id=poi.product_id
        WHERE poi.purchase_order_id=?
        ORDER BY poi.id
      ''', [purchaseOrderId]);

  double _roundOrderQuantity(double wanted, double moq, double multiple) {
    var qty = wanted.clamp(0, double.infinity).toDouble();
    final safeMoq = moq.clamp(0, double.infinity).toDouble();
    final safeMultiple = multiple > 0 ? multiple : 1.0;
    if (qty > 0 && qty < safeMoq) qty = safeMoq;
    if (qty > 0 && safeMultiple > 0) {
      final units = (qty / safeMultiple).ceil();
      qty = units * safeMultiple;
    }
    return qty;
  }

  Future<String> createPurchaseOrder({
    required String supplierId,
    required List<Map<String, Object?>> items,
    String expectedDate = '',
    String notes = '',
    bool placeOrder = true,
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    await requirePermission('purchases', 'create purchase orders');
    if (supplierId.trim().isEmpty) throw Exception('Select a supplier');
    if (items.isEmpty) throw Exception('Purchase order has no items');
    final now = DateTime.now();
    final id = _id('PO');
    final no = 'PO-${now.microsecondsSinceEpoch}';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final suppliers = await t.query('suppliers',
          where: 'id=? AND active=1', whereArgs: [supplierId], limit: 1);
      if (suppliers.isEmpty) throw Exception('Supplier not found or inactive');
      final minOrder =
          (suppliers.first['min_order_value'] as num? ?? 0).toDouble();
      double total = 0;
      final prepared = <Map<String, Object?>>[];
      for (final raw in items) {
        final productId = (raw['id'] ?? raw['product_id'] ?? '').toString();
        if (productId.isEmpty) continue;
        final productRows = await t.query('products',
            where: 'id=? AND active=1', whereArgs: [productId], limit: 1);
        if (productRows.isEmpty)
          throw Exception('A selected product no longer exists');
        final product = productRows.first;
        final requested =
            (raw['qty'] as num? ?? raw['ordered_qty'] as num? ?? 0).toDouble();
        if (requested <= 0) continue;
        final moq = (product['purchase_moq'] as num? ?? 0).toDouble();
        final configuredMultiple =
            (product['order_multiple'] as num? ?? 1).toDouble();
        final casePack = (product['case_pack'] as num? ?? 1).toDouble();
        final multiple = configuredMultiple > 1
            ? configuredMultiple
            : (casePack > 1 ? casePack : 1.0);
        final qty = _roundOrderQuantity(requested, moq, multiple);
        final cost = (raw['unit_cost'] as num? ?? product['cost'] as num? ?? 0)
            .toDouble();
        if (cost < 0) throw Exception('Unit cost cannot be negative');
        final discount = (raw['discount'] as num? ?? 0).toDouble();
        final tax =
            (raw['tax_amount'] as num? ?? raw['tax'] as num? ?? 0).toDouble();
        final inclusive = (raw['tax_inclusive'] as num? ?? 0).toInt() == 1;
        final gross = qty * cost;
        if (discount < 0 || discount > gross)
          throw Exception('Invalid purchase-order discount');
        total += gross - discount + (inclusive ? 0 : tax);
        prepared.add({
          'product_id': productId,
          'name': raw['name'] ?? product['name'],
          'ordered_qty': qty,
          'unit_cost': cost,
          'discount': discount,
          'tax': tax,
          'tax_inclusive': inclusive ? 1 : 0,
          'batch_no': raw['batch_no'] ?? '',
          'expiry_date': raw['expiry_date'],
        });
      }
      if (prepared.isEmpty)
        throw Exception('Purchase order has no valid quantities');
      if (placeOrder && minOrder > 0 && total + 0.000001 < minOrder) {
        throw Exception(
            'Supplier minimum order value is ${minOrder.toStringAsFixed(3)}');
      }
      await t.insert('purchase_orders', {
        'id': id,
        'no': no,
        'created_at': now.toIso8601String(),
        'expected_date':
            expectedDate.trim().isEmpty ? null : expectedDate.trim(),
        'supplier_id': supplierId,
        'status': placeOrder ? 'Ordered' : 'Draft',
        'notes': notes.trim(),
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
        'ordered_total': total,
      });
      for (final row in prepared) {
        await t
            .insert('purchase_order_items', {'purchase_order_id': id, ...row});
      }
      await _audit(
          t,
          placeOrder ? 'Place purchase order' : 'Create purchase order draft',
          'purchase_order',
          id,
          '$no • ${prepared.length} lines • ${total.toStringAsFixed(3)}');
      await _enqueueSyncEventTx(t,
          entityType: 'purchase_order_txn',
          entityId: id,
          operation: 'create',
          payload: {
            'schema': 1,
            'order': await _rowById(t, 'purchase_orders', id),
            'items': await t.query('purchase_order_items',
                where: 'purchase_order_id=?', whereArgs: [id], orderBy: 'id')
          });
    });
    return no;
  }

  Future<void> setPurchaseOrderStatus(String id, String status) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.purchases);
    await requirePermission('purchases', 'update purchase orders');
    const allowed = {'Draft', 'Ordered', 'Cancelled'};
    if (!allowed.contains(status))
      throw Exception('Unsupported purchase order status');
    await db.transaction((t) async {
      final rows = await t.query('purchase_orders',
          where: 'id=?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw Exception('Purchase order not found');
      final current = (rows.first['status'] ?? '').toString();
      if ((current == 'Received' || current == 'Partially Received') &&
          status == 'Draft') {
        throw Exception('A received purchase order cannot return to Draft');
      }
      if (status == 'Ordered') {
        final supplier = await t.query('suppliers',
            where: 'id=? AND active=1',
            whereArgs: [rows.first['supplier_id']],
            limit: 1);
        if (supplier.isEmpty)
          throw Exception('Supplier is inactive or missing.');
        final minimum =
            (supplier.first['min_order_value'] as num? ?? 0).toDouble();
        if ((rows.first['ordered_total'] as num? ?? 0).toDouble() + .000001 <
            minimum)
          throw Exception(
              'Supplier minimum order value is ${minimum.toStringAsFixed(3)}.');
      }
      await t.update('purchase_orders', {'status': status},
          where: 'id=?', whereArgs: [id]);
      await _audit(t, 'Purchase order status', 'purchase_order', id,
          '$current → $status');
      await _enqueueSyncEventTx(t,
          entityType: 'purchase_order_state',
          entityId: id,
          operation: 'status',
          payload: {
            'schema': 1,
            'order': await _rowById(t, 'purchase_orders', id),
            'items': await t.query('purchase_order_items',
                where: 'purchase_order_id=?', whereArgs: [id], orderBy: 'id')
          });
    });
  }

  Future<String> receivePurchaseOrder({
    required String purchaseOrderId,
    required List<Map<String, Object?>> items,
    String supplierDocumentNo = '',
    double freight = 0,
    double otherCharges = 0,
    double paid = 0,
    String paymentMethod = 'Cash',
    String notes = '',
  }) async {
    final rows = await db.query('purchase_orders',
        where: 'id=?', whereArgs: [purchaseOrderId], limit: 1);
    if (rows.isEmpty) throw Exception('Purchase order not found');
    final order = rows.first;
    final status = (order['status'] ?? '').toString();
    if (status == 'Cancelled' || status == 'Received')
      throw Exception('This purchase order cannot receive more stock');
    final poItems = await purchaseOrderItems(purchaseOrderId);
    final byId = <int, Map<String, Object?>>{
      for (final x in poItems) (x['id'] as num).toInt(): x,
    };
    final prepared = <Map<String, Object?>>[];
    for (final raw in items) {
      final dynamic rawItemId = raw['purchase_order_item_id'] ?? raw['id'];
      final itemId = rawItemId is num
          ? rawItemId.toInt()
          : int.tryParse('${rawItemId ?? ''}');
      if (itemId == null || !byId.containsKey(itemId)) continue;
      final src = byId[itemId]!;
      final qty = (raw['qty'] as num? ?? 0).toDouble();
      final remaining = (src['remaining_qty'] as num? ?? 0).toDouble();
      if (qty <= 0) continue;
      if (qty > remaining + 0.000001)
        throw Exception(
            'Received quantity exceeds remaining order quantity for ${src['name']}');
      final orderedQty = (src['ordered_qty'] as num? ?? 0).toDouble();
      final ratio = orderedQty <= 0 ? 0 : qty / orderedQty;
      prepared.add({
        'id': src['product_id'],
        'name': src['name'],
        'qty': qty,
        'unit_cost': (raw['unit_cost'] as num? ?? src['unit_cost'] as num? ?? 0)
            .toDouble(),
        'discount': (src['discount'] as num? ?? 0).toDouble() * ratio,
        'tax_amount': (src['tax'] as num? ?? 0).toDouble() * ratio,
        'tax_inclusive': src['tax_inclusive'] ?? 0,
        'batch_no': raw['batch_no'] ?? src['batch_no'] ?? '',
        'expiry_date': raw['expiry_date'] ?? src['expiry_date'],
        'purchase_order_item_id': itemId,
      });
    }
    if (prepared.isEmpty)
      throw Exception('Enter at least one quantity to receive');
    return postPurchase(
      supplierId: order['supplier_id'].toString(),
      items: prepared,
      documentNo: supplierDocumentNo,
      freight: freight,
      otherCharges: otherCharges,
      paid: paid,
      paymentMethod: paymentMethod,
      notes: notes,
      purchaseOrderId: purchaseOrderId,
    );
  }

  Future<Map<String, double>> incomingStockByProduct() async {
    final ctx = await operationalContext();
    final rows = await db.rawQuery('''
      SELECT poi.product_id,COALESCE(SUM(MAX(poi.ordered_qty-poi.received_qty,0)),0) incoming
      FROM purchase_order_items poi
      JOIN purchase_orders po ON po.id=poi.purchase_order_id
      WHERE po.branch_id=? AND po.status IN ('Ordered','Partially Received')
      GROUP BY poi.product_id
    ''', [ctx['branch_id']]);
    return {
      for (final r in rows)
        r['product_id'].toString(): (r['incoming'] as num? ?? 0).toDouble()
    };
  }

  Future<List<Map<String, Object?>>> stockLots({
    String productId = '',
    bool openOnly = true,
    int limit = 500,
  }) async {
    final ctx = await operationalContext();
    final clauses = <String>['sl.branch_id=?'];
    final args = <Object?>[ctx['branch_id']];
    if (productId.trim().isNotEmpty) {
      clauses.add('sl.product_id=?');
      args.add(productId);
    }
    if (openOnly) clauses.add('sl.remaining_qty>0.000001');
    args.add(limit);
    return db.rawQuery('''
      SELECT sl.*,p.name,p.sku,p.unit
      FROM stock_lots sl JOIN products p ON p.id=sl.product_id
      WHERE ${clauses.join(' AND ')}
      ORDER BY
        CASE WHEN sl.expiry_date IS NULL OR TRIM(sl.expiry_date)='' THEN 1 ELSE 0 END,
        sl.expiry_date ASC,sl.created_at ASC
      LIMIT ?
    ''', args);
  }

  Future<List<Map<String, Object?>>> stockCounts({int limit = 200}) async {
    final ctx = await operationalContext();
    return db.rawQuery('''
      SELECT sc.*,COUNT(sci.id) line_count,
             COALESCE(SUM(ABS(sci.variance)),0) absolute_variance
      FROM stock_counts sc
      LEFT JOIN stock_count_items sci ON sci.stock_count_id=sc.id
      WHERE sc.branch_id=?
      GROUP BY sc.id
      ORDER BY sc.created_at DESC
      LIMIT ?
    ''', [ctx['branch_id'], limit]);
  }

  Future<String> createStockCount({
    required List<Map<String, Object?>> items,
    String notes = '',
  }) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('stock_adjust', 'create stock counts');
    if (items.isEmpty) throw Exception('Add at least one product to the count');
    final now = DateTime.now();
    final id = _id('CNT');
    final no = 'CNT-${now.millisecondsSinceEpoch}';
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      await t.insert('stock_counts', {
        'id': id,
        'no': no,
        'created_at': now.toIso8601String(),
        'status': 'Draft',
        'notes': notes,
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id'],
      });
      final seen = <String>{};
      for (final raw in items) {
        final pid = (raw['id'] ?? raw['product_id'] ?? '').toString();
        if (pid.isEmpty || seen.contains(pid)) continue;
        seen.add(pid);
        final products = await t.query('products',
            columns: ['name'], where: 'id=?', whereArgs: [pid], limit: 1);
        if (products.isEmpty) continue;
        final expected = await _branchQty(t, pid, ctx['branch_id']!);
        final counted = raw['counted_qty'] == null
            ? null
            : (raw['counted_qty'] as num).toDouble();
        await t.insert('stock_count_items', {
          'stock_count_id': id,
          'product_id': pid,
          'name': products.first['name'],
          'expected_qty': expected,
          'counted_qty': counted,
          'variance': counted == null ? 0 : counted - expected,
          'posted': 0,
        });
      }
      await _audit(t, 'Create stock count', 'stock_count', id,
          '$no • ${seen.length} products');
    });
    return no;
  }

  Future<List<Map<String, Object?>>> stockCountItems(
          String stockCountId) async =>
      db.rawQuery('''
        SELECT sci.*,p.sku,p.unit
        FROM stock_count_items sci LEFT JOIN products p ON p.id=sci.product_id
        WHERE sci.stock_count_id=?
        ORDER BY sci.name COLLATE NOCASE
      ''', [stockCountId]);

  Future<void> updateStockCountQuantity(int itemId, double countedQty) async {
    if (countedQty < 0) throw Exception('Counted quantity cannot be negative');
    await db.transaction((t) async {
      final rows = await t.query('stock_count_items',
          where: 'id=?', whereArgs: [itemId], limit: 1);
      if (rows.isEmpty) throw Exception('Stock count line not found');
      final countRows = await t.query('stock_counts',
          where: 'id=?', whereArgs: [rows.first['stock_count_id']], limit: 1);
      if (countRows.isEmpty || countRows.first['status'] != 'Draft')
        throw Exception('Only draft counts can be edited');
      final expected = (rows.first['expected_qty'] as num? ?? 0).toDouble();
      await t.update(
          'stock_count_items',
          {
            'counted_qty': countedQty,
            'variance': countedQty - expected,
          },
          where: 'id=?',
          whereArgs: [itemId]);
    });
  }

  Future<void> postStockCount(String stockCountId) async {
    await LicenseManager.instance
        .requireUsable(entitlement: LicenseEntitlements.corePos);
    await requirePermission('stock_adjust', 'post stock counts');
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final countRows = await t.query('stock_counts',
          where: 'id=?', whereArgs: [stockCountId], limit: 1);
      if (countRows.isEmpty) throw Exception('Stock count not found');
      if (countRows.first['status'] != 'Draft')
        throw Exception('This stock count is already posted or cancelled');
      final lines = await t.query('stock_count_items',
          where: 'stock_count_id=?', whereArgs: [stockCountId]);
      if (lines.isEmpty) throw Exception('Stock count has no lines');
      if (lines.any((x) => x['counted_qty'] == null))
        throw Exception(
            'Enter a counted quantity for every product before posting');
      final now = DateTime.now().toIso8601String();
      for (final line in lines) {
        final pid = line['product_id'].toString();
        final current = await _branchQty(t, pid, ctx['branch_id']!);
        final counted = (line['counted_qty'] as num).toDouble();
        final variance = counted - current;
        if (variance.abs() <= 0.000001) {
          await t.update('stock_count_items',
              {'expected_qty': current, 'variance': 0, 'posted': 1},
              where: 'id=?', whereArgs: [line['id']]);
          continue;
        }
        if (variance < 0) {
          await _consumeLots(t, pid, ctx['branch_id']!, -variance);
        } else {
          final productRows = await t.query('products',
              columns: ['cost'], where: 'id=?', whereArgs: [pid], limit: 1);
          final cost = productRows.isEmpty
              ? 0.0
              : (productRows.first['cost'] as num? ?? 0).toDouble();
          await t.insert('stock_lots', {
            'id': _id('LOT'),
            'product_id': pid,
            'branch_id': ctx['branch_id'],
            'purchase_item_id': null,
            'batch_no': 'COUNT',
            'expiry_date': null,
            'received_qty': variance,
            'remaining_qty': variance,
            'unit_cost': cost,
            'created_at': now,
            'status': 'Open',
          });
        }
        await _changeBranchStock(t, pid, ctx['branch_id']!, variance);
        await t.insert('stock_movements', {
          'created_at': now,
          'product_id': pid,
          'qty_change': variance,
          'type': 'Stock Count',
          'reference': countRows.first['no'],
          'reason': 'Physical stock count variance',
          'branch_id': ctx['branch_id'],
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id'],
        });
        await t.update('stock_count_items',
            {'expected_qty': current, 'variance': variance, 'posted': 1},
            where: 'id=?', whereArgs: [line['id']]);
      }
      await t.update('stock_counts', {'status': 'Posted', 'posted_at': now},
          where: 'id=?', whereArgs: [stockCountId]);
      await _audit(t, 'Post stock count', 'stock_count', stockCountId,
          '${countRows.first['no']} posted');
      await _enqueueSyncEventTx(t,
          entityType: 'stock_count_txn',
          entityId: stockCountId,
          operation: 'post',
          payload: {
            'schema': 1,
            'count': await _rowById(t, 'stock_counts', stockCountId),
            'items': await t.query('stock_count_items',
                where: 'stock_count_id=?',
                whereArgs: [stockCountId],
                orderBy: 'id'),
            'stock_effects': await t.query('stock_movements',
                where: "reference=? AND type='Stock Count'",
                whereArgs: [countRows.first['no']],
                orderBy: 'id')
          });
    });
  }

  Future<List<Map<String, Object?>>> recentPurchaseReturns(
          {int limit = 200}) async =>
      db.rawQuery('''
    SELECT r.*,p.no purchase_no,s.name supplier_name
    FROM purchase_returns r JOIN purchases p ON p.id=r.purchase_id
    LEFT JOIN suppliers s ON s.id=p.supplier_id
    ORDER BY r.created_at DESC LIMIT ?
  ''', [limit]);

  Future<List<Map<String, Object?>>> recentReturns({int limit = 300}) async {
    return db.rawQuery('''
      SELECT r.*,s.no sale_no,c.name customer_name
      FROM sales_returns r
      LEFT JOIN sales s ON s.id=r.sale_id
      LEFT JOIN customers c ON c.id=s.customer_id
      ORDER BY r.created_at DESC LIMIT ?
    ''', [limit]);
  }

  Future<void> setBusinessActionState(String actionKey, String status,
      {String fingerprint = '', int snoozeDays = 7, String note = ''}) async {
    final ctx = await operationalContext();
    final now = DateTime.now();
    final normalized =
        const {'Open', 'Snoozed', 'Resolved', 'Dismissed'}.contains(status)
            ? status
            : 'Open';
    await db.insert(
        'business_action_state',
        {
          'action_key': actionKey,
          'status': normalized,
          'fingerprint': fingerprint,
          'snoozed_until': normalized == 'Snoozed'
              ? now.add(Duration(days: snoozeDays)).toIso8601String()
              : null,
          'note': note.trim(),
          'updated_at': now.toIso8601String(),
          'user_id': ctx['user_id'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (normalized != 'Snoozed')
      await db
          .delete('bi_snoozes', where: 'action_key=?', whereArgs: [actionKey]);
  }

  Future<void> snoozeBusinessAction(String actionKey,
      {int days = 7, String fingerprint = ''}) async {
    await setBusinessActionState(actionKey, 'Snoozed',
        fingerprint: fingerprint, snoozeDays: days);
  }

  Future<void> resolveBusinessAction(String actionKey,
          {String fingerprint = ''}) =>
      setBusinessActionState(actionKey, 'Resolved', fingerprint: fingerprint);

  Future<void> dismissBusinessAction(String actionKey,
          {String fingerprint = ''}) =>
      setBusinessActionState(actionKey, 'Dismissed', fingerprint: fingerprint);

  Future<void> clearBusinessActionSnooze(String actionKey) async {
    await db
        .delete('bi_snoozes', where: 'action_key=?', whereArgs: [actionKey]);
    await db.delete('business_action_state',
        where: 'action_key=?', whereArgs: [actionKey]);
  }

  Future<Map<String, dynamic>> businessActionCenter({
    int lookbackDays = 30,
    bool forceRefresh = false,
    bool refreshInventory = true,
  }) async {
    final days = lookbackDays <= 0 ? 30 : lookbackDays;
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final key = 'action_center:v3:$branchId:$days';
    if (!forceRefresh) {
      final row = await _analyticsSnapshot(key);
      final cached = _decodeAnalyticsMap(row);
      if (cached != null) {
        if (_snapshotNeedsRefresh(row!))
          unawaited(_refreshBusinessActionSnapshot(key, days,
              refreshInventory: true));
        return cached;
      }
    }
    if (forceRefresh && refreshInventory) {
      await inventoryIntelligence(lookbackDays: days, forceRefresh: true);
    }
    return _refreshBusinessActionSnapshot(key, days, refreshInventory: false);
  }

  Future<Map<String, dynamic>> _refreshBusinessActionSnapshot(
      String key, int days,
      {required bool refreshInventory}) {
    final running = _actionCenterRefreshes[key];
    if (running != null) return running;
    final future = () async {
      try {
        if (refreshInventory)
          await inventoryIntelligence(lookbackDays: days, forceRefresh: true);
        final value = await _calculateBusinessActionCenter(lookbackDays: days);
        await _writeAnalyticsSnapshot(key, value);
        return value;
      } finally {
        _actionCenterRefreshes.remove(key);
      }
    }();
    _actionCenterRefreshes[key] = future;
    return future;
  }

  Future<Map<String, dynamic>> _calculateBusinessActionCenter(
      {int lookbackDays = 30}) async {
    final days = lookbackDays <= 0 ? 30 : lookbackDays;
    final ctx = await operationalContext();
    final branchId = ctx['branch_id']!;
    final now = DateTime.now();
    final currentFrom = now.subtract(Duration(days: days)).toIso8601String();
    final previousFrom =
        now.subtract(Duration(days: days * 2)).toIso8601String();
    final inventory = await inventoryIntelligence(lookbackDays: days);
    final actions = <Map<String, Object?>>[];
    final portfolio = <Map<String, Object?>>[];

    final snoozedRows = await db.query('bi_snoozes',
        where: 'snoozed_until>?', whereArgs: [now.toIso8601String()]);
    final snoozed = {
      for (final r in snoozedRows) '${r['action_key']}': r['snoozed_until']
    };
    double n(Map<String, Object?> r, String key) =>
        (r[key] as num? ?? 0).toDouble();
    bool f(Map<String, Object?> r, String key) => (r[key] as num? ?? 0) != 0;

    final buyRows =
        inventory.where((r) => n(r, 'suggested_order') > 0.001).toList();
    final buyValue = buyRows.fold<double>(
        0, (a, r) => a + n(r, 'suggested_order') * n(r, 'cost'));
    if (buyRows.isNotEmpty) {
      final urgent = buyRows
          .where((r) =>
              n(r, 'stock') <= 0 ||
              (n(r, 'coverage_days') >= 0 && n(r, 'coverage_days') <= 8))
          .length;
      actions.add({
        'key': 'buy',
        'priority': urgent > 0 ? 100 : 78,
        'kind': 'Buy',
        'title': '${buyRows.length} products need replenishment',
        'message':
            'Estimated order requirement is KWD ${buyValue.toStringAsFixed(3)}. ${urgent > 0 ? '$urgent may run out within roughly 8 days.' : 'Open purchase orders are already included in the inventory position.'}',
        'value': buyValue,
        'count': buyRows.length,
        'confidence': 'High',
        'action': 'Create Purchase Order',
        'nav': 19,
        'icon': 'buy'
      });
    }

    final discrepancies =
        inventory.where((r) => f(r, 'stock_discrepancy')).toList();
    if (discrepancies.isNotEmpty)
      actions.add({
        'key': 'stock_discrepancy',
        'priority': 98,
        'kind': 'Stock control',
        'title': '${discrepancies.length} stock discrepancies need counting',
        'message':
            'Negative recorded stock is treated as a count/correction issue, not as extra purchase demand. Resolve the stock position before replenishing these products.',
        'value': 0.0,
        'count': discrepancies.length,
        'confidence': 'High',
        'action': 'Open Physical Stock Counts',
        'nav': 20,
        'icon': 'count'
      });

    final dormant =
        inventory.where((r) => '${r['demand_state']}' == 'Dormant').toList();
    final dormantValue =
        dormant.fold<double>(0, (a, r) => a + n(r, 'stock_value'));
    if (dormant.isNotEmpty)
      actions.add({
        'key': 'dormant_products',
        'priority': 69,
        'kind': 'Product review',
        'title': '${dormant.length} active products are dormant',
        'message':
            'These products remain in forecasting/history but automatic purchasing is blocked. KWD ${dormantValue.toStringAsFixed(3)} is currently held in their on-hand stock. Review whether they should stay active, be promoted, transferred or deactivated.',
        'value': dormantValue,
        'count': dormant.length,
        'confidence': 'High',
        'action': 'Review Products',
        'nav': 2,
        'icon': 'dead'
      });

    final over = inventory.where((r) => f(r, 'overstock')).toList();
    final overValue = over.fold<double>(0, (a, r) => a + n(r, 'stock_value'));
    if (over.isNotEmpty)
      actions.add({
        'key': 'overstock',
        'priority': 72,
        'kind': 'Stop buying',
        'title': '${over.length} products appear overstocked',
        'message':
            'About KWD ${overValue.toStringAsFixed(3)} is tied up in stock above current demand-based targets.',
        'value': overValue,
        'count': over.length,
        'confidence': 'Medium',
        'action': 'Review Stock Decisions',
        'nav': 8,
        'icon': 'overstock'
      });

    final dead = inventory
        .where((r) =>
            n(r, 'stock') > 0.001 &&
            (f(r, 'dead_stock') || f(r, 'not_sold_recently')))
        .toList();
    final deadValue = dead.fold<double>(0, (a, r) => a + n(r, 'stock_value'));
    if (dead.isNotEmpty)
      actions.add({
        'key': 'dead_stock',
        'priority': 70,
        'kind': 'Sell / transfer',
        'title': '${dead.length} products are slow or idle',
        'message':
            'KWD ${deadValue.toStringAsFixed(3)} is tied up in products with weak or no recent movement. Consider promotion, transfer, supplier return or target reduction.',
        'value': deadValue,
        'count': dead.length,
        'confidence': 'Medium',
        'action': 'Open Inventory Intelligence',
        'nav': 8,
        'icon': 'dead'
      });

    final expiry =
        inventory.where((r) => n(r, 'projected_expiry_value') > 0.001).toList();
    final expiryValue =
        expiry.fold<double>(0, (a, r) => a + n(r, 'projected_expiry_value'));
    if (expiry.isNotEmpty)
      actions.add({
        'key': 'expiry',
        'priority': 92,
        'kind': 'Expiry',
        'title': '${expiry.length} products have projected expiry exposure',
        'message':
            'About KWD ${expiryValue.toStringAsFixed(3)} may remain unsold before the nearest tracked lots expire.',
        'value': expiryValue,
        'count': expiry.length,
        'confidence': 'High',
        'action': 'Review Expiry Risk',
        'nav': 8,
        'icon': 'expiry'
      });

    final periodEnd = DateTime(now.year, now.month, now.day);
    final periodStart = periodEnd.subtract(Duration(days: days - 1));
    final currentSummary = await reportSummaryBetween(periodStart, periodEnd);
    final previousSummary = await reportSummaryBetween(
        periodStart.subtract(Duration(days: days)),
        periodStart.subtract(const Duration(days: 1)));
    final curSales = (currentSummary['sales'] ?? 0).toDouble();
    final prevSales = (previousSummary['sales'] ?? 0).toDouble();
    final salesChange =
        prevSales > 0 ? ((curSales - prevSales) / prevSales * 100) : 0.0;
    if (prevSales > 0 && salesChange <= -8)
      actions.add({
        'key': 'sales_decline',
        'priority': 85,
        'kind': 'Sales',
        'title': 'Revenue is down ${salesChange.abs().toStringAsFixed(1)}%',
        'message':
            'Net sales in the last $days days are KWD ${curSales.toStringAsFixed(3)} versus KWD ${prevSales.toStringAsFixed(3)} in the preceding comparable period.',
        'value': curSales,
        'count': 0,
        'confidence': 'High',
        'action': 'View Reports',
        'nav': 15,
        'icon': 'sales'
      });

    final cm = (currentSummary['grossMargin'] ?? 0).toDouble(),
        pm = (previousSummary['grossMargin'] ?? 0).toDouble();
    final cr = curSales, pr = prevSales;
    final cmp = cr > 0 ? cm / cr * 100 : 0.0,
        pmp = pr > 0 ? pm / pr * 100 : 0.0,
        marginDelta = cmp - pmp;
    if (pr > 0 && marginDelta <= -2)
      actions.add({
        'key': 'margin_decline',
        'priority': 88,
        'kind': 'Margin',
        'title':
            'Gross margin rate fell ${marginDelta.abs().toStringAsFixed(1)} points',
        'message':
            'Current gross margin is ${cmp.toStringAsFixed(1)}% versus ${pmp.toStringAsFixed(1)}% in the previous comparable period. Review discounting, selling price and cost movement.',
        'value': cm,
        'count': 0,
        'confidence': 'High',
        'action': 'View Reports',
        'nav': 15,
        'icon': 'margin'
      });

    final overdueRows = await db.rawQuery('''
      SELECT COUNT(*) customer_count,COALESCE(SUM(balance),0) overdue,
             COALESCE(SUM(CASE WHEN due_date<datetime('now','-30 day') THEN balance ELSE 0 END),0) overdue_30
      FROM sales WHERE branch_id=? AND balance>0.001 AND due_date IS NOT NULL AND due_date<datetime('now') AND COALESCE(status,'Completed')<>'Cancelled'
    ''', [branchId]);
    final od = overdueRows.first;
    final overdue = (od['overdue'] as num? ?? 0).toDouble(),
        overdue30 = (od['overdue_30'] as num? ?? 0).toDouble();
    if (overdue > 0.001)
      actions.add({
        'key': 'customer_overdue',
        'priority': 90,
        'kind': 'Customers',
        'title': 'KWD ${overdue.toStringAsFixed(3)} is overdue',
        'message':
            '${od['customer_count']} open invoices have overdue balances; KWD ${overdue30.toStringAsFixed(3)} is more than 30 days late.',
        'value': overdue,
        'count': od['customer_count'],
        'confidence': 'High',
        'action': 'Open Payments & Ledgers',
        'nav': 11,
        'icon': 'customer'
      });

    final quoteRows = await db.rawQuery('''
      SELECT COUNT(*) quote_count,COALESCE(SUM(total),0) quote_value
      FROM quotations
      WHERE branch_id=? AND status='Sent' AND created_at<datetime('now','-3 day')
        AND (valid_until IS NULL OR valid_until>=datetime('now'))
    ''', [branchId]);
    final qr = quoteRows.first;
    final quoteCount = (qr['quote_count'] as num? ?? 0).toInt();
    final quoteValue = (qr['quote_value'] as num? ?? 0).toDouble();
    if (quoteCount > 0)
      actions.add({
        'key': 'quotation_followup',
        'priority': 74,
        'kind': 'Sales follow-up',
        'title':
            '$quoteCount sent quotation${quoteCount == 1 ? '' : 's'} need follow-up',
        'message':
            'KWD ${quoteValue.toStringAsFixed(3)} of open quotations were sent more than 3 days ago and have not been converted.',
        'value': quoteValue,
        'count': quoteCount,
        'confidence': 'High',
        'action': 'Follow Up Quotations',
        'nav': 10,
        'icon': 'sales'
      });

    final productStats = await db.rawQuery('''
      WITH s AS (
        SELECT si.product_id,SUM(si.line_total) revenue,SUM(si.qty) qty,SUM(si.line_total-si.cost*si.qty) gross_profit,COUNT(DISTINCT si.sale_id) tx
        FROM sale_items si JOIN sales x ON x.id=si.sale_id
        WHERE x.branch_id=? AND x.created_at>=? AND COALESCE(x.status,'Completed')<>'Cancelled'
        GROUP BY si.product_id)
      SELECT p.id,p.name,p.category,p.cost,COALESCE(bs.qty,0) stock,COALESCE(s.revenue,0) revenue,COALESCE(s.qty,0) sold_qty,
             COALESCE(s.gross_profit,0) gross_profit,COALESCE(s.tx,0) tx,
             COALESCE((SELECT SUM(sri.qty) FROM sale_return_items sri JOIN sales_returns sr ON sr.id=sri.return_id WHERE sri.product_id=p.id AND sr.branch_id=? AND sr.created_at>=? AND COALESCE(sr.status,'Posted')<>'Cancelled'),0) returned_qty,
             COALESCE((SELECT SUM(sl.remaining_qty * MAX(julianday('now')-julianday(sl.created_at),0))/NULLIF(SUM(sl.remaining_qty),0) FROM stock_lots sl WHERE sl.product_id=p.id AND sl.branch_id=? AND sl.remaining_qty>0.000001),0) avg_age_days
      FROM products p LEFT JOIN branch_stock bs ON bs.product_id=p.id AND bs.branch_id=? LEFT JOIN s ON s.product_id=p.id
      WHERE p.active=1 AND COALESCE(p.product_type,'Stocked')='Stocked' ORDER BY revenue DESC
    ''', [branchId, currentFrom, branchId, currentFrom, branchId, branchId]);
    final totalRevenue = productStats.fold<double>(
        0, (a, r) => a + (r['revenue'] as num? ?? 0).toDouble());
    double cumulative = 0;
    for (final r in productStats) {
      final rev = (r['revenue'] as num? ?? 0).toDouble();
      cumulative += rev;
      final share = totalRevenue > 0 ? cumulative / totalRevenue : 1.0;
      final abc = share <= .80
          ? 'A'
          : share <= .95
              ? 'B'
              : 'C';
      final qty = (r['sold_qty'] as num? ?? 0).toDouble();
      final tx = (r['tx'] as num? ?? 0).toDouble();
      final xyz = qty <= 0
          ? 'Z'
          : tx >= 8
              ? 'X'
              : tx >= 3
                  ? 'Y'
                  : 'Z';
      final stock = (r['stock'] as num? ?? 0).toDouble();
      final cost = (r['cost'] as num? ?? 0).toDouble();
      final gp = (r['gross_profit'] as num? ?? 0).toDouble();
      final invValue = stock * cost;
      final gmroi = invValue > 0 ? gp / invValue : 0.0;
      final returned = (r['returned_qty'] as num? ?? 0).toDouble();
      final returnRate = qty > 0 ? (returned / qty) * 100 : 0.0;
      portfolio.add({
        ...r,
        'abc': abc,
        'xyz': xyz,
        'gmroi': gmroi,
        'inventory_value': invValue,
        'return_rate_pct': returnRate
      });
    }

    final supplierSignals = await db.rawQuery('''
      WITH recent AS (SELECT p.supplier_id,pi.product_id,AVG(pi.unit_cost) avg_cost FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id WHERE p.branch_id=? AND p.created_at>=? AND COALESCE(p.status,'Received')<>'Cancelled' GROUP BY p.supplier_id,pi.product_id),
           older AS (SELECT p.supplier_id,pi.product_id,AVG(pi.unit_cost) avg_cost FROM purchase_items pi JOIN purchases p ON p.id=pi.purchase_id WHERE p.branch_id=? AND p.created_at>=? AND p.created_at<? AND COALESCE(p.status,'Received')<>'Cancelled' GROUP BY p.supplier_id,pi.product_id)
      SELECT sp.id,sp.name,sp.balance,sp.credit_balance,
             (SELECT MAX(created_at) FROM purchases WHERE supplier_id=sp.id AND branch_id=? AND status<>'Cancelled') last_purchase,
             (SELECT COUNT(*) FROM purchases WHERE supplier_id=sp.id AND branch_id=? AND created_at>=? AND status<>'Cancelled') purchase_count,
             COUNT(r.product_id) products_checked,AVG(CASE WHEN o.avg_cost>0 THEN ((r.avg_cost-o.avg_cost)/o.avg_cost)*100 END) cost_change_pct,
             COALESCE((SELECT SUM(total) FROM purchases p2 WHERE p2.supplier_id=sp.id AND p2.branch_id=? AND p2.created_at>=? AND COALESCE(p2.status,'Received')<>'Cancelled'),0) spend
      FROM suppliers sp LEFT JOIN recent r ON r.supplier_id=sp.id LEFT JOIN older o ON o.supplier_id=r.supplier_id AND o.product_id=r.product_id
      WHERE sp.active=1 GROUP BY sp.id,sp.name HAVING spend>0 ORDER BY spend DESC LIMIT 12
    ''', [
      branchId,
      currentFrom,
      branchId,
      previousFrom,
      currentFrom,
      branchId,
      branchId,
      currentFrom,
      branchId,
      currentFrom
    ]);

    final customerSignals = await db.rawQuery('''
      SELECT c.id,c.name,c.balance,c.credit_balance,COUNT(DISTINCT s.id) visits,COALESCE(SUM(s.total-s.returned_total),0) revenue,
             COALESCE(AVG(s.total-s.returned_total),0) avg_bill,MAX(s.created_at) last_sale,
             COALESCE(SUM(CASE WHEN s.balance>0 AND s.due_date<datetime('now') THEN s.balance ELSE 0 END),0) overdue
      FROM customers c LEFT JOIN sales s ON s.customer_id=c.id AND s.branch_id=? AND s.created_at>=? AND COALESCE(s.status,'Completed')<>'Cancelled'
      WHERE c.active=1 GROUP BY c.id,c.name HAVING visits>0 OR overdue>0 ORDER BY revenue DESC LIMIT 20
    ''', [branchId, currentFrom]);

    final branchSignals = await db.rawQuery('''
      WITH sold AS (SELECT s.branch_id,si.product_id,SUM(si.qty) qty FROM sale_items si JOIN sales s ON s.id=si.sale_id WHERE s.created_at>=? AND COALESCE(s.status,'Completed')<>'Cancelled' GROUP BY s.branch_id,si.product_id)
      SELECT b.id branch_id,b.name branch_name,p.id product_id,p.name product_name,COALESCE(bs.qty,0) stock,COALESCE(sold.qty,0) sold_qty
      FROM branches b JOIN branch_stock bs ON bs.branch_id=b.id JOIN products p ON p.id=bs.product_id
      LEFT JOIN sold ON sold.branch_id=b.id AND sold.product_id=p.id WHERE b.active=1 AND p.active=1
    ''', [currentFrom]);
    final byProduct = <String, List<Map<String, Object?>>>{};
    for (final r in branchSignals) {
      byProduct.putIfAbsent('${r['product_id']}', () => []).add(r);
    }
    final branchOpportunities = <Map<String, Object?>>[];
    for (final e in byProduct.entries) {
      final rows = e.value;
      if (rows.length < 2) continue;
      rows.sort((a, b) => ((b['sold_qty'] as num? ?? 0).toDouble())
          .compareTo((a['sold_qty'] as num? ?? 0).toDouble()));
      final fast = rows.first;
      final slow = rows.last;
      final fastSold = (fast['sold_qty'] as num? ?? 0).toDouble(),
          fastStock = (fast['stock'] as num? ?? 0).toDouble();
      final slowSold = (slow['sold_qty'] as num? ?? 0).toDouble(),
          slowStock = (slow['stock'] as num? ?? 0).toDouble();
      if (fastSold >= 3 &&
          fastStock < fastSold * .5 &&
          slowStock > fastStock + 2 &&
          slowSold < fastSold * .5) {
        branchOpportunities.add({
          'product_id': e.key,
          'product_name': fast['product_name'],
          'from_branch': slow['branch_name'],
          'to_branch': fast['branch_name'],
          'from_stock': slowStock,
          'to_stock': fastStock,
          'to_sold': fastSold
        });
      }
    }
    if (branchOpportunities.isNotEmpty)
      actions.add({
        'key': 'branch_balance',
        'priority': 74,
        'kind': 'Branches',
        'title':
            '${branchOpportunities.length} stock-transfer opportunities found',
        'message':
            'Some products are idle or better stocked in one branch while selling faster in another.',
        'value': 0.0,
        'count': branchOpportunities.length,
        'confidence': 'Medium',
        'action': 'Open Stock Transfers',
        'nav': 4,
        'icon': 'branch'
      });

    actions
        .sort((a, b) => (b['priority'] as num).compareTo(a['priority'] as num));
    final actionStateRows = await db.query('business_action_state');
    final actionStates = {
      for (final r in actionStateRows) '${r['action_key']}': r
    };
    final visibleActions = <Map<String, Object?>>[];
    for (final original in actions) {
      final a = <String, Object?>{...original};
      final actionKey = '${a['key']}';
      final value = (a['value'] as num? ?? 0).toDouble();
      final count = (a['count'] as num? ?? 0).toInt();
      final fingerprint = '$actionKey:$count:${value.toStringAsFixed(2)}';
      a['fingerprint'] = fingerprint;
      if (snoozed.containsKey(actionKey)) continue;
      final state = actionStates[actionKey];
      if (state != null) {
        final status = '${state['status'] ?? 'Open'}';
        final oldFingerprint = '${state['fingerprint'] ?? ''}';
        final until = DateTime.tryParse('${state['snoozed_until'] ?? ''}');
        if (status == 'Snoozed' && until != null && until.isAfter(now))
          continue;
        if ((status == 'Resolved' || status == 'Dismissed') &&
            oldFingerprint == fingerprint) continue;
      }
      visibleActions.add(a);
    }
    final stockDiscrepancies = inventory
        .where((r) => (r['stock_discrepancy'] as num? ?? 0).toInt() == 1)
        .length;
    final dormantProducts =
        inventory.where((r) => '${r['demand_state']}' == 'Dormant').length;
    return {
      'actions': visibleActions,
      'snoozed': snoozed,
      'portfolio': portfolio,
      'customers': customerSignals,
      'suppliers': supplierSignals,
      'branches': branchOpportunities,
      'summary': {
        'action_count': visibleActions.length,
        'stock_value':
            inventory.fold<double>(0, (a, r) => a + n(r, 'stock_value')),
        'reorder_value': buyValue,
        'expiry_risk': expiryValue,
        'overdue': overdue,
        'sales_change_pct': salesChange,
        'margin_pct': cmp,
        'margin_change_points': marginDelta,
        'stock_discrepancies': stockDiscrepancies,
        'dormant_products': dormantProducts,
        'quotation_followups': quoteCount
      }
    };
  }

  Future<String> removeBranch(String id) async {
    await requirePermission('users', 'remove branches');
    if ((await operationalContext())['branch_id'] == id)
      throw Exception('Switch branches before removing the active branch.');
    return db.transaction((t) async {
      final row =
          (await t.query('branches', where: 'id=?', whereArgs: [id], limit: 1))
              .first;
      var used = false;
      for (final table in [
        'sales',
        'purchases',
        'stock_movements',
        'stock_lots',
        'stock_transfers',
        'payments',
        'expenses',
        'purchase_orders',
        'stock_counts',
        'terminals',
        'user_branches'
      ]) {
        final cols = await t.rawQuery('PRAGMA table_info($table)');
        for (final col in cols.where((c) => [
              'branch_id',
              'from_branch_id',
              'to_branch_id'
            ].contains(c['name']))) {
          final matches = await t.query(table,
              where: '${col['name']}=?', whereArgs: [id], limit: 1);
          if (matches.isNotEmpty) used = true;
        }
      }
      if ((await t.query('branch_stock',
              where: 'branch_id=? AND ABS(qty)>0.000001',
              whereArgs: [id],
              limit: 1))
          .isNotEmpty) used = true;
      if (used) {
        await t.update('branches', {'active': 0},
            where: 'id=?', whereArgs: [id]);
        await _queueMasterRecordTx(t,
            entityType: 'branch',
            entityId: id,
            operation: 'upsert',
            record: await _rowById(t, 'branches', id));
      } else {
        await t.delete('branch_stock', where: 'branch_id=?', whereArgs: [id]);
        await t.delete('branches', where: 'id=?', whereArgs: [id]);
        await _queueMasterRecordTx(t,
            entityType: 'branch',
            entityId: id,
            operation: 'delete',
            record: row,
            extras: {'deleted': true});
      }
      await _audit(t, used ? 'Archive branch' : 'Delete branch', 'branch', id,
          '${row['name']}');
      return used
          ? 'Branch archived; historical records retained.'
          : 'Unused branch deleted.';
    });
  }

  /// An unlinked return is a separate accounting document, never a fabricated sale.
  Future<String> postUnlinkedReturn(
      {required bool purchase,
      String? partyId,
      required List<Map<String, Object?>> items,
      required String notes,
      String refundMethod = 'Cash',
      bool restoreStock = true}) async {
    await LicenseManager.instance.requireUsable(
        entitlement: purchase
            ? LicenseEntitlements.purchases
            : LicenseEntitlements.corePos);
    await requirePermission('returns', 'post returns without an invoice');
    if (items.isEmpty || notes.trim().isEmpty)
      throw Exception('Add a product and a return reason.');
    if (purchase && (partyId == null || partyId.isEmpty))
      throw Exception('Select a supplier.');
    final id = _id(purchase ? 'PR' : 'RET');
    final no =
        '${purchase ? 'PR' : 'R'}-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final branch = ctx['branch_id']!;
      final prepared = <Map<String, Object?>>[];
      final seen = <String>{};
      double total = 0;
      for (final line in items) {
        final pid = '${line['product_id']}';
        final qty = (line['qty'] as num).toDouble();
        final value = (line['amount'] as num).toDouble();
        if (!seen.add(pid)) throw Exception('Combine duplicate product lines.');
        if (!qty.isFinite || !value.isFinite || qty <= 0 || value <= 0)
          throw Exception(
              'Quantity and return amount must be finite and positive.');
        final rows = await t.query('products',
            where: 'id=? AND active=1', whereArgs: [pid], limit: 1);
        if (rows.isEmpty) throw Exception('Product is missing or inactive.');
        final product = rows.first;
        if ((product['product_type'] ?? 'Stocked') != 'Stocked')
          throw Exception(
              'Use an invoice-linked return for recipe or combo products.');
        if (purchase && await _branchQty(t, pid, branch) + .000001 < qty)
          throw Exception('Insufficient branch stock for ${product['name']}.');
        prepared.add({
          ...line,
          'name': product['name'],
          'cost': (product['cost'] as num? ?? 0).toDouble() * qty
        });
        total += value;
      }
      if (!total.isFinite ||
          prepared.any((line) => !(line['cost'] as num).isFinite))
        throw Exception('Return values exceed the supported range.');
      final partyTable = purchase ? 'suppliers' : 'customers';
      final sourceTable = purchase ? 'purchases' : 'sales';
      final fk = purchase ? 'supplier_id' : 'customer_id';
      double reduction = 0, credit = 0;
      final adjustments = <Map<String, Object?>>[];
      if (purchase) {
        final party = await t.query(partyTable,
            where: 'id=? AND active=1', whereArgs: [partyId], limit: 1);
        if (party.isEmpty) throw Exception('Supplier is missing or inactive.');
        final balance = (party.first['balance'] as num? ?? 0).toDouble();
        reduction = min(total, max(balance, 0.0));
        credit = total - reduction;
        var remaining = reduction;
        final invoices = await t.query(sourceTable,
            where:
                "$fk=? AND balance>0 AND COALESCE(status,'Received')<>'Cancelled'",
            whereArgs: [partyId],
            orderBy: 'created_at,id');
        for (final invoice in invoices) {
          if (remaining <= .000001) break;
          final amount = min(remaining, (invoice['balance'] as num).toDouble());
          await t.rawUpdate(
              'UPDATE $sourceTable SET balance=MAX(balance-?,0) WHERE id=?',
              [amount, invoice['id']]);
          adjustments.add({'id': invoice['id'], 'amount': amount});
          remaining -= amount;
        }
        await t.rawUpdate(
            'UPDATE $partyTable SET balance=MAX(balance-?,0),credit_balance=COALESCE(credit_balance,0)+? WHERE id=?',
            [reduction, credit, partyId]);
      } else if (partyId != null) {
        if ((await t.query(partyTable,
                where: 'id=? AND active=1', whereArgs: [partyId], limit: 1))
            .isEmpty) throw Exception('Customer is missing or inactive.');
      }
      final headers = purchase ? 'purchase_returns' : 'sales_returns';
      final lines = purchase ? 'purchase_return_items' : 'sale_return_items';
      await t.insert(headers, {
        'id': id,
        'no': no,
        (purchase ? 'purchase_id' : 'sale_id'): null,
        'party_id': partyId,
        'created_at': now,
        'total': total,
        'refund_amount': purchase ? 0 : total,
        'refund_method': purchase ? 'Supplier Credit' : refundMethod,
        'status': 'Posted',
        'notes': 'Unlinked return: ${notes.trim()}',
        'branch_id': branch,
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      });
      for (final line in prepared) {
        final pid = '${line['product_id']}';
        final qty = (line['qty'] as num).toDouble();
        final amount = (line['amount'] as num).toDouble();
        await t.insert(lines, {
          'return_id': id,
          (purchase ? 'purchase_item_id' : 'sale_item_id'): null,
          'product_id': pid,
          'name': line['name'],
          'qty': qty,
          (purchase ? 'unit_cost' : 'unit_price'): amount / qty,
          'line_total': amount,
          'tax': 0,
          if (!purchase) 'cost': restoreStock ? line['cost'] : 0
        });
        final delta = purchase
            ? -qty
            : restoreStock
                ? qty
                : 0.0;
        if (delta != 0) {
          if (purchase) {
            await _consumeLots(t, pid, branch, qty);
          } else {
            await t.insert('stock_lots', {
              'id': _id('LOT'),
              'product_id': pid,
              'branch_id': branch,
              'purchase_item_id': null,
              'batch_no': 'UNLINKED-RETURN',
              'expiry_date': null,
              'received_qty': qty,
              'remaining_qty': qty,
              'unit_cost': (line['cost'] as num) / qty,
              'created_at': now,
              'status': 'Open'
            });
          }
          await _changeBranchStock(t, pid, branch, delta);
          await t.insert('stock_movements', {
            'created_at': now,
            'product_id': pid,
            'qty_change': delta,
            'type': purchase ? 'Purchase Return' : 'Sale Return',
            'reference': no,
            'reason': notes.trim(),
            'branch_id': branch,
            'terminal_id': ctx['terminal_id'],
            'user_id': ctx['user_id']
          });
        }
      }
      if (!purchase) {
        await t.insert('payments', {
          'id': _id('PAY'),
          'created_at': now,
          'party_type': 'Customer',
          'party_id': partyId,
          'document_type': 'Sale Return',
          'document_id': id,
          'amount': -total,
          'method': refundMethod,
          'reference': no,
          'notes': notes.trim(),
          'branch_id': branch,
          'terminal_id': ctx['terminal_id'],
          'user_id': ctx['user_id']
        });
      }
      await _audit(
          t,
          'Unlinked ${purchase ? 'purchase' : 'sale'} return',
          purchase ? 'purchase_return' : 'sale_return',
          id,
          '$no • $total • payable reduction $reduction • supplier credit $credit • ${notes.trim()}');
      await _enqueueSyncEventTx(t,
          entityType: purchase ? 'purchase_return_txn' : 'sale_return_txn',
          entityId: id,
          operation: 'post',
          payload: {
            'schema': 1,
            'return': await _rowById(t, headers, id),
            'items':
                await t.query(lines, where: 'return_id=?', whereArgs: [id]),
            'payments': await t
                .query('payments', where: 'document_id=?', whereArgs: [id]),
            'stock_effects': await t.query('stock_movements',
                where: 'reference=?', whereArgs: [no]),
            'party_id': partyId ?? '',
            'party_balance_delta': -reduction,
            'party_credit_delta': credit,
            'balance_adjustments': adjustments
          });
    });
    return no;
  }

  Future<Map<String, dynamic>> partyInsight(String id,
      {required bool supplier, int days = 30}) async {
    final branch = (await operationalContext())['branch_id'];
    final source = supplier ? 'purchases' : 'sales';
    final fk = supplier ? 'supplier_id' : 'customer_id';
    final lines = supplier ? 'purchase_items' : 'sale_items';
    final link = supplier ? 'purchase_id' : 'sale_id';
    final start =
        DateTime.now().subtract(Duration(days: days)).toIso8601String();
    final trend = await db.rawQuery(
        "SELECT strftime('%Y-%m',created_at) month,SUM(total) value FROM $source WHERE $fk=? AND branch_id=? AND created_at>=? AND status<>'Cancelled' GROUP BY month ORDER BY month",
        [id, branch, start]);
    final top = await db.rawQuery(
        "SELECT i.name,SUM(i.qty) qty,SUM(i.line_total) value FROM $lines i JOIN $source h ON h.id=i.$link WHERE h.$fk=? AND h.branch_id=? AND h.created_at>=? AND h.status<>'Cancelled' GROUP BY i.product_id,i.name ORDER BY value DESC LIMIT 5",
        [id, branch, start]);
    final payment = await db.rawQuery(
        "SELECT COUNT(*) count,COALESCE(SUM(ABS(amount)),0) total,MAX(created_at) last_payment FROM payments WHERE party_id=? AND party_type=? AND branch_id=? AND created_at>=?",
        [id, supplier ? 'Supplier' : 'Customer', branch, start]);
    return {'trend': trend, 'products': top, 'payments': payment.first};
  }

  Future<List<Map<String, Object?>>> returnCandidates(
      {required bool purchase,
      required List<String> productIds,
      String? partyId}) async {
    if (productIds.isEmpty) return [];
    final table = purchase ? 'purchases' : 'sales',
        lines = purchase ? 'purchase_items' : 'sale_items',
        fk = purchase ? 'purchase_id' : 'sale_id',
        partyFk = purchase ? 'supplier_id' : 'customer_id';
    final branch = (await operationalContext())['branch_id'];
    final placeholders = List.filled(productIds.length, '?').join(',');
    return db.rawQuery(
        "SELECT DISTINCT h.* FROM $table h JOIN $lines i ON i.$fk=h.id WHERE h.branch_id=? AND h.status<>'Cancelled' AND i.product_id IN ($placeholders) ${partyId == null ? '' : 'AND h.$partyFk=?'} ORDER BY h.created_at DESC LIMIT 20",
        [branch, ...productIds, if (partyId != null) partyId]);
  }

  Future<void> linkReturnReference(
      {required bool purchase,
      required String returnId,
      required String invoiceId}) async {
    await requirePermission('returns', 'link return invoice references');
    final table = purchase ? 'purchase_returns' : 'sales_returns',
        source = purchase ? 'purchases' : 'sales';
    await db.transaction((t) async {
      final returns =
          await t.query(table, where: 'id=?', whereArgs: [returnId], limit: 1);
      final invoices = await t.query(source,
          where: 'id=?', whereArgs: [invoiceId], limit: 1);
      if (returns.isEmpty || invoices.isEmpty)
        throw Exception('Return or invoice is missing.');
      final r = returns.first, invoice = invoices.first;
      if (r[purchase ? 'purchase_id' : 'sale_id'] != null)
        throw Exception('This return already has an original invoice.');
      if (r['branch_id'] != invoice['branch_id'])
        throw Exception('The invoice belongs to another branch.');
      if (r['party_id'] != null &&
          r['party_id'] != invoice[purchase ? 'supplier_id' : 'customer_id'])
        throw Exception('The invoice belongs to another customer or supplier.');
      await t.update(table, {'source_reference': invoice['no']},
          where: 'id=?', whereArgs: [returnId]);
      await _audit(
          t,
          'Link return invoice reference',
          purchase ? 'purchase_return' : 'sale_return',
          returnId,
          '${r['no']} → ${invoice['no']} (reference only; financial posting unchanged)');
      await _enqueueSyncEventTx(t,
          entityType: 'return_reference',
          entityId: returnId,
          operation: 'link',
          payload: {
            'schema': 1,
            'purchase': purchase,
            'source_reference': invoice['no']
          });
    });
  }

  Future<List<Map<String, Object?>>> morningTopProducts() async {
    final branch = (await operationalContext())['branch_id'];
    return db.rawQuery(
        '''SELECT i.product_id,i.name,SUM(i.qty) qty,SUM(i.line_total) revenue
      FROM sale_items i JOIN sales s ON s.id=i.sale_id
      WHERE s.branch_id=? AND s.created_at>=? AND COALESCE(s.status,'Completed')<>'Cancelled'
      GROUP BY i.product_id,i.name ORDER BY revenue DESC LIMIT 5''',
        [
          branch,
          DateTime.now().subtract(const Duration(days: 7)).toIso8601String()
        ]);
  }

  Future<void> recordAudit(
      String action, String entity, String entityId, String details) async {
    await db.transaction((t) => _audit(t, action, entity, entityId, details));
  }

  Map<String, Object?> _auditWhere({
    String search = '',
    String action = 'All',
    String entity = 'All',
    String userId = 'All',
    String branchId = 'All',
    DateTime? from,
    DateTime? to,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    final q = search.trim().toLowerCase();
    if (q.isNotEmpty) {
      where.add(
          "(LOWER(COALESCE(a.action,'')) LIKE ? OR LOWER(COALESCE(a.entity,'')) LIKE ? OR LOWER(COALESCE(a.entity_id,'')) LIKE ? OR LOWER(COALESCE(a.details,'')) LIKE ? OR LOWER(COALESCE(u.display_name,a.user_id,a.user,'')) LIKE ? OR LOWER(COALESCE(b.name,'')) LIKE ? OR LOWER(COALESCE(tm.name,'')) LIKE ?)");
      final like = '%$q%';
      args.addAll([like, like, like, like, like, like, like]);
    }
    if (action != 'All') {
      where.add('a.action=?');
      args.add(action);
    }
    if (entity != 'All') {
      where.add('a.entity=?');
      args.add(entity);
    }
    if (userId != 'All') {
      where.add('COALESCE(a.user_id,a.user)=?');
      args.add(userId);
    }
    if (branchId != 'All') {
      where.add('a.branch_id=?');
      args.add(branchId);
    }
    if (from != null) {
      where.add('a.created_at>=?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      where.add('a.created_at<?');
      args.add(DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1))
          .toIso8601String());
    }
    return {'where': where, 'args': args};
  }

  String _auditSelectSql(String whereSql) => '''SELECT a.*,
      COALESCE(u.display_name,a.user_id,a.user,'Unknown') AS user_name,
      u.username AS username,
      b.name AS branch_name,
      tm.name AS terminal_name
      FROM audit a
      LEFT JOIN users u ON u.id=COALESCE(a.user_id,a.user)
      LEFT JOIN branches b ON b.id=a.branch_id
      LEFT JOIN terminals tm ON tm.id=a.terminal_id
      $whereSql''';

  Future<Map<String, Object?>> auditPage({
    String search = '',
    String action = 'All',
    String entity = 'All',
    String userId = 'All',
    String branchId = 'All',
    DateTime? from,
    DateTime? to,
    int limit = 50,
    int offset = 0,
  }) async {
    await requirePermission('audit_trail', 'view the audit trail');
    final filter = _auditWhere(
      search: search,
      action: action,
      entity: entity,
      userId: userId,
      branchId: branchId,
      from: from,
      to: to,
    );
    final where = (filter['where'] as List<String>);
    final args = List<Object?>.from(filter['args'] as List<Object?>);
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final needsSearchJoin = search.trim().isNotEmpty;
    final countRows = await db.rawQuery('''SELECT COUNT(*) AS c
      FROM audit a
      ${needsSearchJoin ? 'LEFT JOIN users u ON u.id=COALESCE(a.user_id,a.user) LEFT JOIN branches b ON b.id=a.branch_id LEFT JOIN terminals tm ON tm.id=a.terminal_id' : ''}
      $whereSql''', args);
    final total = _firstIntValue(countRows) ?? 0;
    final safeLimit = limit.clamp(10, 200).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    final rows = await db.rawQuery(
      '${_auditSelectSql(whereSql)} ORDER BY a.created_at DESC,a.id DESC LIMIT ? OFFSET ?',
      [...args, safeLimit, safeOffset],
    );
    return {'rows': rows, 'total': total};
  }

  Future<List<Map<String, Object?>>> auditEntries({
    String search = '',
    String action = 'All',
    String entity = 'All',
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    final page = await auditPage(
      search: search,
      action: action,
      entity: entity,
      from: from,
      to: to,
      limit: limit.clamp(10, 200).toInt(),
    );
    return (page['rows'] as List).cast<Map<String, Object?>>();
  }

  Future<Map<String, Object?>> auditFilterData() async {
    await requirePermission('audit_trail', 'view the audit trail');
    final actions = await db.rawQuery(
        "SELECT DISTINCT action FROM audit WHERE COALESCE(action,'')<>'' ORDER BY action");
    final entities = await db.rawQuery(
        "SELECT DISTINCT entity FROM audit WHERE COALESCE(entity,'')<>'' ORDER BY entity");
    final users = await db.rawQuery('''SELECT DISTINCT
      COALESCE(a.user_id,a.user) AS id,
      COALESCE(u.display_name,a.user_id,a.user,'Unknown') AS name,
      COALESCE(u.username,'') AS username
      FROM audit a LEFT JOIN users u ON u.id=COALESCE(a.user_id,a.user)
      WHERE COALESCE(a.user_id,a.user,'')<>'' ORDER BY name''');
    final branches = await db.rawQuery('''SELECT DISTINCT a.branch_id AS id,
      COALESCE(b.name,a.branch_id) AS name
      FROM audit a LEFT JOIN branches b ON b.id=a.branch_id
      WHERE COALESCE(a.branch_id,'')<>'' ORDER BY name''');
    return {
      'actions': actions.map((e) => '${e['action']}').toList(),
      'entities': entities.map((e) => '${e['entity']}').toList(),
      'users': users,
      'branches': branches,
    };
  }

  Future<Map<String, List<String>>> auditFilterOptions() async {
    final data = await auditFilterData();
    return {
      'actions': (data['actions'] as List).map((e) => '$e').toList(),
      'entities': (data['entities'] as List).map((e) => '$e').toList(),
    };
  }

  Future<Map<String, Object?>> auditStats() async {
    await requirePermission('audit_trail', 'view audit statistics');
    final summary = await db.rawQuery('''SELECT
      COUNT(*) AS c,
      MIN(created_at) AS oldest,
      MAX(created_at) AS newest
      FROM audit''');
    // Estimate storage from a small recent sample instead of scanning every
    // details field. This keeps the statistics card cheap even with millions
    // of audit rows.
    final sample =
        await db.rawQuery('''SELECT AVG(row_bytes) AS avg_bytes FROM (
      SELECT 96 + LENGTH(COALESCE(created_at,'')) + LENGTH(COALESCE(user,'')) +
        LENGTH(COALESCE(action,'')) + LENGTH(COALESCE(entity,'')) +
        LENGTH(COALESCE(entity_id,'')) + LENGTH(COALESCE(details,'')) +
        LENGTH(COALESCE(branch_id,'')) + LENGTH(COALESCE(terminal_id,'')) +
        LENGTH(COALESCE(user_id,'')) AS row_bytes
      FROM audit ORDER BY id DESC LIMIT 500
    )''');
    final recent = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM audit WHERE created_at>=?',
      [DateTime.now().subtract(const Duration(days: 30)).toIso8601String()],
    );
    final dir = await dataDir;
    Future<int> sizeOf(String path) async {
      final file = File(path);
      return await file.exists() ? await file.length() : 0;
    }

    final livePath = p.join(dir, 'reliq_solutions.db');
    final databaseBytes = await sizeOf(livePath) +
        await sizeOf('$livePath-wal') +
        await sizeOf('$livePath-shm');
    final archiveDir = Directory(p.join(dir, 'audit_archives'));
    var archiveCount = 0;
    var archiveBytes = 0;
    if (await archiveDir.exists()) {
      await for (final item in archiveDir.list()) {
        if (item is File && item.path.toLowerCase().endsWith('.db')) {
          archiveCount++;
          archiveBytes += await item.length();
        }
      }
    }
    final row = summary.isEmpty ? const <String, Object?>{} : summary.first;
    final total = ((row['c'] as num?) ?? 0).toInt();
    final avgBytes = sample.isEmpty
        ? 0.0
        : ((sample.first['avg_bytes'] as num?) ?? 0).toDouble();
    return {
      'total': total,
      'last_30_days': _firstIntValue(recent) ?? 0,
      'oldest': row['oldest'],
      'newest': row['newest'],
      'estimated_bytes': (avgBytes * total).round(),
      'database_bytes': databaseBytes,
      'archive_count': archiveCount,
      'archive_bytes': archiveBytes,
      'archive_directory': archiveDir.path,
    };
  }

  String _csvCell(Object? value) {
    final text = value?.toString() ?? '';
    if (text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  Future<int> exportAuditCsvTo(
    String path, {
    String search = '',
    String action = 'All',
    String entity = 'All',
    String userId = 'All',
    String branchId = 'All',
    DateTime? from,
    DateTime? to,
  }) async {
    await requirePermission('audit_trail', 'export the audit trail');
    final filter = _auditWhere(
      search: search,
      action: action,
      entity: entity,
      userId: userId,
      branchId: branchId,
      from: from,
      to: to,
    );
    final where = (filter['where'] as List<String>);
    final args = List<Object?>.from(filter['args'] as List<Object?>);
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final sink = File(path).openWrite();
    var exported = 0;
    try {
      sink.writeln(
          'Time,User,Username,Action,Entity,Entity ID,Branch,Terminal,Details');
      var offset = 0;
      const chunk = 1000;
      while (true) {
        final rows = await db.rawQuery(
          '${_auditSelectSql(whereSql)} ORDER BY a.created_at DESC,a.id DESC LIMIT ? OFFSET ?',
          [...args, chunk, offset],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          sink.writeln([
            row['created_at'],
            row['user_name'],
            row['username'],
            row['action'],
            row['entity'],
            row['entity_id'],
            row['branch_name'] ?? row['branch_id'],
            row['terminal_name'] ?? row['terminal_id'],
            row['details'],
          ].map(_csvCell).join(','));
        }
        exported += rows.length;
        offset += rows.length;
        if (rows.length < chunk) break;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return exported;
  }

  Future<Map<String, Object?>> archiveAuditOlderThan(DateTime cutoff) async {
    await requirePermission('audit_trail', 'archive the audit trail');
    await requirePermission('backup_restore', 'archive audit history');
    final cutoffDate = DateTime(cutoff.year, cutoff.month, cutoff.day);
    if (cutoffDate.isAfter(DateTime.now().subtract(const Duration(days: 30)))) {
      throw Exception(
          'Choose a cutoff at least 30 days in the past. Recent audit history should stay in the live database.');
    }
    final cutoffIso = cutoffDate.toIso8601String();
    final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM audit WHERE created_at<?', [cutoffIso]);
    final count = _firstIntValue(countRows) ?? 0;
    if (count == 0)
      throw Exception(
          'There are no audit events older than the selected cutoff.');

    final dir = Directory(p.join(await dataDir, 'audit_archives'));
    await dir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final datePart =
        '${cutoffDate.year.toString().padLeft(4, '0')}-${cutoffDate.month.toString().padLeft(2, '0')}-${cutoffDate.day.toString().padLeft(2, '0')}';
    final target =
        p.join(dir.path, 'RELIQ_Audit_Archive_before_${datePart}_$stamp.db');

    final archiveDb = await databaseFactory.openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) async {
          await d.execute('''CREATE TABLE audit(
            id INTEGER PRIMARY KEY,created_at TEXT,user TEXT,action TEXT,entity TEXT,
            entity_id TEXT,details TEXT,branch_id TEXT,terminal_id TEXT,user_id TEXT,
            user_name TEXT,username TEXT,branch_name TEXT,terminal_name TEXT)''');
          await d
              .execute('CREATE TABLE archive_meta(k TEXT PRIMARY KEY,v TEXT)');
          await d.execute(
              'CREATE INDEX idx_archive_created_id ON audit(created_at DESC,id DESC)');
          await d.execute(
              'CREATE INDEX idx_archive_action_created ON audit(action,created_at DESC,id DESC)');
          await d.execute(
              'CREATE INDEX idx_archive_entity_created ON audit(entity,created_at DESC,id DESC)');
          await d.execute(
              'CREATE INDEX idx_archive_user_created ON audit(user_id,created_at DESC,id DESC)');
          await d.execute(
              'CREATE INDEX idx_archive_branch_created ON audit(branch_id,created_at DESC,id DESC)');
        },
      ),
    );

    var lastId = 0;
    var copied = 0;
    try {
      while (true) {
        final rows = await db.rawQuery(
          '''SELECT a.*,
          COALESCE(u.display_name,a.user_id,a.user,'Unknown') AS user_name,
          COALESCE(u.username,'') AS username,
          COALESCE(b.name,a.branch_id,'') AS branch_name,
          COALESCE(tm.name,a.terminal_id,'') AS terminal_name
          FROM audit a
          LEFT JOIN users u ON u.id=COALESCE(a.user_id,a.user)
          LEFT JOIN branches b ON b.id=a.branch_id
          LEFT JOIN terminals tm ON tm.id=a.terminal_id
          WHERE a.created_at<? AND a.id>? ORDER BY a.id LIMIT 1000''',
          [cutoffIso, lastId],
        );
        if (rows.isEmpty) break;
        final batch = archiveDb.batch();
        for (final row in rows) {
          batch.insert('audit', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
        copied += rows.length;
        lastId = ((rows.last['id'] as num?) ?? lastId).toInt();
      }
      final verify =
          await archiveDb.rawQuery('SELECT COUNT(*) AS c FROM audit');
      final archivedCount = _firstIntValue(verify) ?? 0;
      if (archivedCount != count || copied != count) {
        throw Exception(
            'Archive verification failed. No live audit records were removed.');
      }
      final meta = <String, String>{
        'created_at': DateTime.now().toIso8601String(),
        'cutoff': cutoffIso,
        'row_count': '$count',
        'source_node': nodeId,
      };
      final batch = archiveDb.batch();
      for (final entry in meta.entries) {
        batch.insert('archive_meta', {'k': entry.key, 'v': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      await archiveDb.close();
    } catch (e) {
      try {
        await archiveDb.close();
      } catch (_) {}
      try {
        final partial = File(target);
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    }

    await db.transaction((t) async {
      await t.delete('audit', where: 'created_at<?', whereArgs: [cutoffIso]);
      await _audit(
        t,
        'Archive audit history',
        'audit_archive',
        p.basename(target),
        '$count events before $datePart archived to ${p.basename(target)}',
      );
    });
    try {
      await db.execute('PRAGMA wal_checkpoint(PASSIVE)');
    } catch (_) {}
    return {'path': target, 'rows': count, 'cutoff': cutoffIso};
  }

  Future<List<Map<String, Object?>>> auditArchives() async {
    await requirePermission('audit_trail', 'view audit archives');
    final dir = Directory(p.join(await dataDir, 'audit_archives'));
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final item in dir.list()) {
      if (item is File && item.path.toLowerCase().endsWith('.db'))
        files.add(item);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final out = <Map<String, Object?>>[];
    for (final file in files) {
      try {
        final archive = await databaseFactory.openDatabase(file.path,
            options: OpenDatabaseOptions(readOnly: true));
        try {
          final metaRows = await archive.query('archive_meta');
          final meta = {
            for (final row in metaRows) '${row['k']}': '${row['v'] ?? ''}'
          };
          final countRows =
              await archive.rawQuery('SELECT COUNT(*) AS c FROM audit');
          out.add({
            'path': file.path,
            'name': p.basename(file.path),
            'created_at':
                meta['created_at'] ?? file.lastModifiedSync().toIso8601String(),
            'cutoff': meta['cutoff'] ?? '',
            'rows': int.tryParse(meta['row_count'] ?? '') ??
                (_firstIntValue(countRows) ?? 0),
            'bytes': await file.length(),
          });
        } finally {
          await archive.close();
        }
      } catch (_) {
        out.add({
          'path': file.path,
          'name': p.basename(file.path),
          'created_at': file.lastModifiedSync().toIso8601String(),
          'cutoff': '',
          'rows': 0,
          'bytes': await file.length(),
          'error': 'Archive metadata could not be read',
        });
      }
    }
    return out;
  }

  Future<Map<String, Object?>> auditArchivePage(
    String archivePath, {
    String search = '',
    int limit = 50,
    int offset = 0,
  }) async {
    await requirePermission('audit_trail', 'view archived audit history');
    final root =
        p.normalize(p.absolute(p.join(await dataDir, 'audit_archives')));
    final target = p.normalize(p.absolute(archivePath));
    if (!p.isWithin(root, target))
      throw Exception('Invalid audit archive path.');
    final file = File(target);
    if (!await file.exists()) throw Exception('Audit archive not found.');
    final archive = await databaseFactory.openDatabase(target,
        options: OpenDatabaseOptions(readOnly: true));
    try {
      final where = <String>[];
      final args = <Object?>[];
      final q = search.trim().toLowerCase();
      if (q.isNotEmpty) {
        where.add(
            "(LOWER(COALESCE(action,'')) LIKE ? OR LOWER(COALESCE(entity,'')) LIKE ? OR LOWER(COALESCE(entity_id,'')) LIKE ? OR LOWER(COALESCE(details,'')) LIKE ? OR LOWER(COALESCE(user_name,user_id,user,'')) LIKE ?)");
        final like = '%$q%';
        args.addAll([like, like, like, like, like]);
      }
      final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
      final countRows = await archive.rawQuery(
          'SELECT COUNT(*) AS c FROM audit $whereSql', args);
      final safeLimit = limit.clamp(10, 200).toInt();
      final safeOffset = offset < 0 ? 0 : offset;
      final rows = await archive.rawQuery(
        'SELECT * FROM audit $whereSql ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?',
        [...args, safeLimit, safeOffset],
      );
      return {'rows': rows, 'total': _firstIntValue(countRows) ?? 0};
    } finally {
      await archive.close();
    }
  }

  Future<void> _audit(DatabaseExecutor t, String action, String entity,
      String entityId, String details) async {
    final ctx = await operationalContext(t);
    await t.insert('audit', {
      'created_at': DateTime.now().toIso8601String(),
      'user': ctx['user_id'],
      'action': action,
      'entity': entity,
      'entity_id': entityId,
      'details': details,
      'branch_id': ctx['branch_id'],
      'terminal_id': ctx['terminal_id'],
      'user_id': ctx['user_id'],
    });
  }

  Future<String> saveQuotation(
      {String? id,
      required String customerId,
      required List<Map<String, Object?>> items,
      required DateTime validUntil,
      double discount = 0,
      double deliveryCharge = 0,
      double otherCharge = 0,
      String notes = '',
      Map<String, String> customFields = const {}}) async {
    if (items.isEmpty) throw Exception('Quotation needs at least one item');
    final qid = id ?? _id('QUO');
    final now = DateTime.now();
    final existing = id == null
        ? <Map<String, Object?>>[]
        : await db.query('quotations',
            columns: ['no'], where: 'id=?', whereArgs: [id], limit: 1);
    final no = id == null
        ? 'QT-${now.millisecondsSinceEpoch}'
        : (existing.isEmpty
            ? 'QT-${now.millisecondsSinceEpoch}'
            : existing.first['no'].toString());
    double subtotal = 0, tax = 0;
    for (final x in items) {
      final qty = (x['qty'] as num? ?? 0).toDouble();
      final price =
          (x['price'] as num? ?? x['unit_price'] as num? ?? 0).toDouble();
      final ld = (x['line_discount'] as num? ?? 0).toDouble();
      subtotal += qty * price - ld;
      tax += (x['tax_amount'] as num? ?? x['tax'] as num? ?? 0).toDouble();
    }
    final total = (subtotal + tax - discount + deliveryCharge + otherCharge)
        .clamp(0, double.infinity)
        .toDouble();
    await db.transaction((t) async {
      final ctx = await operationalContext(t);
      final row = {
        'id': qid,
        'no': no,
        'created_at': now.toIso8601String(),
        'valid_until': validUntil.toIso8601String(),
        'customer_id': customerId,
        'status': 'Draft',
        'subtotal': subtotal,
        'discount': discount,
        'tax': tax,
        'delivery_charge': deliveryCharge,
        'other_charge': otherCharge,
        'total': total,
        'notes': notes,
        'custom_fields': jsonEncode(customFields),
        'branch_id': ctx['branch_id'],
        'terminal_id': ctx['terminal_id'],
        'user_id': ctx['user_id']
      };
      if (id == null) {
        await t.insert('quotations', row);
      } else {
        row.remove('id');
        row.remove('no');
        row.remove('created_at');
        await t.update('quotations', row, where: 'id=?', whereArgs: [qid]);
        await t.delete('quotation_items',
            where: 'quotation_id=?', whereArgs: [qid]);
      }
      for (final x in items) {
        final qty = (x['qty'] as num? ?? 0).toDouble(),
            price =
                (x['price'] as num? ?? x['unit_price'] as num? ?? 0).toDouble(),
            ld = (x['line_discount'] as num? ?? 0).toDouble(),
            lt = qty * price -
                ld +
                (x['tax_amount'] as num? ?? x['tax'] as num? ?? 0).toDouble();
        await t.insert('quotation_items', {
          'quotation_id': qid,
          'product_id': x['id'] ?? x['product_id'],
          'name': x['name'],
          'sku': x['sku'],
          'qty': qty,
          'unit_price': price,
          'line_discount': ld,
          'tax': x['tax_amount'] ?? x['tax'] ?? 0,
          'line_total': lt
        });
      }
      await _audit(t, id == null ? 'Create' : 'Edit', 'Quotation', qid,
          '$no • ${items.length} items • total $total');
    });
    await db.rawUpdate('UPDATE analytics_snapshots SET dirty=1 WHERE dirty=0');
    return qid;
  }

  Future<List<Map<String, Object?>>> quotations({String search = ''}) async {
    final ctx = await operationalContext(db);
    final q = '%${search.trim()}%';
    return db.rawQuery(
        "SELECT q.*,c.name customer_name,c.phone customer_phone,c.whatsapp customer_whatsapp FROM quotations q LEFT JOIN customers c ON c.id=q.customer_id WHERE q.branch_id=? AND (?='' OR q.no LIKE ? OR c.name LIKE ? OR c.phone LIKE ? OR c.whatsapp LIKE ?) ORDER BY q.created_at DESC LIMIT 1000",
        [ctx['branch_id'], search.trim(), q, q, q, q]);
  }

  Future<Map<String, Object?>> quotationDetail(String id) async {
    final h = await db.rawQuery(
        'SELECT q.*,c.name customer_name,c.phone customer_phone,c.whatsapp customer_whatsapp FROM quotations q LEFT JOIN customers c ON c.id=q.customer_id WHERE q.id=?',
        [id]);
    if (h.isEmpty) throw Exception('Quotation not found');
    final items = await db.query('quotation_items',
        where: 'quotation_id=?', whereArgs: [id], orderBy: 'id');
    return {'header': h.first, 'items': items};
  }

  Future<void> setQuotationStatus(String id, String status) async {
    await db.update('quotations', {'status': status},
        where: 'id=?', whereArgs: [id]);
    await db.rawUpdate('UPDATE analytics_snapshots SET dirty=1 WHERE dirty=0');
  }

  Future<String> convertQuotationToHeldSale(String id) async {
    final d = await quotationDetail(id);
    final h = Map<String, Object?>.from(d['header'] as Map);
    if (h['status'] == 'Converted')
      throw Exception('Quotation is already converted');
    final items = (d['items'] as List)
        .cast<Map<String, Object?>>()
        .map((x) => {
              'id': x['product_id'],
              'qty': x['qty'],
              'price': x['unit_price'],
              'line_discount': x['line_discount']
            })
        .toList();
    final held = await holdSale(
        items: items,
        customerId: h['customer_id']?.toString(),
        billDiscount: (h['discount'] as num? ?? 0).toDouble(),
        deliveryCharge: (h['delivery_charge'] as num? ?? 0).toDouble(),
        otherCharge: (h['other_charge'] as num? ?? 0).toDouble(),
        notes: 'Converted from quotation ${h['no']}. ${h['notes'] ?? ''}');
    await db.update(
        'quotations', {'status': 'Converted', 'converted_held_sale_id': held},
        where: 'id=?', whereArgs: [id]);
    await db.rawUpdate('UPDATE analytics_snapshots SET dirty=1 WHERE dirty=0');
    return held;
  }

  Future<void> logCommunication(
      {required String partyType,
      required String partyId,
      required String channel,
      required String documentType,
      required String documentId,
      required String action}) async {
    final ctx = await operationalContext(db);
    await db.insert('communication_log', {
      'id': _id('COM'),
      'created_at': DateTime.now().toIso8601String(),
      'party_type': partyType,
      'party_id': partyId,
      'channel': channel,
      'document_type': documentType,
      'document_id': documentId,
      'action': action,
      'user_id': ctx['user_id']
    });
  }

  Future<List<Map<String, Object?>>> communicationHistory(
          String partyType, String partyId) async =>
      db.query('communication_log',
          where: 'party_type=? AND party_id=?',
          whereArgs: [partyType, partyId],
          orderBy: 'created_at DESC',
          limit: 200);
}
