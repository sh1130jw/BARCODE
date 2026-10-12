import 'dart:io';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';

/// 스캔 목록을 .xlsx 파일로 만들고 공유(카카오톡/이메일/저장 등)하는 서비스.
///
/// 만든 파일은 앱 안에도 남겨두어서 "보관함"에서 다시 보내거나 지울 수 있습니다.
class ExcelExportService {
  /// 박스 순서(1번, 2번, …), 같은 박스 안에서는 스캔한 순서로 정렬합니다.
  List<ScanRecord> _sortByBox(List<ScanRecord> records) {
    final sorted = [...records];
    sorted.sort((a, b) {
      final byBox = compareBoxes(a.box, b.box);
      if (byBox != 0) return byBox;
      return a.scannedAt.compareTo(b.scannedAt);
    });
    return sorted;
  }

  Future<File> buildExcelFile(List<ScanRecord> records) async {
    final excel = Excel.createExcel();
    final sorted = _sortByBox(records);

    // ---- 시트 1: 전체 목록(박스 열 포함) ----
    const sheetName = '스캔목록';
    excel.rename(excel.getDefaultSheet()!, sheetName);
    final Sheet sheet = excel[sheetName];

    sheet.appendRow(<CellValue?>[
      TextCellValue('번호'),
      TextCellValue('박스'),
      TextCellValue('품번'),
      TextCellValue('품명'),
      TextCellValue('색상'),
      TextCellValue('사이즈'),
      TextCellValue('수량'),
      TextCellValue('인식코드'),
      TextCellValue('매칭여부'),
      TextCellValue('인식일시'),
      TextCellValue('메모'),
    ]);

    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    for (var i = 0; i < sorted.length; i++) {
      final r = sorted[i];
      final p = r.product;
      sheet.appendRow(<CellValue?>[
        IntCellValue(i + 1),
        TextCellValue(boxLabel(r.box)),
        TextCellValue(p?.itemNo ?? ''),
        TextCellValue(p?.name ?? ''),
        TextCellValue(p?.color ?? ''),
        TextCellValue(p?.sizeLabel ?? ''),
        IntCellValue(r.quantity),
        TextCellValue(r.code),
        TextCellValue(r.isMatched ? 'O' : 'X'),
        TextCellValue(dateFormat.format(r.scannedAt)),
        TextCellValue(r.memo ?? ''),
      ]);
    }

    final totalQuantity = sorted.fold<int>(0, (sum, r) => sum + r.quantity);
    sheet.appendRow(<CellValue?>[
      TextCellValue('합계'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue('${sorted.length}종'),
      TextCellValue(''),
      TextCellValue(''),
      IntCellValue(totalQuantity),
    ]);

    // ---- 시트 2: 박스별 합계 ----
    final Sheet summary = excel['박스별 합계'];
    summary.appendRow(<CellValue?>[
      TextCellValue('박스'),
      TextCellValue('상품 종류'),
      TextCellValue('수량'),
    ]);
    final boxKeys = <String>[];
    final kinds = <String, int>{};
    final quantities = <String, int>{};
    for (final r in sorted) {
      final key = (r.box ?? '').trim();
      if (!kinds.containsKey(key)) boxKeys.add(key);
      kinds[key] = (kinds[key] ?? 0) + 1;
      quantities[key] = (quantities[key] ?? 0) + r.quantity;
    }
    for (final key in boxKeys) {
      summary.appendRow(<CellValue?>[
        TextCellValue(boxLabel(key)),
        IntCellValue(kinds[key] ?? 0),
        IntCellValue(quantities[key] ?? 0),
      ]);
    }
    summary.appendRow(<CellValue?>[
      TextCellValue('합계 (${boxKeys.length}박스)'),
      IntCellValue(sorted.length),
      IntCellValue(totalQuantity),
    ]);

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('엑셀 파일 생성에 실패했습니다.');
    }

    final dir = await getApplicationDocumentsDirectory();
    final fileName =
        'SINOON_스캔_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> exportAndShare(List<ScanRecord> records) async {
    final file = await buildExcelFile(records);
    final boxes = records.map((r) => (r.box ?? '').trim()).toSet().length;
    final total = records.fold<int>(0, (sum, r) => sum + r.quantity);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: '케어라벨 스캔 결과',
      text: '케어라벨 스캔 결과 ($boxes박스, ${records.length}종, 총 $total개)',
    );
  }

  /// 지금까지 만든 엑셀 파일들(최근 것부터).
  Future<List<File>> listSavedFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.xlsx'))
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<void> shareFile(File file) async {
    await Share.shareXFiles([XFile(file.path)], subject: '케어라벨 스캔 결과');
  }
}
