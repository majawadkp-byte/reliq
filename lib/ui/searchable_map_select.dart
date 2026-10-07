import 'package:flutter/material.dart';

class SearchableMapSelect extends StatefulWidget {
  final List<Map<String,Object?>> options;
  final String? value;
  final String labelText;
  final String hintText;
  final bool enabled;
  final bool allowClear;
  final FocusNode? focusNode;
  final ValueChanged<String?> onChanged;
  final String Function(Map<String,Object?>) display;
  final String Function(Map<String,Object?>)? subtitle;

  const SearchableMapSelect({
    super.key,
    required this.options,
    required this.value,
    required this.labelText,
    required this.onChanged,
    required this.display,
    this.subtitle,
    this.hintText='Type to search...',
    this.enabled=true,
    this.allowClear=false,
    this.focusNode,
  });

  @override
  State<SearchableMapSelect> createState()=>_SearchableMapSelectState();
}

class _SearchableMapSelectState extends State<SearchableMapSelect> {
  final controller=TextEditingController();
  final menu=MenuController();
  List<Map<String,Object?>> filtered=const [];

  @override
  void initState(){
    super.initState();
    _syncText();
  }

  @override
  void didUpdateWidget(covariant SearchableMapSelect oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.value!=widget.value || oldWidget.options.length!=widget.options.length) _syncText();
  }

  void _syncText(){
    if(widget.value==null || widget.value!.isEmpty){controller.text='';return;}
    final matches=widget.options.where((x)=>'${x['id']}'==widget.value).toList();
    controller.text=matches.isEmpty?'':widget.display(matches.first);
  }

  void _search(String value){
    final q=value.trim().toLowerCase();
    filtered=widget.options.where((x){
      if(q.isEmpty)return true;
      final text='${widget.display(x)} ${widget.subtitle?.call(x) ?? ''}'.toLowerCase();
      return text.contains(q);
    }).take(12).toList();
    setState((){});
    if(filtered.isNotEmpty && !menu.isOpen)menu.open();
    if(filtered.isEmpty && menu.isOpen)menu.close();
  }

  void _choose(Map<String,Object?> row){
    controller.text=widget.display(row);
    if(menu.isOpen)menu.close();
    widget.onChanged('${row['id']}');
  }

  @override
  void dispose(){controller.dispose();super.dispose();}

  @override
  Widget build(BuildContext context)=>MenuAnchor(
    controller:menu,
    crossAxisUnconstrained:false,
    menuChildren:[
      for(final row in filtered) MenuItemButton(
        onPressed:widget.enabled?()=>_choose(row):null,
        child:SizedBox(width:480,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(widget.display(row),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700)),
          if(widget.subtitle!=null) Text(widget.subtitle!(row),maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontSize:10,color:Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
      ),
    ],
    builder:(context,_,__)=>TextField(
      controller:controller,
      focusNode:widget.focusNode,
      enabled:widget.enabled,
      onTap:(){
        if(widget.value!=null && widget.value!.isNotEmpty && controller.text.isNotEmpty){
          controller.selection=TextSelection(baseOffset:0,extentOffset:controller.text.length);
        }
        _search(controller.text);
      },
      onChanged:_search,
      onSubmitted:(_){if(filtered.isNotEmpty)_choose(filtered.first);},
      decoration:InputDecoration(
        labelText:widget.labelText,
        hintText:widget.hintText,
        prefixIcon:const Icon(Icons.search),
        suffixIcon:widget.allowClear && widget.value!=null && widget.value!.isNotEmpty?IconButton(
          icon:const Icon(Icons.close),
          onPressed:(){controller.clear();widget.onChanged(null);if(menu.isOpen)menu.close();setState(()=>filtered=const[]);},
        ):null,
      ),
    ),
  );
}
