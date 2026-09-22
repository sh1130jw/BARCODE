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
}
