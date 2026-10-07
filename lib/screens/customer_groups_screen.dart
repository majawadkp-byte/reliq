import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../ui/v3_style.dart';

class CustomerGroupsScreen extends StatefulWidget {
  const CustomerGroupsScreen({super.key});
  @override
  State<CustomerGroupsScreen> createState() => _CustomerGroupsScreenState();
}

class _CustomerGroupsScreenState extends State<CustomerGroupsScreen> {
  Future<void> _editGroup([Map<String,Object?>? group]) async {
    String name=(group?['name'] ?? '').toString();
    String discount='${group?['default_discount_pct'] ?? 0}';
    String notes=(group?['notes'] ?? '').toString();
    bool active=((group?['active'] as num?) ?? 1).toInt()==1;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(
      title:Text(group==null?'Add Customer Group':'Edit Customer Group'),
      content:SizedBox(width:520,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextFormField(initialValue:name,onChanged:(v)=>name=v,decoration:const InputDecoration(labelText:'Group name',hintText:'e.g. Technicians / Wholesale / VIP')),
        const SizedBox(height:10),
        TextFormField(initialValue:discount,onChanged:(v)=>discount=v,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Default discount %')),
        const SizedBox(height:10),
        TextFormField(initialValue:notes,onChanged:(v)=>notes=v,minLines:2,maxLines:3,decoration:const InputDecoration(labelText:'Notes')),
        SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Active'),value:active,onChanged:(v)=>setD(()=>active=v)),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Save'))],
    )));
    if(ok==true && name.trim().isNotEmpty){
      await AppDatabase.instance.saveCustomerGroup(id:group?['id'] as String?,name:name,defaultDiscountPct:double.tryParse(discount)??0,notes:notes,active:active);
      if(mounted){setState((){});ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Customer group saved')));}
    }
  }

  Future<void> _rules(Map<String,Object?> group) async {
    await showDialog<void>(context:context,builder:(ctx)=>_GroupRulesDialog(group:group));
    if(mounted)setState((){});
  }

  @override
  Widget build(BuildContext context)=>Padding(
    padding:V3Style.pagePadding,
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[
        const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Customer Groups & Pricing',style:TextStyle(fontSize:24,fontWeight:FontWeight.w800)),SizedBox(height:4),Text('Set customer clusters such as Technicians or Wholesale, then override discounts by category or product.',style:TextStyle(color:V3Style.muted))])),
        FilledButton.icon(onPressed:()=>_editGroup(),icon:const Icon(Icons.group_add_outlined),label:const Text('Add Group')),
      ]),
      const SizedBox(height:16),
      Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:AppDatabase.instance.customerGroups(),builder:(context,snap){
        final rows=snap.data??[];
        if(rows.isEmpty)return const Center(child:Text('No customer groups yet. Add Technicians, Wholesale, VIP or any pricing cluster you need.'));
        return Card(child:ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const Divider(height:1),itemBuilder:(context,i){
          final g=rows[i];
          return ListTile(
            leading:CircleAvatar(child:Text((g['name']??'?').toString().substring(0,1).toUpperCase())),
            title:Text('${g['name']}',style:const TextStyle(fontWeight:FontWeight.w700)),
            subtitle:Text('Default discount ${(g['default_discount_pct'] as num? ?? 0).toStringAsFixed(2)}%${((g['active'] as num?)??1).toInt()==0?' • INACTIVE':''}'),
            trailing:Wrap(spacing:6,children:[OutlinedButton.icon(onPressed:()=>_rules(g),icon:const Icon(Icons.tune,size:17),label:const Text('Rules')),IconButton(onPressed:()=>_editGroup(g),tooltip:'Edit group',icon:const Icon(Icons.edit_outlined))]),
          );
        }));
      })),
    ]),
  );
}

class _GroupRulesDialog extends StatefulWidget {
  final Map<String,Object?> group;
  const _GroupRulesDialog({required this.group});
  @override State<_GroupRulesDialog> createState()=>_GroupRulesDialogState();
}
class _GroupRulesDialogState extends State<_GroupRulesDialog>{
  Future<void> _addRule() async {
    String scope='Category'; String value=''; String discount='0';
    List<Map<String,Object?>> products=[]; List<String> categories=[];
    final all=await AppDatabase.instance.products(activeOnly:true,limit:1000);
    products=all;
    categories={...all.map((x)=>(x['category']??'').toString()).where((x)=>x.isNotEmpty)}.toList()..sort();
    if(!mounted)return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(
      title:const Text('Add Discount Rule'),
      content:SizedBox(width:520,child:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<String>(value:scope,decoration:const InputDecoration(labelText:'Rule applies to'),items:const ['Category','Product'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setD((){scope=v??'Category';value='';})),
        const SizedBox(height:10),
        if(scope=='Category') DropdownButtonFormField<String>(value:categories.contains(value)?value:null,isExpanded:true,decoration:const InputDecoration(labelText:'Category'),items:categories.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setD(()=>value=v??'')),
        if(scope=='Product') DropdownButtonFormField<String>(value:products.any((p)=>p['id']==value)?value:null,isExpanded:true,decoration:const InputDecoration(labelText:'Product'),items:products.map((p)=>DropdownMenuItem(value:p['id'].toString(),child:Text('${p['name']}',overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>setD(()=>value=v??'')),
        const SizedBox(height:10),
        TextFormField(initialValue:'0',keyboardType:const TextInputType.numberWithOptions(decimal:true),onChanged:(v)=>discount=v,decoration:const InputDecoration(labelText:'Discount % (0 can explicitly exclude the group discount)')),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Add Rule'))],
    )));
    if(ok==true && value.isNotEmpty){await AppDatabase.instance.saveCustomerGroupRule(groupId:widget.group['id'].toString(),scopeType:scope,scopeValue:value,discountPct:double.tryParse(discount)??0);if(mounted)setState((){});}
  }
  @override Widget build(BuildContext context)=>AlertDialog(
    title:Text('${widget.group['name']} • Discount Rules'),
    content:SizedBox(width:700,height:430,child:Column(children:[
      Text('Default ${(widget.group['default_discount_pct'] as num? ?? 0).toStringAsFixed(2)}%. Specific product rules override category rules, which override the group default.',style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height:12),
      Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:AppDatabase.instance.customerGroupRules(widget.group['id'].toString()),builder:(context,snap){final rows=snap.data??[];if(rows.isEmpty)return const Center(child:Text('No overrides. The group default applies to all products.'));return ListView.separated(itemCount:rows.length,separatorBuilder:(_,__)=>const Divider(height:1),itemBuilder:(context,i){final r=rows[i];return ListTile(title:Text('${r['scope_type']}: ${r['scope_value']}'),trailing:Text('${(r['discount_pct'] as num? ?? 0).toStringAsFixed(2)}%',style:const TextStyle(fontWeight:FontWeight.w800)));});})),
    ])),
    actions:[OutlinedButton.icon(onPressed:_addRule,icon:const Icon(Icons.add),label:const Text('Add Rule')),FilledButton(onPressed:()=>Navigator.pop(context),child:const Text('Done'))],
  );
}
