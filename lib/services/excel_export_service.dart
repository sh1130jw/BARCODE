import 'dart:io';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';

/// 스캔 목록을 이름을 붙인 .xlsx 파일로 저장하고(보관함),
/// 저장한 파일을 다시 보내거나(카카오톡/이메일/드라이브 등) 이름을 바꾸고 지우는 서비스.
class ExcelExportService {
  /// 파일 이름에 쓸 수 없는 글자(\ / : * ? " < > |)를 빼고 정리합니다.
  String cleanName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.toLowerCase().endsWith('.xlsx')) s = s.substring(0, s.length - 5).trim();
    while (s.startsWith('.')) {
      s = s.substring(1).trim();
    }
    if (s.length > 80) s = s.substring(0, 80).trim();
    return s;
  }

  /// 파일 이름(확장자 뺀 것)
  String displayName(File file) {
    final name = file.path.split('/').last;
    return name.toLowerCase().endsWith('.xlsx') ? name.substring(0, name.length - 5) : name;
  }

  Future<Directory> _dir() => getApplicationDocumentsDirectory();

  /// 같은 이름이 있으면 "이름 (2)", "이름 (3)" … 으로 피합니다.
  File _uniqueFile(Directory dir, String base, {File? except}) {
    var file = File('${dir.path}/$base.xlsx');
    var n = 2;
    while (file.existsSync() && (except == null || file.path != except.path)) {
      file = File('${dir.path}/$base ($n).xlsx');
      n += 1;
    }
    return file;
  }

  List<int> _buildBytes(List<ScanRecord> records) {
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
    return bytes;
  }

  /// 스캔 목록을 [name] 이름의 엑셀 파일로 보관함에 저장합니다.
  Future<File> saveNamed(List<ScanRecord> records, String name) async {
    final base = cleanName(name);
    if (base.isEmpty) throw Exception('파일 이름을 입력해 주세요.');
    final bytes = _buildBytes(records);
    final dir = await _dir();
    final file = _uniqueFile(dir, base);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 보관함에 있는 엑셀 파일들(최근 것부터).
  Future<List<File>> listSavedFiles() async {
    final dir = await _dir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.xlsx'))
        .toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// 파일 이름을 바꿉니다(같은 이름이 있으면 뒤에 (2) 등을 붙입니다).
  Future<File> rename(File file, String newName) async {
    final base = cleanName(newName);
    if (base.isEmpty) throw Exception('파일 이름을 입력해 주세요.');
    final target = _uniqueFile(file.parent, base, except: file);
    if (target.path == file.path) return file;
    return file.rename(target.path);
  }

  Future<void> shareFile(File file) async {
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: displayName(file),
      text: '${displayName(file)} (케어라벨 스캔 목록)',
    );
  }
}
