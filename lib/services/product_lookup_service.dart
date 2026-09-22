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

      if (p.hasColor) _knownColors.add(p.color.toUpperCase());
      if (p.size.isNotEmpty) _knownSizes.add(p.size.toUpperCase());
      if (p.sizeLabel.isNotEmpty) _knownSizes.add(p.sizeLabel.toUpperCase());
    }

    _loaded = true;
  }

  /// 공백/하이픈 제거 + 대문자 변환 (바코드 비교용)
  String _normalizeBarcode(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

  ProductInfo? findExactBarcode(String code) =>
      _byBarcode[_normalizeBarcode(code)];

  /// OCR 오인식을 감안해 편집거리 이내의 가장 가까운 바코드를 찾습니다.
  /// 너무 짧은 문자열은 오탐 위험이 커서 제외합니다.
  ProductInfo? findClosestBarcode(String code, {int maxDistance = 2}) {
    final target = _normalizeBarcode(code);
    if (target.length < 8) return null;

    ProductInfo? best;
    int bestDist = maxDistance + 1;

    for (final entry in _byBarcode.entries) {
      if ((entry.key.length - target.length).abs() > maxDistance) continue;
      final dist = _levenshtein(target, entry.key, bestDist);
      if (dist < bestDist) {
        bestDist = dist;
        best = entry.value;
        if (bestDist == 0) break;
      }
    }
    return bestDist <= maxDistance ? best : null;
  }

  List<ProductInfo> variantsForItemNo(String itemNo) {
    return _byItemNo[itemNo.toUpperCase()] ?? const [];
  }

  /// 품번(+색상/사이즈)으로 상품을 찾습니다. 라벨에 코드가 각각 따로
  /// 인쇄되어 있을 때 사용합니다.
  ProductInfo? findByComponents({
    required String itemNo,
    String? color,
    String? size,
  }) {
    final variants = variantsForItemNo(itemNo);
    if (variants.isEmpty) return null;
    if (variants.length == 1) return variants.first;

    // 색상/사이즈 정보가 전혀 없으면 여러 옵션 중 하나를 임의로 고르지 않고
    // "특정 불가"로 처리합니다(호출부에서 선택 UI로 안내).
    if ((color == null || color.isEmpty) && (size == null || size.isEmpty)) {
      return null;
    }

    for (final v in variants) {
      final colorOk = color == null ||
          !v.hasColor ||
          v.color.toUpperCase() == color.toUpperCase();
      final sizeOk = size == null ||
          v.size.toUpperCase() == size.toUpperCase() ||
          v.sizeLabel.toUpperCase() == size.toUpperCase();
      if (colorOk && sizeOk) return v;
    }
    return null;
  }

  bool isKnownColor(String token) => _knownColors.contains(token.toUpperCase());

  bool isKnownSize(String token) => _knownSizes.contains(token.toUpperCase());

  /// 정확한 품번이거나(하이픈 유무와 무관하게) 인식되면 실제 품번 문자열을 반환합니다.
  String? matchItemNo(String token) {
    final upper = token.toUpperCase();
    if (_byItemNo.containsKey(upper)) return upper;

    final normalized = _normalizeBarcode(token);
    final candidates = _itemNoByNormalized[normalized];
    if (candidates != null && candidates.length == 1) return candidates.first;
    return null;
  }

  /// 품번 일부로 검색(수동 검색용). 품명도 함께 검색합니다.
  List<ProductInfo> searchItems(String query, {int limit = 30}) {
    if (query.trim().isEmpty) return const [];
    final q = query.toUpperCase().trim();
    final results = <ProductInfo>[];
    final seenItemNo = <String>{};

    for (final entry in _byItemNo.entries) {
      if (results.length >= limit) break;
      final matchesItemNo = entry.key.contains(q);
      final matchesName =
          entry.value.isNotEmpty && entry.value.first.name.toUpperCase().contains(q);
      if ((matchesItemNo || matchesName) && seenItemNo.add(entry.key)) {
        results.add(entry.value.first);
      }
    }
    return results;
  }

  /// OCR로 인식된 토큰들(단어 단위)을 가지고 상품 매칭을 시도합니다.
  ///
  /// 1) 토큰 하나가 바코드와 완전히 일치하는지 확인
  /// 2) (길이가 충분히 길면) 근사 일치 확인 - OCR 오인식 대비
  /// 3) 품번으로 보이는 토큰 + 색상/사이즈로 보이는 토큰을 조합해서 확인
  ///    (라벨에 품번/컬러/사이즈가 따로 인쇄된 경우)
  MatchResult attemptAutoMatch(List<String> tokens) {
    if (tokens.isEmpty) return const MatchResult(confidence: MatchConfidence.none);

    final sortedByLength = [...tokens]
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final t in sortedByLength) {
      final exact = findExactBarcode(t);
      if (exact != null) {
        return MatchResult(
          product: exact,
          confidence: MatchConfidence.exact,
          matchedFrom: t,
        );
      }
    }

    // 가장 긴 후보 1~2개에 대해서만 근사 매칭 시도 (성능 보호)
    for (final t in sortedByLength.take(2)) {
      final near = findClosestBarcode(t);
      if (near != null) {
        return MatchResult(
          product: near,
          confidence: MatchConfidence.fuzzy,
          matchedFrom: t,
        );
      }
    }

    // 품번 + 색상 + 사이즈가 따로 인쇄된 경우
    String? itemNo;
    for (final t in sortedByLength) {
      final matched = matchItemNo(t);
      if (matched != null) {
        itemNo = matched;
        break;
      }
    }

    if (itemNo != null) {
      final colorGuess = tokens.firstWhere(
        (t) => isKnownColor(t),
        orElse: () => '',
      );
      final sizeGuess = tokens.firstWhere(
        (t) => isKnownSize(t),
        orElse: () => '',
      );
      final combined = findByComponents(
        itemNo: itemNo,
        color: colorGuess.isEmpty ? null : colorGuess,
        size: sizeGuess.isEmpty ? null : sizeGuess,
      );
      if (combined != null) {
        final parts = [itemNo, colorGuess, sizeGuess]
            .where((s) => s.isNotEmpty)
            .join(' ');
        return MatchResult(
          product: combined,
          confidence: MatchConfidence.components,
          matchedFrom: parts,
        );
      }

      // 품번은 확실한데 색상/사이즈까지는 특정하지 못한 경우:
      // 임의로 하나를 고르는 대신 옵션 목록을 넘겨 사용자가 고르게 합니다.
      final variants = variantsForItemNo(itemNo);
      if (variants.isNotEmpty) {
        return MatchResult(
          confidence: MatchConfidence.components,
          matchedFrom: itemNo,
          ambiguousVariants: variants,
        );
      }
    }

    return const MatchResult(confidence: MatchConfidence.none);
  }

  /// Levenshtein 편집거리. [cutoff]를 넘어서면 더 계산하지 않고 cutoff+1을 반환합니다
  /// (모든 상품과 비교해야 하므로 성능을 위해 조기 종료).
  int _levenshtein(String a, String b, int cutoff) {
    if (a == b) return 0;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > cutoff) return cutoff + 1;

    List<int> prev = List<int>.generate(lb + 1, (i) => i);
    List<int> curr = List<int>.filled(lb + 1, 0);

    for (var i = 1; i <= la; i++) {
      curr[0] = i;
      var rowMin = curr[0];
      for (var j = 1; j <= lb; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((v, e) => v < e ? v : e);
        if (curr[j] < rowMin) rowMin = curr[j];
      }
      if (rowMin > cutoff) return cutoff + 1;
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[lb];
  }
}
