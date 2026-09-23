import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/product_info.dart';
import '../models/scan_record.dart';

/// 스캔 목록(저장 로그)을 기기에 영구 저장하고 불러오는 서비스.
///
/// 이전에는 앱을 완전히 종료하면 스캔 목록이 사라졌는데(메모리에만 보관),
/// 이제는 스캔/수정/삭제할 때마다 기기 안에 자동으로 저장해서
/// 앱을 껐다 켜도, 며칠에 걸쳐 작업해도 기록이 남아있도록 합니다.
/// (인터넷 연결이 필요 없는 기기 로컬 저장소를 사용합니다.)
class ScanHistoryService {
  static const _storageKey = 'scan_records_v1';

  /// 저장된 기록을 불러옵니다. [findByBarcode]로 각 기록의 상품 정보를
  /// 상품 DB에서 다시 찾아 연결합니다(상품 DB가 갱신돼도 최신 상품명을
  /// 보여주기 위함). 저장된 기록이 없거나 읽기에 실패하면 빈 목록을 반환합니다.
  Future<List<ScanRecord>> load(
    ProductInfo? Function(String barcode) findByBarcode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return [];

      final List<dynamic> list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => ScanRecord.fromStorageJson(
                e as Map<String, dynamic>,
                findByBarcode,
              ))
          .toList();
    } catch (_) {
      // 저장된 데이터가 손상되어 있어도 앱이 멈추지 않도록 빈 목록으로 시작합니다.
      return [];
    }
  }

  /// 현재 스캔 목록 전체를 기기에 저장합니다.
  /// (스캔 추가/수정/삭제/상품 연결이 있을 때마다 호출합니다.)
  Future<void> save(List<ScanRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = json.encode(records.map((r) => r.toStorageJson()).toList());
    await prefs.setString(_storageKey, raw);
  }

  /// 저장된 기록을 모두 지웁니다.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
