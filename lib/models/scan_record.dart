import 'product_info.dart';

/// 스캔 1건을 나타내는 데이터 모델입니다.
///
/// [product]가 있으면 상품 DB와 매칭에 성공한 경우이고,
/// null이면 코드만 인식(또는 직접 입력)되고 상품명은 아직 연결되지 않은 상태입니다.
class ScanRecord {
  final String id;
  String code;
  final DateTime scannedAt;
  String? memo;
  ProductInfo? product;

  ScanRecord({
    required this.id,
    required this.code,
    required this.scannedAt,
    this.memo,
    this.product,
  });

  bool get isMatched => product != null;

  String get displayName => product?.name ?? '(상품명 미확인)';

  Map<String, dynamic> toMap() => {
        'id': id,
        'code': code,
        'itemNo': product?.itemNo ?? '',
        'name': product?.name ?? '',
        'color': product?.color ?? '',
        'size': product?.sizeLabel ?? '',
        'scannedAt': scannedAt.toIso8601String(),
        'memo': memo ?? '',
        'matched': isMatched,
      };

  /// 기기에 저장(영구 보관)하기 위한 직렬화.
  /// 상품 정보 전체를 저장하지 않고, 매칭됐던 바코드만 저장해뒀다가
  /// 불러올 때 [ProductLookupService]에서 다시 찾아 연결합니다
  /// (상품 DB가 갱신돼도 항상 최신 상품명을 보여주기 위함).
  Map<String, dynamic> toStorageJson() => {
        'id': id,
        'code': code,
        'scannedAt': scannedAt.toIso8601String(),
        'memo': memo,
        'barcode': product?.barcode,
      };

  static ScanRecord fromStorageJson(
    Map<String, dynamic> json,
    ProductInfo? Function(String barcode) findByBarcode,
  ) {
    final barcode = json['barcode'] as String?;
    return ScanRecord(
      id: json['id'] as String,
      code: json['code'] as String,
      scannedAt: DateTime.parse(json['scannedAt'] as String),
      memo: json['memo'] as String?,
      product: (barcode != null && barcode.isNotEmpty)
          ? findByBarcode(barcode)
          : null,
    );
  }
}
