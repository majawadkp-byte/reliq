import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../ui/pagination_bar.dart';
import '../ui/v3_style.dart';

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});
  @override State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final searchCtl = TextEditingController();
  String query = '';
  String category = 'All';
  String method = 'All';
  String sort = 'Newest';
  DateTime? from;
  DateTime? to;
  int page = 0;
  int pageSize = 10;
  int refreshKey = 0;

  @override void dispose() { searchCtl.dispose(); super.dispose(); }

  Future<Map<String,Object>> _load() => AppDatabase.instance.expensesPage(
    limit: pageSize, offset: page*pageSize, search: query, category: category,
    method: method, sort: sort, from: from, to: to,
  );

  Future<String?> _quickCategory() async {
    String value='';
    final result = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Add Expense Category'),
      content: TextFormField(autofocus: true, decoration: const InputDecoration(labelText: 'Category name'), onChanged: (v)=>value=v, onFieldSubmitted: (v)=>Navigator.pop(c,v.trim())),
      actions: [TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,value.trim()),child:const Text('Add'))],
    ));
    if(result==null || result.trim().isEmpty) return null;
    await AppDatabase.instance.addExpenseCategory(result);
    return result.trim();
  }

  Future<void> addExpense() async {
    final categories = await AppDatabase.instance.expenseCategories();
    final taxProfiles = await AppDatabase.instance.taxProfiles();
    if(!mounted) return;
    String selectedCategory = categories.isEmpty ? 'General' : categories.first['name'].toString();
    String description=''; String amountText=''; String taxText='0'; String reference=''; String notes='';
    String paymentMethod='Cash'; String taxCode='NONE'; DateTime date=DateTime.now();

    double taxForProfile() {
      final amount=double.tryParse(amountText)??0;
      final profile=taxProfiles.cast<Map<String,Object?>>().firstWhere((x)=>x['code']==taxCode,orElse:()=>{'rate':0,'price_inclusive':0});
      final rate=(profile['rate'] as num? ?? 0).toDouble();
      final inclusive=(profile['price_inclusive'] as num? ?? 0).toInt()==1;
      if(rate<=0) return 0;
      return inclusive ? amount*rate/(100+rate) : amount*rate/100;
    }

    final ok=await showDialog<bool>(context: context, builder:(dialogContext)=>StatefulBuilder(builder:(dialogContext,setDialog)=>AlertDialog(
      title: const Row(children:[CircleAvatar(radius:18,child:Icon(Icons.receipt_long_outlined,size:18)),SizedBox(width:10),Text('Add Expense')]),
      content:SizedBox(width:640,child:SingleChildScrollView(child:Column(children:[
        Row(children:[
          Expanded(child:DropdownButtonFormField<String>(value:selectedCategory,isExpanded:true,decoration:const InputDecoration(labelText:'Category'),items:[for(final c in categories) DropdownMenuItem(value:c['name'].toString(),child:Text(c['name'].toString()))],onChanged:(v)=>setDialog(()=>selectedCategory=v??selectedCategory))),
          const SizedBox(width:7),
          IconButton.filledTonal(tooltip:'Add category',onPressed:() async {final added=await _quickCategory(); if(added!=null){categories.add({'name':added}); if(dialogContext.mounted)setDialog(()=>selectedCategory=added);}},icon:const Icon(Icons.add,size:18)),
        ]),
        const SizedBox(height:10),
        TextFormField(decoration:const InputDecoration(labelText:'Description'),onChanged:(v)=>description=v),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:TextFormField(key:ValueKey('amount-$amountText'),initialValue:amountText,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Expense amount'),onChanged:(v){amountText=v; setDialog(()=>taxText=taxForProfile().toStringAsFixed(3));})),
          const SizedBox(width:10),
          Expanded(child:DropdownButtonFormField<String>(value:taxCode,isExpanded:true,decoration:const InputDecoration(labelText:'Tax profile'),items:[for(final t in taxProfiles) DropdownMenuItem(value:t['code'].toString(),child:Text('${t['name']} • ${(t['rate'] as num? ?? 0).toStringAsFixed(3)}%'))],onChanged:(v)=>setDialog((){taxCode=v??'NONE';taxText=taxForProfile().toStringAsFixed(3);})) ),
          const SizedBox(width:10),
          SizedBox(width:130,child:TextFormField(key:ValueKey('tax-$taxText'),initialValue:taxText,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Tax amount'),onChanged:(v)=>taxText=v)),
        ]),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:DropdownButtonFormField<String>(value:paymentMethod,decoration:const InputDecoration(labelText:'Payment method'),items:['Cash','Card','Bank','Cheque','Other'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setDialog(()=>paymentMethod=v??'Cash'))),
          const SizedBox(width:10),
          Expanded(child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:10),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10),side:BorderSide(color:Theme.of(dialogContext).dividerColor)),title:const Text('Expense date',style:TextStyle(fontSize:11)),subtitle:Text(DateFormat('dd MMM yyyy').format(date)),trailing:const Icon(Icons.calendar_month_outlined),onTap:() async {final v=await showDatePicker(context:dialogContext,firstDate:DateTime(2020),lastDate:DateTime(2100),initialDate:date);if(v!=null)setDialog(()=>date=v);})),
        ]),
        const SizedBox(height:10),
        TextFormField(decoration:const InputDecoration(labelText:'Reference / voucher no.'),onChanged:(v)=>reference=v),
        const SizedBox(height:10),
        TextFormField(minLines:2,maxLines:3,decoration:const InputDecoration(labelText:'Notes'),onChanged:(v)=>notes=v),
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Cancel')),FilledButton.icon(onPressed:()=>Navigator.pop(dialogContext,true),icon:const Icon(Icons.save_outlined,size:17),label:const Text('Save Expense'))],
    )));
    if(ok!=true) return;
    try{
      final enteredAmount=double.tryParse(amountText)??0;
      final taxAmount=double.tryParse(taxText)??0;
      final profile=taxProfiles.cast<Map<String,Object?>>().firstWhere((x)=>x['code']==taxCode,orElse:()=>{'price_inclusive':0});
      final inclusive=(profile['price_inclusive'] as num? ?? 0).toInt()==1;
      final netAmount=inclusive ? (enteredAmount-taxAmount).clamp(0,double.infinity).toDouble() : enteredAmount;
      await AppDatabase.instance.createExpense(date:date,category:selectedCategory,description:description,amount:netAmount,taxAmount:taxAmount,taxCode:taxCode,paymentMethod:paymentMethod,reference:reference,notes:notes);
      if(mounted)setState((){page=0;refreshKey++;});
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }

  Future<void> _pickDate(bool start) async {
    final initial=start?(from??DateTime.now()):(to??DateTime.now());
    final value=await showDatePicker(context:context,initialDate:initial,firstDate:DateTime(2020),lastDate:DateTime.now().add(const Duration(days:366)));
    if(value==null)return; setState((){if(start)from=value;else to=value;page=0;});
  }

  @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.all(22),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Expenses',style:TextStyle(fontSize:24,fontWeight:FontWeight.w800)),const SizedBox(height:4),Text('Categorized expenses with tax, filters, sorting and paged history.',style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant))])),FilledButton.icon(onPressed:addExpense,icon:const Icon(Icons.add),label:const Text('Add Expense'))]),
    const SizedBox(height:14),
    FutureBuilder<List<Map<String,Object?>>>(future:AppDatabase.instance.expenseCategories(),builder:(context,snap){final cats=snap.data??[];return Card(child:Padding(padding:const EdgeInsets.all(12),child:Wrap(spacing:9,runSpacing:9,crossAxisAlignment:WrapCrossAlignment.center,children:[
      SizedBox(width:280,child:TextField(controller:searchCtl,onChanged:(v)=>setState((){query=v.trim();page=0;}),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Description, reference, notes'))),
      SizedBox(width:170,child:DropdownButtonFormField<String>(value:category,isExpanded:true,decoration:const InputDecoration(labelText:'Category'),items:[const DropdownMenuItem(value:'All',child:Text('All categories')),for(final c in cats)DropdownMenuItem(value:c['name'].toString(),child:Text(c['name'].toString(),overflow:TextOverflow.ellipsis))],onChanged:(v)=>setState((){category=v??'All';page=0;}))),
      SizedBox(width:140,child:DropdownButtonFormField<String>(value:method,isExpanded:true,decoration:const InputDecoration(labelText:'Method'),items:['All','Cash','Card','Bank','Cheque','Other'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState((){method=v??'All';page=0;}))),
      SizedBox(width:150,child:DropdownButtonFormField<String>(value:sort,isExpanded:true,decoration:const InputDecoration(labelText:'Sort'),items:['Newest','Oldest','Amount high','Amount low','Category'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setState((){sort=v??'Newest';page=0;}))),
      OutlinedButton.icon(onPressed:()=>_pickDate(true),icon:const Icon(Icons.calendar_today_outlined,size:16),label:Text(from==null?'From':DateFormat('dd MMM').format(from!))),
      OutlinedButton.icon(onPressed:()=>_pickDate(false),icon:const Icon(Icons.event_outlined,size:16),label:Text(to==null?'To':DateFormat('dd MMM').format(to!))),
      if(from!=null||to!=null)TextButton.icon(onPressed:()=>setState((){from=null;to=null;page=0;}),icon:const Icon(Icons.close,size:16),label:const Text('Clear')),
    ])));}),
    const SizedBox(height:12),
    Expanded(child:FutureBuilder<Map<String,Object>>(key:ValueKey(refreshKey),future:_load(),builder:(context,snap){if(!snap.hasData)return const Center(child:CircularProgressIndicator());final rows=(snap.data!['rows'] as List).cast<Map<String,Object?>>();final total=snap.data!['total'] as int;if(rows.isEmpty)return const Card(child:Center(child:Text('No expenses match these filters.')));return Card(clipBehavior:Clip.antiAlias,child:Column(children:[
      Container(height:42,padding:const EdgeInsets.symmetric(horizontal:12),color:V3Style.tableHeader(context),child:const Row(children:[SizedBox(width:120,child:Text('DATE',style:_head)),Expanded(flex:2,child:Text('CATEGORY / DESCRIPTION',style:_head)),SizedBox(width:115,child:Text('METHOD',style:_head)),SizedBox(width:115,child:Text('AMOUNT',textAlign:TextAlign.right,style:_head)),SizedBox(width:95,child:Text('TAX',textAlign:TextAlign.right,style:_head)),SizedBox(width:120,child:Text('TOTAL',textAlign:TextAlign.right,style:_head))])),
      Expanded(child:ListView.builder(itemCount:rows.length,itemBuilder:(context,i){final r=rows[i];final dt=DateTime.tryParse('${r['expense_date']}');final amount=(r['amount'] as num? ?? 0).toDouble();final tax=(r['tax_amount'] as num? ?? 0).toDouble();return V4AlternateRow(index:i,child:Row(children:[SizedBox(width:120,child:Text(dt==null?'—':DateFormat('dd MMM yyyy').format(dt),style:const TextStyle(fontSize:11))),Expanded(flex:2,child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[Text('${r['category']}',style:const TextStyle(fontWeight:FontWeight.w700)),Text('${r['description']??''}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:10,color:V3Style.muted))])),SizedBox(width:115,child:Text('${r['payment_method']??'—'}')),SizedBox(width:115,child:Text(amount.toStringAsFixed(3),textAlign:TextAlign.right)),SizedBox(width:95,child:Text(tax.toStringAsFixed(3),textAlign:TextAlign.right)),SizedBox(width:120,child:Text((amount+tax).toStringAsFixed(3),textAlign:TextAlign.right,style:const TextStyle(fontWeight:FontWeight.w800)))]));})),
      V4PaginationBar(total:total,page:page,pageSize:pageSize,onPageChanged:(v)=>setState(()=>page=v),onPageSizeChanged:(v)=>setState((){pageSize=v;page=0;})),
    ]));})),
  ]));
}

const _head=TextStyle(fontSize:10,fontWeight:FontWeight.w800,color:V3Style.muted);
