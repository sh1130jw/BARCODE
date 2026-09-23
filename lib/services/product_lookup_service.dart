import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/product_info.dart';

enum MatchConfidence {
  /// 인식된 문자열이 바코드와 완전히 일치
  exact,

  /// OCR 오인식을 감안한 근사(편집거리) 일치
  fuzzy,

  /// 품번+색상+사이즈가 라벨에 따로 표기되어 있어 조합으로 찾은 경우
  components,

  /// 매칭 실패
  none,
}

class MatchResult {
  final ProductInfo? product;
  final MatchConfidence confidence;

  /// 어떤 원문 코드(또는 조합)로 매칭됐는지 - 화면에 참고용으로 표시
  final String matchedFrom;

  /// 품번은 확인됐지만 색상/사이즈를 정확히 특정하지 못해
  /// 후보 옵션이 여러 개 남은 경우(선택 UI로 넘길 때 사용)
  final List<ProductInfo> ambiguousVariants;

  const MatchResult({
    this.product,
    required this.confidence,
    this.matchedFrom = '',
    this.ambiguousVariants = const [],
  });

  bool get isMatched => product != null;

  bool get isAmbiguous => product == null && ambiguousVariants.isNotEmpty;
}

/// `assets/product_barcodes.json`(엑셀 "상품바코드조회" 원본을 변환한 데이터)을
/// 로드하고, OCR로 인식된 코드를 상품 정보와 매칭하는 서비스.
///
/// 두 가지 라벨 형태를 모두 지원합니다.
/// 1) 라벨에 "바코드" 한 줄(품번+색상+사이즈 조합)이 그대로 인쇄된 경우
/// 2) 라벨에 품번/컬러/사이즈가 각각 따로 인쇄된 경우
class ProductLookupService {
  static const _assetPath = 'assets/product_barcodes.json';

  final Map<String, ProductInfo> _byBarcode = {}; // normalize(바코드) -> 상품
  final Map<String, List<ProductInfo>> _byItemNo = {}; // 품번(대문자) -> 변형 목록
  final Map<String, List<String>> _itemNoByNormalized = {}; // 하이픈 제거형 -> 실제 품번 목록
  final Set<String> _knownColors = {};
  final Set<String> _knownSizes = {}; // 사이즈 코드 + 사이즈표기 모두 포함

  bool _loaded = false;
  bool get isLoaded => _loaded;
  int get productCount => _byBarcode.length;

  Future<void> load() async {
    if (_loaded) return;
    final raw = await rootBundle.loadString(_assetPath);
    final List<dynamic> data = json.decode(raw) as List<dynamic>;

    for (final item in data) {
      final p = ProductInfo.fromJson(item as Map<String, dynamic>);
      if (p.barcode.isEmpty || p.itemNo.isEmpty) continue;

      _byBarcode[_normalizeBarcode(p.barcode)] = p;

      final itemKey = p.itemNo.toUpperCase();
      _byItemNo.putIfAbsent(itemKey, () => []).add(p);

      final normalizedItem = _normalizeBarcode(p.itemNo);
      _itemNoByNormalized.putIfAbsent(normalizedItem, () => []);
      if (!_itemNoByNormalized[normalizedItem]!.contains(itemKey)) {
        _itemNoByNormalized[normalizedItem]!.add(itemKey);
      }

      if (p.hasColor) _knownColors.add(_normalizeBarcode(p.color));
      if (p.size.isNotEmpty) _knownSizes.add(_normalizeBarcode(p.size));
      if (p.sizeLabel.isNotEmpty) {
        _knownSizes.add(_normalizeBarcode(p.sizeLabel));
      }
    }

    _loaded = true;
  }

  /// 공백/하이픈 제거 + 대문자 변환 + OCR이 흔히 헷갈리는 문자 통일
  /// (바코드/품번/색상/사이즈 비교에 공통으로 사용)
  ///
  /// 케어라벨은 인쇄 폰트가 작고 흐릿한 경우가 많아 OCR이 아래 문자쌍을
  /// 서로 바꿔 읽는 일이 흔합니다.
  ///   O(영문) ↔ 0(숫자), S(영문) ↔ 5(숫자), B(영문) ↔ 8(숫자),
  ///   Z(영문) ↔ 2(숫자), G(영문) ↔ 6(숫자)
  /// 실제 상품 데이터(바코드/품번/색상/사이즈 전체) 기준으로 이 문자쌍들을
  /// 통일해도 서로 다른 상품끼리 겹치는 경우가 전혀 없음을 확인한 뒤에만
  /// 추가했습니다(예: 영문 I/L/숫자 1처럼 실제로 서로 다른 상품을 구분하는
  /// 데 쓰이는 문자쌍은 겹치는 사례가 있어 일부러 포함하지 않았습니다).
  ///
