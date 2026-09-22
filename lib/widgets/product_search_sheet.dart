import 'package:flutter/material.dart';

import '../models/product_info.dart';
import '../services/product_lookup_service.dart';

/// 품번/품명으로 상품을 직접 검색해서 고르는 바텀시트.
///
/// 케어라벨에 바코드 없이 품번·컬러·사이즈가 각각 따로 인쇄되어 있어서
/// 자동 인식이 안 될 때, 또는 OCR이 잘못 읽었을 때 사용하는 대체 경로입니다.
///
/// 선택이 완료되면 [Navigator.pop]에 확정된 [ProductInfo]를 담아 반환합니다.
class ProductSearchSheet extends StatefulWidget {
  final ProductLookupService lookupService;
  final String initialQuery;

  /// 품번이 이미 확정된 경우, 검색 목록을 건너뛰고 바로 해당 품번의
  /// 색상/사이즈 옵션 선택 화면으로 시작합니다. (예: OCR로 품번은 정확히
  /// 인식했지만 색상/사이즈까지는 특정하지 못했을 때)
  final String? directItemNo;

  const ProductSearchSheet({
    super.key,
    required this.lookupService,
    this.initialQuery = '',
    this.directItemNo,
  });

  @override
  State<ProductSearchSheet> createState() => _ProductSearchSheetState();
}

class _ProductSearchSheetState extends State<ProductSearchSheet> {
  late final TextEditingController _controller;
  List<ProductInfo> _results = [];

  // null이면 검색 목록 화면, 값이 있으면 해당 품번의 색상/사이즈(변형) 선택 화면
  String? _selectedItemNo;
  List<ProductInfo> _variants = [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);

    if (widget.directItemNo != null) {
      final variants = widget.lookupService.variantsForItemNo(widget.directItemNo!);
      _selectedItemNo = widget.directItemNo;
      _variants = variants;
    } else {
      _runSearch(widget.initialQuery);
    }
  }

  void _runSearch(String query) {
    setState(() {
      _results = widget.lookupService.searchItems(query);
    });
  }

  void _pickItem(ProductInfo item) {
    final variants = widget.lookupService.variantsForItemNo(item.itemNo);
    if (variants.length <= 1) {
      Navigator.pop(context, variants.isNotEmpty ? variants.first : item);
      return;
    }
    setState(() {
      _selectedItemNo = item.itemNo;
      _variants = variants;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: _selectedItemNo == null
                ? _buildSearchView(scrollController)
                : _buildVariantView(scrollController),
          ),
        );
      },
    );
  }

  Widget _buildSearchView(ScrollController scrollController) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '상품 직접 검색',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          '품번 또는 품명 일부를 입력하세요',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '예: EW2A2BB001 또는 FACADE',
            border: OutlineInputBorder(),
          ),
          onChanged: _runSearch,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _results.isEmpty
              ? const Center(child: Text('검색 결과가 없습니다.'))
              : ListView.separated(
                  controller: scrollController,
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _results[index];
                    final variantCount =
                        widget.lookupService.variantsForItemNo(item.itemNo).length;
                    return ListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.itemNo}${variantCount > 1 ? '  ·  옵션 $variantCount개' : ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickItem(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildVariantView(ScrollController scrollController) {
    final name = _variants.isNotEmpty ? _variants.first.name : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                if (_results.isEmpty) {
                  _runSearch(_selectedItemNo ?? '');
                }
                setState(() => _selectedItemNo = null);
              },
            ),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '색상/사이즈를 선택하세요',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            controller: scrollController,
            itemCount: _variants.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final v = _variants[index];
              return ListTile(
                title: Text(v.variantLabel.isEmpty ? '(옵션 없음)' : v.variantLabel),
                subtitle: Text(v.barcode),
                onTap: () => Navigator.pop(context, v),
              );
            },
          ),
        ),
      ],
    );
  }
}
