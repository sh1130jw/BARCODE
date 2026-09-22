import 'product_info.dart';

/// 스캔 화면에서 홈 화면으로 결과를 전달할 때 사용하는 값.
class ScanOutcome {
  final String code;
  final ProductInfo? product;

  const ScanOutcome({required this.code, this.product});
}
