/// `assets/product_barcodes.json`(엑셀 "상품바코드조회" 원본을 변환한 데이터)의
/// 한 행을 나타내는 모델입니다.
class ProductInfo {
  final String itemNo; // 품번
  final String name; // 품명
  final String color; // 색상 코드 (예: BU, TL / 없으면 "-")
  final String size; // 사이즈 코드 (예: F, S, M, 230)
  final String sizeLabel; // 사이즈표기 (예: FREE, SMALL, MEDIUM)
  final String barcode; // 바코드 (품번+색상+사이즈 조합)
  final String category; // 사이즈구분명 (예: 의류(CLOTHES))
  final String gender; // 성별구분명
  final int? price; // 최초판매가
  final int? tagPrice; // 택가

  ProductInfo({
    required this.itemNo,
    required this.name,
    required this.color,
    required this.size,
    required this.sizeLabel,
    required this.barcode,
    required this.category,
    required this.gender,
    this.price,
    this.tagPrice,
  });

  factory ProductInfo.fromJson(Map<String, dynamic> json) => ProductInfo(
        itemNo: (json['itemNo'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        color: (json['color'] ?? '-').toString(),
        size: (json['size'] ?? '').toString(),
        sizeLabel: (json['sizeLabel'] ?? '').toString(),
        barcode: (json['barcode'] ?? '').toString(),
        category: (json['category'] ?? '').toString(),
        gender: (json['gender'] ?? '').toString(),
        price: json['price'] is int ? json['price'] as int : null,
        tagPrice: json['tagPrice'] is int ? json['tagPrice'] as int : null,
      );

  /// 색상이 없는(단일 색상) 상품인지 여부
  bool get hasColor => color.isNotEmpty && color != '-';

  /// 목록/다이얼로그에 보여줄 한 줄 요약
  String get variantLabel {
    final parts = <String>[];
    if (hasColor) parts.add(color);
    if (sizeLabel.isNotEmpty) parts.add(sizeLabel);
    return parts.isEmpty ? '' : parts.join(' / ');
  }
}
