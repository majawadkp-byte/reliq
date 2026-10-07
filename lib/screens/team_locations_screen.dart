import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../services/auth_service.dart';
import '../services/permission_catalog.dart';
import '../ui/v3_style.dart';

class TeamLocationsScreen extends StatefulWidget {
  const TeamLocationsScreen({super.key});

  @override
  State<TeamLocationsScreen> createState() => _TeamLocationsScreenState();
}

class _TeamLocationsScreenState extends State<TeamLocationsScreen> {
  List<Map<String, Object?>> branches = [];
  List<Map<String, Object?>> users = [];
  List<Map<String, Object?>> terminals = [];
  Map<String, Object?> identity = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final result = await Future.wait([
      AppDatabase.instance.branches(),
      AppDatabase.instance.users(),
      AppDatabase.instance.terminals(),
      AppDatabase.instance.currentIdentity(),
    ]);
    if (!mounted) return;
    setState(() {
      branches = result[0] as List<Map<String, Object?>>;
      users = result[1] as List<Map<String, Object?>>;
      terminals = result[2] as List<Map<String, Object?>>;
      identity = result[3] as Map<String, Object?>;
      loading = false;
    });
  }

  Future<void> addBranch([Map<String,Object?>? branch]) async {
    String name = '${branch?['name'] ?? ''}';
    String code = '${branch?['code'] ?? ''}';
    String address = '${branch?['address'] ?? ''}';
    String phone = '${branch?['phone'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(branch == null ? 'Add Branch' : 'Edit Branch'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(initialValue: name, autofocus: true, decoration: const InputDecoration(labelText: 'Branch name *'), onChanged: (v) => name = v),
            const SizedBox(height: 10),
            TextFormField(initialValue: code, decoration: const InputDecoration(labelText: 'Branch code *'), onChanged: (v) => code = v),
            const SizedBox(height: 10),
            TextFormField(initialValue: address, decoration: const InputDecoration(labelText: 'Address'), onChanged: (v) => address = v),
            const SizedBox(height: 10),
            TextFormField(initialValue: phone, decoration: const InputDecoration(labelText: 'Phone'), onChanged: (v) => phone = v),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save Branch')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.saveBranch(id: branch?['id'] as String?, name: name, code: code, address: address, phone: phone, active: branch == null || branch['active'] == 1);
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _editUser([Map<String, Object?>? user]) async {
    final isNew = user == null;
    final isBuiltInOwner = user != null && ((user['id'] ?? '').toString() == 'USR-OWNER' || (user['username'] ?? '').toString().toLowerCase() == 'owner');
    var username = (user?['username'] ?? '').toString();
    var display = (user?['display_name'] ?? '').toString();
    var email = (user?['email'] ?? '').toString();
    var role = isBuiltInOwner ? 'Owner' : PermissionCatalog.normalizedRole((user?['role'] ?? 'Cashier').toString());
    final currentRole = PermissionCatalog.normalizedRole(((identity['user'] as Map<String, Object?>?)?['role'] ?? 'Admin').toString());
    if (isBuiltInOwner && currentRole != 'Owner') {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Only the Owner account can change Owner credentials.')));
      return;
    }
    final availableRoles = currentRole == 'Owner'
        ? PermissionCatalog.roles
        : const ['Accountant', 'Cashier', 'Storekeeper', 'Viewer'];
    final roleChoices = isBuiltInOwner ? const ['Owner'] : availableRoles;
    if (!isBuiltInOwner && !availableRoles.contains(role)) role = availableRoles.first;
    var active = isBuiltInOwner ? true : ((user?['active'] as num?) ?? 1).toInt() == 1;
    var password = '';
    var confirm = '';
    const permissionLabels = PermissionCatalog.labels;
    const roleDefaults = PermissionCatalog.defaults;
    final rawPermissions = (user?['permissions'] ?? '').toString().split(',').map((e)=>e.trim()).where((e)=>e.isNotEmpty).toSet();
    final selectedPermissions = <String>{...rawPermissions};
    if (!isBuiltInOwner && selectedPermissions.isEmpty) selectedPermissions.addAll(roleDefaults[role] ?? const <String>{});
    final selectedBranches = <String>{};
    if (user != null) selectedBranches.addAll(await AppDatabase.instance.userBranchIds(user['id'].toString()));
    if (isNew && branches.isNotEmpty) selectedBranches.add(branches.first['id'].toString());
    if (!mounted) return;

    String? validation;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .48),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: Row(children: [Icon(isNew ? Icons.person_add_alt_1 : Icons.manage_accounts_outlined), const SizedBox(width: 10), Text(isNew ? 'Add User' : 'Edit User')]),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: TextFormField(initialValue: display, autofocus: true, decoration: const InputDecoration(labelText: 'Display name *'), onChanged: (v) => display = v)),
                  const SizedBox(width: 10),
                  Expanded(child: TextFormField(initialValue: username, enabled: !isBuiltInOwner, decoration: const InputDecoration(labelText: 'Username *'), onChanged: (v) => username = v)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextFormField(initialValue: email, decoration: const InputDecoration(labelText: 'Email'), onChanged: (v) => email = v)),
                  const SizedBox(width: 10),
                  Expanded(child: DropdownButtonFormField<String>(
                    value: role,
                    disabledHint: Text(role),
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: roleChoices.map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
                    onChanged: isBuiltInOwner ? null : (v) => setDialog(() { role = v ?? role; selectedPermissions..clear()..addAll(roleDefaults[role] ?? const <String>{}); }),
                  )),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextFormField(obscureText: true, decoration: InputDecoration(labelText: isNew ? 'Password / PIN *' : 'New password / PIN (optional)'), onChanged: (v) => password = v)),
                  const SizedBox(width: 10),
                  Expanded(child: TextFormField(obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password / PIN'), onChanged: (v) => confirm = v)),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: active,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active user'),
                  subtitle: const Text('Inactive users cannot sign in.'),
                  onChanged: isBuiltInOwner ? null : (v) => setDialog(() => active = v),
                ),
                const Divider(height: 24),
                const Text('Allowed branches', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final branch in branches)
                    FilterChip(
                      label: Text('${branch['name']} (${branch['code']})'),
                      selected: selectedBranches.contains(branch['id'].toString()),
                      onSelected: (v) => setDialog(() {
                        final id = branch['id'].toString();
                        if (v) selectedBranches.add(id); else selectedBranches.remove(id);
                      }),
                    ),
                ]),
                if (!isBuiltInOwner && currentRole == 'Owner') ...[
                  const Divider(height: 24),
                  const Text('Fine-grained permissions', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 5),
                  const Text('Override the role preset for this user. Sensitive permissions such as voiding, migration, product deletion, profit visibility and backup/restore are controlled independently.', style: TextStyle(fontSize: 11, color: V3Style.muted)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 7, runSpacing: 6, children: [
                    for (final entry in permissionLabels.entries)
                      FilterChip(
                        label: Text(entry.value),
                        selected: selectedPermissions.contains(entry.key),
                        onSelected: (v) => setDialog(() { if(v) selectedPermissions.add(entry.key); else selectedPermissions.remove(entry.key); }),
                      ),
                  ]),
                ],
                if (validation != null) ...[
                  const SizedBox(height: 12),
                  Text(validation!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w700)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: Text(isNew ? 'Create User' : 'Save Changes'),
              onPressed: () {
                String? error;
                if (display.trim().isEmpty || username.trim().isEmpty) error = 'Display name and username are required.';
                if (isNew && password.length < 4) error = 'New users need a password/PIN with at least 4 characters.';
                if (password.isNotEmpty && password != confirm) error = 'Passwords do not match.';
                if (selectedBranches.isEmpty) error = 'Select at least one branch.';
                if (error != null) {
                  setDialog(() => validation = error);
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;
    try {
      final id = await AppDatabase.instance.saveUser(
        id: user?['id']?.toString(),
        username: username,
        displayName: display,
        role: role,
        email: email,
        active: active,
        branchIds: selectedBranches.toList(),
        permissions: isBuiltInOwner ? const [] : selectedPermissions.toList(),
      );
      if (password.isNotEmpty) await AuthService.instance.setPassword(id, password);
      await load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isNew ? 'User created.' : 'User updated.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _toggleUser(Map<String, Object?> user) async {
    final active = ((user['active'] as num?) ?? 0).toInt() == 1;
    try {
      await AuthService.instance.setActive(user['id'].toString(), !active);
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _deleteUser(Map<String, Object?> user) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete User?'),
        content: Text('Delete ${user['display_name']} (@${user['username']})? Historical transactions will keep their user ID in the audit trail.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await AuthService.instance.deleteUser(user['id'].toString());
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> switchBranch(String branchId) async {
    await AppDatabase.instance.switchBranch(branchId);
    await load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Active branch changed for this device.')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final activeBranch = identity['branch'] as Map<String, Object?>?;
    final activeUser = identity['user'] as Map<String, Object?>?;
    final activeTerminal = identity['terminal'] as Map<String, Object?>?;

    return ListView(
      padding: V3Style.pagePadding,
      children: [
        const Text('Users & Roles', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        Text('Create login accounts, assign roles/branches, reset passwords and control user status.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Card(child: Padding(
          padding: const EdgeInsets.all(18),
          child: Wrap(spacing: 28, runSpacing: 12, children: [
            _identity('Active branch', '${activeBranch?['name'] ?? '—'}'),
            _identity('Signed-in identity', '${activeUser?['display_name'] ?? '—'} • ${activeUser?['role'] ?? ''}'),
            _identity('Terminal', '${activeTerminal?['name'] ?? '—'}'),
            _identity('Users', '${users.where((u) => ((u['active'] as num?) ?? 0).toInt() == 1).length} active / ${users.length} total'),
          ]),
        )),
        const SizedBox(height: 20),
        Row(children: [
          Text('Users', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          FilledButton.icon(onPressed: () => _editUser(), icon: const Icon(Icons.person_add_alt_1), label: const Text('Add User')),
        ]),
        const SizedBox(height: 8),
        Card(clipBehavior: Clip.antiAlias, child: Column(children: [
          for (var i = 0; i < users.length; i++)
            Container(
              color: i.isOdd ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF102536) : const Color(0xFFF7FAFC)) : Colors.transparent,
              child: ListTile(
                minTileHeight: 66,
                leading: CircleAvatar(backgroundColor: const Color(0xFFEAF1FF), child: Text('${users[i]['display_name'] ?? '?'}'.substring(0, 1).toUpperCase(), style: const TextStyle(color: V3Style.blueDark, fontWeight: FontWeight.w800))),
                title: Row(children: [
                  Flexible(child: Text('${users[i]['display_name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  const SizedBox(width: 8),
                  _status(((users[i]['active'] as num?) ?? 0).toInt() == 1 ? 'Active' : 'Inactive', ((users[i]['active'] as num?) ?? 0).toInt() == 1),
                ]),
                subtitle: Text('@${users[i]['username']} • ${users[i]['role']} • ${users[i]['email'] ?? ''}'),
                trailing: Wrap(spacing: 3, children: [
                  IconButton(tooltip: 'Edit user / change password', onPressed: () => _editUser(users[i]), icon: const Icon(Icons.edit_outlined)),
                  IconButton(tooltip: ((users[i]['active'] as num?) ?? 0).toInt() == 1 ? 'Disable user' : 'Activate user', onPressed: () => _toggleUser(users[i]), icon: Icon(((users[i]['active'] as num?) ?? 0).toInt() == 1 ? Icons.person_off_outlined : Icons.person_add_alt_outlined)),
                  IconButton(tooltip: 'Delete user', onPressed: (users[i]['username'] ?? '').toString().toLowerCase() == 'owner' ? null : () => _deleteUser(users[i]), icon: const Icon(Icons.delete_outline)),
                ]),
              ),
            ),
        ])),
        const SizedBox(height: 22),
        Row(children: [
          Text('Branches', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          FilledButton.tonalIcon(onPressed: () => addBranch(), icon: const Icon(Icons.add_business), label: const Text('Add Branch')),
        ]),
        const SizedBox(height: 8),
        Card(child: Column(children: [
          for (final branch in branches)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.store_outlined)),
              title: Text('${branch['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${branch['code']} • ${branch['address'] ?? ''}'),
              trailing: Row(mainAxisSize:MainAxisSize.min,children:[
                if(branch['id']==activeBranch?['id']) const Chip(label:Text('Active on this device')) else if(branch['active']==1) OutlinedButton(onPressed:()=>switchBranch(branch['id'] as String),child:const Text('Use Branch')),
                IconButton(tooltip:'Edit branch',onPressed:()=>addBranch(branch),icon:const Icon(Icons.edit_outlined)),
                TextButton(onPressed:()async{try{await AppDatabase.instance.saveBranch(id:'${branch['id']}',name:'${branch['name']}',code:'${branch['code']}',address:'${branch['address']??''}',phone:'${branch['phone']??''}',active:branch['active']!=1);await load();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}},child:Text(branch['active']==1?'Disable':'Enable')),
                IconButton(tooltip:'Delete or archive branch',icon:const Icon(Icons.delete_outline),onPressed:()async{final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:Text('Remove ${branch['name']}?'),content:const Text('Branches with history will be archived. Only unused branches can be deleted.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Remove'))]));if(ok==true){try{final result=await AppDatabase.instance.removeBranch('${branch['id']}');await load();if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(result)));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}}),
              ]),
            ),
        ])),
        const SizedBox(height: 22),
        Text('Registered terminals', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Card(child: Column(children: [
          for (final terminal in terminals)
            ListTile(
              leading: const Icon(Icons.computer_outlined),
              title: Text('${terminal['name']}'),
              subtitle: Text('${terminal['branch_name'] ?? 'Unassigned'} • ${terminal['device_key']}'),
              trailing: terminal['id'] == activeTerminal?['id'] ? const Chip(label: Text('This device')) : null,
            ),
        ])),
      ],
    );
  }

  Widget _status(String label, bool active) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: (active ? const Color(0xFF16794C) : const Color(0xFFB42318)).withValues(alpha: .10), borderRadius: BorderRadius.circular(999)),
    child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: active ? const Color(0xFF16794C) : const Color(0xFFB42318))),
  );

  Widget _identity(String label, String value) => SizedBox(
    width: 230,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: V3Style.muted)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ]),
  );
}
