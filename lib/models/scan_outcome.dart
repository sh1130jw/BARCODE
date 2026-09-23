import 'product_info.dart';
import 'scan_record.dart';

/// 스캔 화면에서 홈 화면으로 결과를 전달할 때 사용하는 값.
class ScanOutcome {
  final String code;
  final ProductInfo? product;

  const ScanOutcome({required this.code, this.product});
}

/// 스캔 결과를 목록에 넣은 결과.
/// [merged]가 true면 이미 있던 줄의 수량을 올린 것이고,
/// false면 새 줄을 추가한 것입니다(되돌리기에 사용).
class AddResult {
  final ScanRecord record;
  final bool merged;

  const AddResult({required this.record, required this.merged});
}
