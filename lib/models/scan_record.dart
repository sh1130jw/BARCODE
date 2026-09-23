import 'product_info.dart';

/// 스캔 1건(같은 상품은 한 줄로 합쳐서 수량으로 관리)을 나타내는 데이터 모델입니다.
///
/// [product]가 있으면 상품 DB와 매칭에 성공한 경우이고,
/// null이면 코드만 인식(또는 직접 입력)되고 상품명은 아직 연결되지 않은 상태입니다.
class ScanRecord {
  final String id;
  String code;
  final DateTime scannedAt;
  String? memo;
  ProductInfo? product;

  /// 같은 상품을 여러 번 스캔하면 줄을 늘리지 않고 이 수량을 올립니다.
  int quantity;

  ScanRecord({
    required this.id,
    required this.code,
    required this.scannedAt,
    this.memo,
    this.product,
    this.quantity = 1,
  });

  bool get isMatched => product != null;

  String get displayName => product?.name ?? '(상품명 미확인)';

  /// 같은 상품인지 판단하는 기준.
  /// 상품이 연결돼 있으면 바코드로, 아니면 인식된 코드 문자열로 비교합니다.
  String get mergeKey => product != null
      ? 'P:${product!.barcode.toUpperCase()}'
      : 'C:${code.trim().toUpperCase()}';

  Map<String, dynamic> toMap() => {
        'id': id,
        'code': code,
        'itemNo': product?.itemNo ?? '',
        'name': product?.name ?? '',
        'color': product?.color ?? '',
        'size': product?.sizeLabel ?? '',
        'quantity': quantity,
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
        'quantity': quantity,
      };

  static ScanRecord fromStorageJson(
    Map<String, dynamic> json,
    ProductInfo? Function(String barcode) findByBarcode,
  ) {
    final barcode = json['barcode'] as String?;
    // 수량 기능 이전에 저장된 기록에는 quantity가 없으므로 1로 봅니다.
    final rawQuantity = json['quantity'];
    final quantity = rawQuantity is num && rawQuantity >= 1 ? rawQuantity.toInt() : 1;
    return ScanRecord(
      id: json['id'] as String,
      code: json['code'] as String,
      scannedAt: DateTime.parse(json['scannedAt'] as String),
      memo: json['memo'] as String?,
      product: (barcode != null && barcode.isNotEmpty)
          ? findByBarcode(barcode)
          : null,
      quantity: quantity,
    );
  }
}
