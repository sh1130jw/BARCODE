import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, rootBundle;
import 'package:intl/intl.dart';

import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../models/scan_record.dart' show boxLabel;
import '../services/product_lookup_service.dart';

/// 품번 하나(색상·사이즈 변형을 묶은 것)
class CatalogItem {
  final String itemNo;
  final String name;
  final String category;
  final String gender;
  final int? price;
  final int? tagPrice;
  final List<ProductInfo> variants;
  final List<String> colors;
  final List<String> sizes;

  /// 검색용 글자(품번·품명·바코드, 하이픈 있는 것/없는 것 모두, 대문자)
  final String searchKey;

  CatalogItem._({
    required this.itemNo,
    required this.name,
    required this.category,
    required this.gender,
    required this.price,
    required this.tagPrice,
    required this.variants,
    required this.colors,
    required this.sizes,
    required this.searchKey,
  });

  factory CatalogItem.fromVariants(List<ProductInfo> variants) {
    final first = variants.first;
    final colors = <String>[];
    final sizes = <String>[];
    final key = StringBuffer()
      ..write(first.itemNo.toUpperCase())
      ..write(' ')
      ..write(first.itemNo.toUpperCase().replaceAll('-', ''))
      ..write(' ')
      ..write(first.name.toUpperCase());
    for (final v in variants) {
      if (v.hasColor && !colors.contains(v.color)) colors.add(v.color);
      final size = v.sizeLabel.isNotEmpty ? v.sizeLabel : v.size;
      if (size.isNotEmpty && !sizes.contains(size)) sizes.add(size);
      final barcode = v.barcode.toUpperCase();
      key
        ..write(' ')
        ..write(barcode)
        ..write(' ')
        ..write(barcode.replaceAll('-', ''));
    }
    return CatalogItem._(
      itemNo: first.itemNo,
      name: first.name,
      category: first.category,
      gender: first.gender,
      price: first.price,
      tagPrice: first.tagPrice,
      variants: variants,
      colors: colors,
      sizes: sizes,
      searchKey: key.toString(),
    );
  }

  /// "의류(CLOTHES)" → "의류"
  String get categoryShort => shortLabel(category);
}

String shortLabel(String s) {
  final i = s.indexOf('(');
  return (i > 0 ? s.substring(0, i) : s).trim();
}

/// 상품 데이터(JSON)를 별도 작업에서 읽습니다(화면이 멈추지 않도록).
List<Map<String, dynamic>> _decodeProducts(String raw) => (jsonDecode(raw) as List)
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();

enum _CatalogSort { itemNo, itemNoDesc, priceHigh, priceLow, name }

/// 우리 상품 전체를 둘러보는 화면.
/// 검색(품번·품명·바코드), 종류별 보기, 정렬이 되고, 상품을 누르면
/// 색상·사이즈별 바코드를 보고 지금 박스에 바로 담을 수도 있습니다.
class CatalogScreen extends StatefulWidget {
  final ProductLookupService productLookup;

  /// 지금 스캔 목록에 들어 있는 수량(바코드 대문자 → 수량)
  final Map<String, int> scannedByBarcode;

  /// 지금 담는 박스
  final ValueListenable<String> currentBox;

  /// 상품을 지금 박스에 담기 / 되돌리기
  final AddResult Function(ProductInfo product) onAdd;
  final void Function(AddResult result) onUndo;

  const CatalogScreen({
    super.key,
    required this.productLookup,
    required this.scannedByBarcode,
    required this.currentBox,
    required this.onAdd,
    required this.onUndo,
  });

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  static const _assetPath = 'assets/product_barcodes.json';

  final TextEditingController _searchController = TextEditingController();
  final NumberFormat _won = NumberFormat('#,###');

  List<CatalogItem>? _items;
  List<String> _categories = const [];
  String? _error;

  String _query = '';
  String? _category; // null = 전체
  bool _onlyScanned = false;
  _CatalogSort _sort = _CatalogSort.itemNo;

  /// 스캔 목록 수량(이 화면에서 담으면 같이 올라갑니다)
  late final Map<String, int> _scanned = Map.of(widget.scannedByBarcode);

  /// 이 화면에서 담은 기록(바코드별) — "빼기" 버튼으로 되돌릴 때 사용
  final Map<String, List<AddResult>> _addedHere = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final data = await compute(_decodeProducts, raw);
      final groups = <String, List<ProductInfo>>{};
      for (final m in data) {
        final p0 = ProductInfo.fromJson(m);
        if (p0.barcode.isEmpty || p0.itemNo.isEmpty) continue;
        // 스캔 쪽과 같은 상품 정보를 쓰도록 맞춥니다.
        final same = widget.productLookup.findExactBarcode(p0.barcode);
        final p = (same != null && same.barcode == p0.barcode) ? same : p0;
        groups.putIfAbsent(p.itemNo.toUpperCase(), () => []).add(p);
      }
      final items = groups.values.map(CatalogItem.fromVariants).toList();
      final categories = <String>[];
      for (final it in items) {
        if (it.category.isNotEmpty && !categories.contains(it.category)) {
          categories.add(it.category);
        }
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _categories = categories;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  int _scannedCount(CatalogItem item) {
    var total = 0;
    for (final v in item.variants) {
      total += _scanned[v.barcode.toUpperCase()] ?? 0;
    }
    return total;
  }

  List<CatalogItem> _filtered() {
    final items = _items ?? const <CatalogItem>[];
    final tokens = _query
        .toUpperCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final result = items.where((it) {
      if (_category != null && it.category != _category) return false;
      if (_onlyScanned && _scannedCount(it) == 0) return false;
      for (final t in tokens) {
        if (!it.searchKey.contains(t) &&
            !it.searchKey.contains(t.replaceAll('-', ''))) {
          return false;
        }
      }
      return true;
    }).toList();

    int byPrice(CatalogItem a, CatalogItem b, bool high) {
      final pa = a.price;
      final pb = b.price;
      if (pa == null && pb == null) return a.itemNo.compareTo(b.itemNo);
      if (pa == null) return 1;
      if (pb == null) return -1;
      final c = high ? pb.compareTo(pa) : pa.compareTo(pb);
      return c != 0 ? c : a.itemNo.compareTo(b.itemNo);
    }

    switch (_sort) {
      case _CatalogSort.itemNo:
        result.sort((a, b) => a.itemNo.compareTo(b.itemNo));
        break;
      case _CatalogSort.itemNoDesc:
        result.sort((a, b) => b.itemNo.compareTo(a.itemNo));
        break;
      case _CatalogSort.priceHigh:
        result.sort((a, b) => byPrice(a, b, true));
        break;
      case _CatalogSort.priceLow:
        result.sort((a, b) => byPrice(a, b, false));
        break;
      case _CatalogSort.name:
        result.sort((a, b) => a.name.compareTo(b.name));
        break;
    }
    return result;
  }

  String _priceText(int? price) => price == null ? '' : '${_won.format(price)}원';

  String _sortLabel(_CatalogSort s) {
    switch (s) {
      case _CatalogSort.itemNo:
        return '품번순';
      case _CatalogSort.itemNoDesc:
        return '품번 역순';
      case _CatalogSort.priceHigh:
        return '가격 높은순';
      case _CatalogSort.priceLow:
        return '가격 낮은순';
      case _CatalogSort.name:
        return '품명순';
    }
  }

  // ---------------- 담기 / 빼기 ----------------

  void _add(ProductInfo product) {
    final key = product.barcode.toUpperCase();
    final result = widget.onAdd(product);
    HapticFeedback.selectionClick();
    setState(() {
      _scanned[key] = (_scanned[key] ?? 0) + 1;
      _addedHere.putIfAbsent(key, () => []).add(result);
    });
  }

  void _removeAdded(ProductInfo product) {
    final key = product.barcode.toUpperCase();
    final list = _addedHere[key];
    if (list == null || list.isEmpty) return;
    final result = list.removeLast();
    widget.onUndo(result);
    setState(() {
      final now = (_scanned[key] ?? 0) - 1;
      _scanned[key] = now < 0 ? 0 : now;
    });
  }

  // ---------------- 상세 ----------------

  Future<void> _openDetail(CatalogItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    item.name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SelectableText(
                    item.itemNo,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (item.category.isNotEmpty) _infoChip(item.categoryShort),
                      if (item.gender.isNotEmpty) _infoChip(shortLabel(item.gender)),
                      if (item.price != null) _infoChip('판매가 ${_priceText(item.price)}'),
                      if (item.tagPrice != null && item.tagPrice != item.price)
                        _infoChip('택가 ${_priceText(item.tagPrice)}'),
                      _infoChip('옵션 ${item.variants.length}개'),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: ValueListenableBuilder<String>(
                    valueListenable: widget.currentBox,
                    builder: (_, box, __) => Text(
                      '+ 를 누르면 ${boxLabel(box)}에 바로 담겨요 (택 없는 상품 수기 추가용)',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: item.variants.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final v = item.variants[i];
                      final key = v.barcode.toUpperCase();
                      final inList = _scanned[key] ?? 0;
                      final added = _addedHere[key]?.length ?? 0;
                      return ListTile(
                        dense: true,
                        title: Text(
                          v.variantLabel.isEmpty ? '단일 옵션' : v.variantLabel,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          inList > 0 ? '${v.barcode} · 스캔목록 $inList개' : v.barcode,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (added > 0) ...[
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                tooltip: '방금 담은 것 빼기',
                                onPressed: () {
                                  _removeAdded(v);
                                  setSheetState(() {});
                                },
                              ),
                              Text(
                                '+$added',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                            IconButton(
                              icon: const Icon(Icons.add_circle),
                              tooltip: '지금 박스에 담기',
                              onPressed: () {
                                _add(v);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoChip(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  // ---------------- 화면 ----------------

  Widget _buildFilters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('전체'),
            selected: _category == null,
            onSelected: (_) => setState(() => _category = null),
          ),
          for (final c in _categories) ...[
            const SizedBox(width: 6),
            ChoiceChip(
              label: Text(shortLabel(c)),
              selected: _category == c,
              onSelected: (_) => setState(() => _category = _category == c ? null : c),
            ),
          ],
          const SizedBox(width: 12),
          FilterChip(
            label: const Text('스캔한 상품만'),
            selected: _onlyScanned,
            onSelected: (v) => setState(() => _onlyScanned = v),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(CatalogItem item) {
    final scanned = _scannedCount(item);
    final scheme = Theme.of(context).colorScheme;
    final options = <String>[];
    if (item.colors.isNotEmpty) options.add('색상 ${item.colors.join(', ')}');
    if (item.sizes.isNotEmpty) options.add('사이즈 ${item.sizes.join(', ')}');
    return ListTile(
      onTap: () => _openDetail(item),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${item.itemNo} · ${item.categoryShort}\n${options.join('  ·  ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _priceText(item.price),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (scanned > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('스캔 $scanned개', style: const TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final filtered = items == null ? const <CatalogItem>[] : _filtered();
    final variantCount = filtered.fold<int>(0, (sum, it) => sum + it.variants.length);

    Widget body;
    if (_error != null) {
      body = Center(child: Text('상품 목록을 불러오지 못했어요: $_error'));
    } else if (items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '품번 · 품명 · 바코드 검색 (띄어쓰기로 여러 단어)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          _buildFilters(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Text(
                  '품번 ${filtered.length}개 · 옵션 $variantCount개',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Spacer(),
                Text(
                  _sortLabel(_sort),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('조건에 맞는 상품이 없어요.'))
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _buildTile(filtered[i]),
                  ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(items == null ? '상품 목록' : '상품 목록 (${items.length})'),
        actions: [
          PopupMenuButton<_CatalogSort>(
            icon: const Icon(Icons.sort),
            tooltip: '정렬',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => _CatalogSort.values
                .map((s) => PopupMenuItem<_CatalogSort>(
                      value: s,
                      child: Text(_sortLabel(s)),
                    ))
                .toList(),
          ),
        ],
      ),
      body: body,
    );
  }
}
