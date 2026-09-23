import 'dart:io';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';

/// 스캔 목록을 .xlsx 파일로 만들고 공유(카카오톡/이메일/저장 등)하는 서비스.
class ExcelExportService {
  Future<File> buildExcelFile(List<ScanRecord> records) async {
    final excel = Excel.createExcel();

    const sheetName = '스캔목록';
    excel.rename(excel.getDefaultSheet()!, sheetName);
    final Sheet sheet = excel[sheetName];

    sheet.appendRow(<CellValue?>[
      TextCellValue('번호'),
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
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      final p = r.product;
      sheet.appendRow(<CellValue?>[
        IntCellValue(i + 1),
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

    // 맨 아래에 합계(총 수량) 줄을 넣습니다.
    final totalQuantity = records.fold<int>(0, (sum, r) => sum + r.quantity);
    sheet.appendRow(<CellValue?>[
      TextCellValue('합계'),
      TextCellValue(''),
      TextCellValue('${records.length}종'),
      TextCellValue(''),
      TextCellValue(''),
      IntCellValue(totalQuantity),
    ]);

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('엑셀 파일 생성에 실패했습니다.');
    }

    final dir = await getApplicationDocumentsDirectory();
    final fileName =
        'care_label_scan_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> exportAndShare(List<ScanRecord> records) async {
    final file = await buildExcelFile(records);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: '케어라벨 스캔 결과',
      text: '케어라벨 스캔 결과 (${records.length}종, '
          '총 ${records.fold<int>(0, (sum, r) => sum + r.quantity)}개)',
    );
  }
}
