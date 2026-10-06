import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/product_info.dart';

enum MatchConfidence {
  /// 인식된 문자열이 바코드와 완전히 일치
  exact,

  /// OCR 오인식을 감안한 근사(편집거리) 일치
  fuzzy,

  /// 품번+색상+사이즈가 라벨에 따로 표기되어 있어 조합으로 찾은 경우
  components,

  /// 예전에 이 라벨이 똑같이 틀리게 읽혔을 때 사용자가 바로잡아준 기록으로 찾은 경우
  learned,

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

  /// 바코드가 정확히 일치하지 않았을 때, 읽힌 글자와 비슷한 상품 후보들
  /// (비슷한 순서). 라벨이 구겨지거나 둥글어서 일부 글자만 맞게 읽혀도
  /// 여기에 맞는 상품이 들어오는 경우가 많아서, 화면에 "이 상품인가요?"로
  /// 보여줍니다.
  final List<ProductSuggestion> suggestions;

  /// [MatchConfidence.learned]일 때, 같은 짝을 사용자가 몇 번 확인해줬는지
  final int learnedCount;

  const MatchResult({
    this.product,
    required this.confidence,
    this.matchedFrom = '',
    this.ambiguousVariants = const [],
    this.suggestions = const [],
    this.learnedCount = 0,
  });

  bool get isMatched => product != null;

  bool get isAmbiguous => product == null && ambiguousVariants.isNotEmpty;
}

/// 비슷한 상품 후보 1건. [score]는 0에 가까울수록 비슷합니다(0 = 완전히 같음).
class ProductSuggestion {
  final ProductInfo product;
  final double score;

  const ProductSuggestion(this.product, this.score);
}

/// 틀리게 읽힌 글자 -> 사용자가 바로잡아준 상품(바코드)과 확인 횟수
class LearnedCorrection {
  final String barcode;
  final int count;

  const LearnedCorrection(this.barcode, this.count);
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

  /// 비슷한 바코드를 빨리 찾기 위한 색인: 3글자 조각 -> 그 조각이 들어있는 바코드들
  final Map<String, List<String>> _gramIndex = {};

  /// 사용자가 바로잡아준 기록: 틀리게 읽힌 글자(정규화) -> 맞는 상품.
  /// 기기에 저장돼서 앱을 껐다 켜도 남고, 인터넷 없이 동작합니다.
  static const _learnedPrefKey = 'ocr_corrections_v1';
  static const _maxLearned = 3000;
  final Map<String, LearnedCorrection> _learned = {};

  int get learnedCount => _learned.length;

  /// 구겨지거나 둥근 라벨에서 OCR이 서로 헷갈리기 쉬운 글자 묶음
  /// (O/S/B/Z/G는 이미 0/5/8/2/6으로 통일된 뒤라서 숫자 쪽으로 적었습니다).
  /// 같은 묶음 안의 글자로 잘못 읽힌 건 "절반 이하의 실수"로 계산합니다.
  static const List<String> _similarGroups = [
    '0DQ', '1IL7T', 'UV', 'MNW', 'KX', 'EF', 'C6', 'PR', 'A4', 'HN', '83',
  ];
  static final Set<String> _similarPairs = () {
    final pairs = <String>{};
    for (final group in _similarGroups) {
      for (final a in group.split('')) {
        for (final b in group.split('')) {
          if (a != b) pairs.add('$a$b');
        }
      }
    }
    return pairs;
  }();

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

    for (final key in _byBarcode.keys) {
      for (final g in _grams(key)) {
        _gramIndex.putIfAbsent(g, () => []).add(key);
      }
    }

    await _loadLearned();
    _loaded = true;
  }

  Future<void> _loadLearned() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_learnedPrefKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      map.forEach((key, value) {
        final list = value as List<dynamic>;
        _learned[key] = LearnedCorrection(
          list[0] as String,
          (list[1] as num).toInt(),
        );
      });
    } catch (_) {
      // 기록을 못 읽어도 앱은 그대로 동작합니다.
    }
  }

  Future<void> _saveLearned() async {
    try {
      // 너무 많아지면 오래된 것(먼저 들어간 것)부터 지웁니다.
      while (_learned.length > _maxLearned) {
        _learned.remove(_learned.keys.first);
      }
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{
        for (final e in _learned.entries) e.key: [e.value.barcode, e.value.count],
      };
      await prefs.setString(_learnedPrefKey, json.encode(map));
    } catch (_) {}
  }

  /// 사용자가 이번 스캔의 상품을 [product]로 확정했을 때 호출합니다.
  /// 이번에 읽힌 글자 중 "그 상품의 바코드가 틀리게 읽힌 것"으로 보이는 것만
  /// 골라서 기억합니다. 안전하게 하기 위해:
  /// - 실제로 존재하는 다른 바코드와 똑같은 글자는 기억하지 않고,
  /// - 그 글자와 가장 비슷한 상품이 확정한 상품이고, 2등과 차이가 뚜렷할
  ///   때만 기억합니다(예: "F3TO002"처럼 같은 품번의 여러 색상에 똑같이
  ///   걸치는 글자는 기억하지 않음 → 다른 색상 옷을 잘못 연결하지 않도록).
  void learnCorrection(List<String> tokens, ProductInfo product) {
    if (tokens.isEmpty) return;
    final target = _normalizeBarcode(product.barcode);
    var changed = false;
    for (final cand in _matchCandidates(tokens)) {
      if (cand == target || _byBarcode.containsKey(cand)) continue;
      final ranked = _scoreKeysFor(cand).entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (ranked.isEmpty || ranked.first.key != target) continue;
      if (ranked.length > 1 && ranked[1].value - ranked.first.value < 0.05) continue;
      final prev = _learned.remove(cand);
      final count = (prev != null && prev.barcode == product.barcode) ? prev.count + 1 : 1;
      _learned[cand] = LearnedCorrection(product.barcode, count); // 최근 것이 뒤로
      changed = true;
    }
    if (changed) _saveLearned();
  }

  /// 바로잡아준 기록을 모두 지웁니다.
  Future<void> clearLearned() async {
    _learned.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_learnedPrefKey);
    } catch (_) {}
  }

  Set<String> _grams(String s) {
    final t = '^$s\$';
    final out = <String>{};
    for (var i = 0; i + 3 <= t.length; i++) {
      out.add(t.substring(i, i + 3));
    }
    return out;
  }

  /// 읽힌 글자들과 비슷한 상품을 비슷한 순서로 찾습니다.
  ///
  /// - 일부만 읽힌 경우(예: "F3TO002"): 그 글자가 들어있는 바코드를 후보로
  /// - 몇 글자 틀리게 읽힌 경우: 헷갈리기 쉬운 글자(1/I/L 등)는 가볍게,
  ///   완전히 다른 글자는 무겁게 쳐서 가까운 바코드를 후보로
  /// 주소·전화번호·세탁 표시처럼 상품과 무관한 글자만 있으면 후보가 나오지 않습니다.
  List<ProductSuggestion> suggestProducts(List<String> tokens, {int limit = 6}) {
    final best = <String, double>{};
    for (final cand in _matchCandidates(tokens)) {
      _scoreKeysFor(cand).forEach((key, score) {
        final prev = best[key];
        if (prev == null || score < prev) best[key] = score;
      });
    }

    final ranked = best.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return ranked
        .take(limit)
        .map((e) => ProductSuggestion(_byBarcode[e.key]!, e.value))
        .toList();
  }

  /// 읽힌 글자들에서 비교해볼 후보 문자열(정규화)을 만듭니다: 5글자 이상인
  /// 조각들 + 이웃 조각 2~5개를 이어붙인 것(코드가 쪼개져 읽힌 경우 대비).
  Set<String> _matchCandidates(List<String> tokens) {
    final candidates = <String>{};
    for (final t in tokens) {
      final n = _normalizeBarcode(t);
      if (n.length >= 5) candidates.add(n);
    }
    for (var i = 0; i < tokens.length; i++) {
      var acc = tokens[i];
      for (var span = 2; span <= 5 && i + span <= tokens.length; span++) {
        acc += tokens[i + span - 1];
        final n = _normalizeBarcode(acc);
        if (n.length >= 5 && n.length <= 24) candidates.add(n);
      }
    }
    return candidates;
  }

  /// 후보 문자열 하나와 비슷한 바코드들의 점수(0에 가까울수록 비슷함).
  Map<String, double> _scoreKeysFor(String cand) {
    final scores = <String, double>{};
    if (cand.length < 5) return scores;

    // 1) 3글자 조각이 많이 겹치는 바코드만 추려서(빠르게)
    final counts = <String, int>{};
    for (final g in _grams(cand)) {
      final keys = _gramIndex[g];
      if (keys == null || keys.length > 1500) continue; // 너무 흔한 조각은 건너뜀
      for (final k in keys) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final shortlist = counts.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 2) 추린 후보들만 자세히 비교
    for (final entry in shortlist.take(40)) {
      final key = entry.key;
      if (cand.length >= 6 && key.contains(cand)) {
        scores[key] = 0.5 * (1 - cand.length / key.length);
      } else {
        final limitDistance = 0.35 * key.length;
        final cutoff = limitDistance < 1.0 ? 1.0 : limitDistance;
        final d = _weightedDistance(cand, key, cutoff);
        if (d <= cutoff) scores[key] = d / key.length;
      }
    }
    return scores;
  }

  /// 헷갈리기 쉬운 글자끼리 바뀐 건 0.4, 그 외 바뀜/빠짐/추가는 1로 계산하는
  /// 편집거리. [cutoff]를 넘으면 계산을 멈추고 cutoff + 1을 반환합니다.
  double _weightedDistance(String a, String b, double cutoff) {
    if (a == b) return 0.0;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > cutoff) return cutoff + 1;

    var prev = List<double>.generate(lb + 1, (j) => j.toDouble());
    var curr = List<double>.filled(lb + 1, 0.0);
    for (var i = 1; i <= la; i++) {
      curr[0] = i.toDouble();
      var rowMin = curr[0];
      final ca = a[i - 1];
      for (var j = 1; j <= lb; j++) {
        final cb = b[j - 1];
        final sub = ca == cb ? 0.0 : (_similarPairs.contains('$ca$cb') ? 0.4 : 1.0);
        var v = prev[j - 1] + sub;
        final del = prev[j] + 1.0;
        if (del < v) v = del;
        final ins = curr[j - 1] + 1.0;
        if (ins < v) v = ins;
        curr[j] = v;
        if (v < rowMin) rowMin = v;
      }
      if (rowMin > cutoff) return cutoff + 1;
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[lb];
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
  /// 화면에는 원래 인식된 문자 그대로 표시되므로 사용자에게 혼동을 주지
  /// 않습니다.
  String _normalizeBarcode(String s) => s
      .toUpperCase()
      .replaceAll(RegExp(r'[\s\-]'), '')
      .replaceAll('O', '0')
      .replaceAll('S', '5')
      .replaceAll('B', '8')
      .replaceAll('Z', '2')
      .replaceAll('G', '6');

  /// 정확히 일치하는 바코드를 먼저 찾고, 없으면 OCR 오인식을 감안한
  /// 근사 일치까지 시도합니다. 사용자가 후보를 고르거나 코드를 직접
  /// 수정/입력했을 때도 자동 스캔과 동일한 수준의 보정을 받도록
  /// 화면 쪽 여러 곳에서 공통으로 사용합니다.
  ProductInfo? findBestBarcode(String code) =>
      findExactBarcode(code) ?? findClosestBarcode(code);

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
          _normalizeBarcode(v.color) == _normalizeBarcode(color);
      final sizeOk = size == null ||
          _normalizeBarcode(v.size) == _normalizeBarcode(size) ||
          _normalizeBarcode(v.sizeLabel) == _normalizeBarcode(size);
      if (colorOk && sizeOk) return v;
    }
    return null;
  }

  bool isKnownColor(String token) =>
      _knownColors.contains(_normalizeBarcode(token));

  bool isKnownSize(String token) => _knownSizes.contains(_normalizeBarcode(token));

  /// 정확한 품번이거나(하이픈 유무와 무관하게) 인식되면 실제 품번 문자열을 반환합니다.
  String? matchItemNo(String token) {
    final upper = token.toUpperCase();
    if (_byItemNo.containsKey(upper)) return upper;

    final normalized = _normalizeBarcode(token);
    final candidates = _itemNoByNormalized[normalized];
    if (candidates != null && candidates.length == 1) return candidates.first;
    return null;
  }

  /// [matchItemNo]가 정확히 일치하는 품번을 찾지 못했을 때, OCR 오인식을
  /// 감안해 편집거리 이내의 가장 가까운 품번을 찾습니다(바코드 전체가 아니라
  /// 품번/컬러/사이즈가 라벨에 따로 인쇄된 경우를 위한 것입니다).
  /// 가장 가까운 후보가 여러 실제 품번에 걸쳐 있으면(모호하면) null을
  /// 반환해서 잘못된 상품을 임의로 고르지 않도록 합니다.
  String? matchItemNoFuzzy(String token, {int maxDistance = 2}) {
    final target = _normalizeBarcode(token);
    if (target.length < 6) return null;

    List<String>? best;
    int bestDist = maxDistance + 1;

    for (final entry in _itemNoByNormalized.entries) {
      if ((entry.key.length - target.length).abs() > maxDistance) continue;
      final dist = _levenshtein(target, entry.key, bestDist);
      if (dist < bestDist) {
        bestDist = dist;
        best = entry.value;
        if (bestDist == 0) break;
      }
    }
    if (best != null && bestDist <= maxDistance && best.length == 1) {
      return best.first;
    }
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
  MatchResult attemptAutoMatch(List<String> tokens, {bool withSuggestions = true}) {
    if (tokens.isEmpty) return const MatchResult(confidence: MatchConfidence.none);

    final sortedByLength = [...tokens]
      ..sort((a, b) => b.length.compareTo(a.length));

    // OCR이 하이픈 등 구분 기호를 다른 문자로 잘못 읽거나 아예 놓쳐서,
    // 원래 하나였던 코드가 인접한 토큰 여러 개로 쪼개지는 경우가 있습니다
    // (예: "SN2F3TO002NA-F" 한 줄이 "SN2" / "F3TO002" / "NA-F" 세 조각으로
    // 인식되는 경우). 두 개만 이어붙이면 이런 경우를 못 잡으므로, 원문에 나온
    // 순서 그대로 이웃한 토큰 2~5개를 이어붙여서도 확인합니다.
    final joinedCandidates = <String>[];
    const maxJoinSpan = 5;
    for (var i = 0; i < tokens.length; i++) {
      var acc = tokens[i];
      for (var span = 2;
          span <= maxJoinSpan && i + span <= tokens.length;
          span++) {
        acc += tokens[i + span - 1];
        joinedCandidates.add(acc);
      }
    }

    for (final t in [...sortedByLength, ...joinedCandidates]) {
      final exact = findExactBarcode(t);
      if (exact != null) {
        return MatchResult(
          product: exact,
          confidence: MatchConfidence.exact,
          matchedFrom: t,
        );
      }
    }

    // 예전에 사용자가 바로잡아준 기록과 똑같이 읽혔으면 그 상품으로 찾습니다.
    if (_learned.isNotEmpty) {
      for (final cand in _matchCandidates(tokens).toList()
        ..sort((a, b) => b.length.compareTo(a.length))) {
        final memo = _learned[cand];
        if (memo == null) continue;
        final product = _byBarcode[_normalizeBarcode(memo.barcode)];
        if (product == null) continue; // 상품 데이터에서 빠진 상품이면 무시
        return MatchResult(
          product: product,
          confidence: MatchConfidence.learned,
          matchedFrom: product.barcode,
          suggestions: withSuggestions ? suggestProducts(tokens) : const [],
          learnedCount: memo.count,
        );
      }
    }

    // 정확히 일치하는 바코드가 없으면 비슷한 상품 후보를 구해둡니다.
    // (예전에는 한두 글자 차이면 바로 "근사 일치"로 골랐는데, 같은 품번의
    // 다른 색상처럼 글자 하나 차이인 상품을 잘못 고르는 경우가 있어서,
    // 확실히 한 상품만 가까울 때만 고르고 나머지는 후보로 보여줍니다.)
    // (라이브 인식처럼 1초에 여러 번 부르는 경우엔 후보 계산을 건너뜁니다.)
    final suggestions =
        withSuggestions ? suggestProducts(tokens) : const <ProductSuggestion>[];

    // 품번 + 색상 + 사이즈가 따로 인쇄된 경우
    String? itemNo;
    int itemNoTokenIndex = -1;
    for (final t in sortedByLength) {
      final matched = matchItemNo(t);
      if (matched != null) {
        itemNo = matched;
        itemNoTokenIndex = tokens.indexOf(t);
        break;
      }
    }

    // 품번이 정확히 일치하지 않으면, OCR 오인식을 감안해 가장 가까운
    // 품번을 근사 매칭으로 찾아봅니다(바코드 근사 매칭과 동일한 원리).
    if (itemNo == null) {
      for (final t in sortedByLength.take(3)) {
        final matched = matchItemNoFuzzy(t);
        if (matched != null) {
          itemNo = matched;
          itemNoTokenIndex = tokens.indexOf(t);
          break;
        }
      }
    }

    if (itemNo != null) {
      // 라벨에는 품번/색상/사이즈 외에도 제조일자, 전화번호, 주소처럼 색상·
      // 사이즈 코드와 우연히 겹칠 수 있는 문자열이 많습니다. 품번이 인식된
      // 위치 "근처"의 토큰을 먼저 살펴보고, 거기서 못 찾으면 전체에서
      // 찾아서 엉뚱한 값을 색상/사이즈로 잘못 고르는 일을 줄입니다.
      final colorGuess = _guessNearby(tokens, itemNoTokenIndex, isKnownColor);
      final sizeGuess = _guessNearby(tokens, itemNoTokenIndex, isKnownSize);
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
          suggestions: suggestions,
        );
      }
    }

    // 후보 중 하나만 확실히 가까우면(나머지와 차이가 뚜렷하면) 그 상품으로
    // 고릅니다. 이 경우에도 화면에서 한 번 확인을 받습니다.
    if (suggestions.isNotEmpty) {
      final top = suggestions.first.score;
      final second = suggestions.length > 1 ? suggestions[1].score : 1.0;
      if (top <= 0.15 && second - top >= 0.08) {
        return MatchResult(
          product: suggestions.first.product,
          confidence: MatchConfidence.fuzzy,
          matchedFrom: suggestions.first.product.barcode,
          suggestions: suggestions,
        );
      }
    }

    if (itemNo != null) {
      // 품번은 확실한데 색상/사이즈까지는 특정하지 못한 경우:
      // 임의로 하나를 고르는 대신 옵션 목록을 넘겨 사용자가 고르게 합니다.
      final variants = variantsForItemNo(itemNo);
      if (variants.isNotEmpty) {
        return MatchResult(
          confidence: MatchConfidence.components,
          matchedFrom: itemNo,
          ambiguousVariants: variants,
          suggestions: suggestions,
        );
      }
    }

    return MatchResult(
      confidence: MatchConfidence.none,
      suggestions: suggestions,
    );
  }

  /// [centerIndex](품번 토큰의 위치) 주변 토큰들 중에서 [predicate]를
  /// 만족하는 첫 토큰을 찾습니다. 못 찾으면 전체 토큰에서 찾습니다
  /// (기존 동작과 동일하게 유지해서 인식률이 떨어지지 않도록 함).
  String _guessNearby(
    List<String> tokens,
    int centerIndex,
    bool Function(String) predicate, {
    int window = 4,
  }) {
    if (centerIndex >= 0) {
      final start = (centerIndex - window).clamp(0, tokens.length);
      final end = (centerIndex + window + 1).clamp(0, tokens.length);
      for (var i = start; i < end; i++) {
        if (i == centerIndex) continue;
        if (predicate(tokens[i])) return tokens[i];
      }
    }
    return tokens.firstWhere(predicate, orElse: () => '');
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
