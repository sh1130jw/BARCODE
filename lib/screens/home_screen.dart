import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../main.dart' show AppleColors;
import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../models/scan_record.dart';
import '../services/excel_export_service.dart';
import '../services/product_lookup_service.dart';
import '../services/scan_history_service.dart';
import '../widgets/product_search_sheet.dart';
import 'catalog_screen.dart';
import 'scan_screen.dart';

/// 스캔된 코드/상품 목록을 보여주고, 이름을 붙여 엑셀 파일로 저장(보관함)하는 홈 화면.
/// 아이폰 "설정" 앱처럼 회색 바탕 위에 둥근 흰 목록을 얹은 모양입니다.
class HomeScreen extends StatefulWidget {
  final CameraDescription camera;
  final ProductLookupService productLookup;

  const HomeScreen({
    super.key,
    required this.camera,
    required this.productLookup,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _lastNamePrefKey = 'save_last_name';
  static const _lastNameWasDefaultPrefKey = 'save_last_name_was_default';
  static const _clearAfterSavePrefKey = 'save_clear_after';

  final List<ScanRecord> _records = [];
  final Uuid _uuid = const Uuid();
  final ExcelExportService _exportService = ExcelExportService();
  final ScanHistoryService _historyService = ScanHistoryService();

  bool _isSaving = false;
  bool _isHistoryLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  /// 이전에 저장해둔 스캔 기록을 불러옵니다(앱을 껐다 켜도 목록이 남도록).
  Future<void> _loadHistory() async {
    final loaded = await _historyService.load(
      widget.productLookup.findExactBarcode,
    );
    if (!mounted) return;
    setState(() {
      _records
        ..clear()
        ..addAll(loaded);
      _isHistoryLoaded = true;
    });
  }

  /// 스캔 목록이 바뀔 때마다 기기에 저장합니다.
  void _persist() {
    // 목록을 아직 불러오는 중일 때는 저장하지 않습니다(빈 목록으로 덮어써서
    // 기존 저장 기록을 지워버리는 것을 방지).
    if (!_isHistoryLoaded) return;
    _historyService.save(_records);
  }

  void _toast(String message, {String? actionLabel, VoidCallback? onAction}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
  }

  // ---------------- 목록 ----------------

  Future<void> _confirmClearAll() async {
    if (_records.isEmpty) return;
    final ok = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('스캔 목록 전체 삭제'),
        message: Text(
          '지금 목록 ${_records.length}건을 모두 지울까요?\n보관함에 저장하지 않았다면 되돌릴 수 없어요.',
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전체 삭제'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('취소'),
        ),
      ),
    );
    if (ok == true) {
      setState(() => _records.clear());
      _persist();
    }
  }

  /// 틀리게 읽힌 라벨을 바로잡아준 기록(자동으로 쌓임)을 지웁니다.
  /// 잘못 고른 상품이 기억돼서 계속 엉뚱하게 찾을 때 사용합니다.
  Future<void> _confirmClearLearned() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('인식 학습 기록 지우기'),
        content: const Text(
          '틀리게 읽힌 라벨을 바로잡아준 기록을 모두 지울까요?\n스캔 목록은 그대로 남아요.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.productLookup.clearLearned();
      if (!mounted) return;
      _toast('인식 학습 기록을 지웠어요.');
    }
  }

  /// 오른쪽 위 "···" 버튼
  Future<void> _showMoreMenu() async {
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'catalog'),
            child: const Text('상품 목록 보기'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'saved'),
            child: const Text('보관함 (저장한 파일)'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'learned'),
            child: Text('인식 학습 기록 지우기 (${widget.productLookup.learnedCount}건)'),
          ),
          if (_records.isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: const Text('스캔 목록 전체 삭제'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('취소'),
        ),
      ),
    );
    switch (choice) {
      case 'catalog':
        _openCatalog();
        break;
      case 'saved':
        _showSavedFiles();
        break;
      case 'learned':
        _confirmClearLearned();
        break;
      case 'clear':
        _confirmClearAll();
        break;
    }
  }

  Future<void> _openScanner() async {
    // 스캔 화면은 결과가 나올 때마다 [_addOutcome]을 직접 호출합니다
    // (연속 스캔 모드에서는 화면을 닫지 않고 계속 추가하기 때문).
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ScanScreen(
          camera: widget.camera,
          productLookup: widget.productLookup,
          onAdd: _addOutcome,
          onUndo: _undoAdd,
        ),
      ),
    );
  }

  /// 우리 상품 전체를 둘러보는 화면. 여기서 고른 상품도 스캔 목록에 담을 수 있습니다.
  Future<void> _openCatalog() async {
    // 방금 추가한 상품 알림이 떠 있으면 닫고 들어갑니다.
    ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    final scanned = <String, int>{};
    for (final r in _records) {
      final p = r.product;
      if (p == null) continue;
      final key = p.barcode.toUpperCase();
      scanned[key] = (scanned[key] ?? 0) + r.quantity;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CatalogScreen(
          productLookup: widget.productLookup,
          scannedByBarcode: scanned,
          onAdd: (product) =>
              _addOutcome(ScanOutcome(code: product.barcode, product: product)),
          onUndo: _undoAdd,
        ),
      ),
    );
  }

  /// 스캔 결과를 목록에 넣습니다. 같은 상품이 이미 있으면 새 줄을 만들지 않고
  /// 수량을 1 올린 뒤 맨 위로 올립니다.
  AddResult _addOutcome(ScanOutcome outcome) {
    final incoming = ScanRecord(
      id: _uuid.v4(),
      code: outcome.code,
      scannedAt: DateTime.now(),
      product: outcome.product,
    );
    final index = _records.indexWhere((r) => r.mergeKey == incoming.mergeKey);

    final AddResult result;
    if (index >= 0) {
      final existing = _records.removeAt(index);
      existing.quantity += 1;
      _records.insert(0, existing);
      result = AddResult(record: existing, merged: true);
    } else {
      _records.insert(0, incoming);
      result = AddResult(record: incoming, merged: false);
    }
    if (mounted) setState(() {});
    _persist();
    return result;
  }

  /// 방금 추가한 스캔을 되돌립니다(수량을 올렸던 거면 1 내리고,
  /// 새로 추가한 줄이면 지웁니다).
  void _undoAdd(AddResult result) {
    final record = result.record;
    final index = _records.indexWhere((r) => r.id == record.id);
    if (index < 0) return;
    if (result.merged && record.quantity > 1) {
      record.quantity -= 1;
    } else {
      _records.removeAt(index);
    }
    if (mounted) setState(() {});
    _persist();
  }

  /// 줄을 왼쪽으로 밀어서 지웠을 때(아래 알림에서 되돌릴 수 있음)
  void _deleteWithUndo(ScanRecord record) {
    final index = _records.indexWhere((r) => r.id == record.id);
    if (index < 0) return;
    setState(() => _records.removeAt(index));
    _persist();
    _toast(
      "'${record.displayName}' 삭제했어요",
      actionLabel: '되돌리기',
      onAction: () {
        if (!mounted) return;
        setState(() => _records.insert(index.clamp(0, _records.length), record));
        _persist();
      },
    );
  }

  /// 줄을 눌렀을 때 아래에서 올라오는 메뉴
  Future<void> _showRecordActions(ScanRecord r) async {
    final p = r.product;
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(r.displayName),
        message: Text(
          p != null
              ? '${p.itemNo}${p.variantLabel.isNotEmpty ? ' · ${p.variantLabel}' : ''}  ·  ${r.quantity}개'
              : '${r.code}  ·  상품명 미확인',
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'qty'),
            child: const Text('수량 변경'),
          ),
          if (!r.isMatched)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'link'),
              child: const Text('상품 연결'),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'code'),
            child: const Text('코드 수정'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('삭제'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(ctx),
          child: const Text('취소'),
        ),
      ),
    );
    switch (choice) {
      case 'qty':
        _editQuantity(r);
        break;
      case 'link':
        _attachProduct(r);
        break;
      case 'code':
        _editRecord(r);
        break;
      case 'delete':
        _deleteWithUndo(r);
        break;
    }
  }

  Future<void> _editQuantity(ScanRecord record) async {
    var value = record.quantity;
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('수량', textAlign: TextAlign.center),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                record.displayName,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (record.product != null && record.product!.variantLabel.isNotEmpty)
                Text(
                  record.product!.variantLabel,
                  style: const TextStyle(fontSize: 13, color: AppleColors.secondaryLabel),
                ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: AppleColors.fill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_rounded),
                      color: AppleColors.blue,
                      onPressed: value > 1 ? () => setDialogState(() => value -= 1) : null,
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        '$value',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded),
                      color: AppleColors.blue,
                      onPressed: () => setDialogState(() => value += 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: const Text('완료', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (result != null && result >= 1) {
      setState(() => record.quantity = result);
      _persist();
    }
  }

  Future<void> _editRecord(ScanRecord record) async {
    final result = await _askText(
      title: '코드 수정',
      initial: record.code,
      placeholder: '코드',
      upperCase: true,
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        record.code = result;
        // 코드를 직접 고쳤다면 기존 매칭이 더 이상 맞지 않을 수 있으니
        // 다시 연결합니다(정확히 일치하는 바코드가 없으면 오타/오인식을
        // 감안한 근사 일치까지 시도).
        record.product = widget.productLookup.findBestBarcode(result);
      });
      _persist();
    }
  }

  Future<void> _attachProduct(ScanRecord record) async {
    final selected = await showModalBottomSheet<ProductInfo>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProductSearchSheet(
        lookupService: widget.productLookup,
        initialQuery: record.code,
      ),
    );
    if (selected != null) {
      setState(() => record.product = selected);
      _persist();
    }
  }

  /// 아이폰 스타일 입력 창(글자 하나 입력받기)
  Future<String?> _askText({
    required String title,
    required String initial,
    String placeholder = '',
    String? message,
    bool upperCase = false,
    BuildContext? from,
  }) {
    final controller = TextEditingController(text: initial);
    controller.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showCupertinoDialog<String>(
      context: from ?? context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(message),
            ],
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: controller,
              autofocus: true,
              placeholder: placeholder,
              clearButtonMode: OverlayVisibilityMode.editing,
              textCapitalization:
                  upperCase ? TextCapitalization.characters : TextCapitalization.none,
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  // ---------------- 이름 붙여 저장 / 보관함 ----------------

  String _dateDefaultName() =>
      '${DateFormat('M월 d일').format(DateTime.now())} 스캔';

  /// 저장 창에 미리 넣어둘 이름.
  /// 지난번에 "1번 박스"처럼 숫자가 들어간 이름을 직접 썼다면 숫자를 1 올려서
  /// ("2번 박스") 제안하고, 아니면 오늘 날짜 이름을 제안합니다.
  String _suggestName(String? lastName, bool lastWasDefault) {
    final last = (lastName ?? '').trim();
    if (last.isEmpty || lastWasDefault) return _dateDefaultName();
    final match = RegExp(r'\d+').allMatches(last).toList();
    if (match.isEmpty) return _dateDefaultName();
    final m = match.last;
    final next = int.parse(m.group(0)!) + 1;
    return last.replaceRange(m.start, m.end, '$next');
  }

  Future<void> _saveNamed() async {
    if (_records.isEmpty) {
      _toast('저장할 스캔 기록이 없어요.');
      return;
    }

    String? lastName;
    var lastWasDefault = false;
    var clearAfter = true;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      lastName = prefs.getString(_lastNamePrefKey);
      lastWasDefault = prefs.getBool(_lastNameWasDefaultPrefKey) ?? false;
      clearAfter = prefs.getBool(_clearAfterSavePrefKey) ?? true;
    } catch (_) {}
    if (!mounted) return;

    final suggested = _suggestName(lastName, lastWasDefault);
    final controller = TextEditingController(text: suggested);
    controller.selection = TextSelection(baseOffset: 0, extentOffset: suggested.length);
    final total = _records.fold<int>(0, (sum, r) => sum + r.quantity);

    final result = await showCupertinoDialog<(String, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) => CupertinoAlertDialog(
          title: const Text('이름 붙여 저장'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Text('${_records.length}종 · $total개를 엑셀 파일로 보관함에 저장해요.'),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: controller,
                autofocus: true,
                placeholder: '예: 1번 박스, 10월 입고분',
                clearButtonMode: OverlayVisibilityMode.editing,
                onSubmitted: (v) => Navigator.pop(ctx, (v.trim(), clearAfter)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '저장 후 목록 비우기',
                      textAlign: TextAlign.left,
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  CupertinoSwitch(
                    value: clearAfter,
                    onChanged: (v) => setDialogState(() => clearAfter = v),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, (controller.text.trim(), clearAfter)),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (name, clear) = result;
    if (name.isEmpty || !mounted) return;

    setState(() => _isSaving = true);
    try {
      // 목록은 최신순으로 쌓이므로, 엑셀에는 스캔한 순서(오래된 것부터)로 넣습니다.
      final file = await _exportService.saveNamed(_records.reversed.toList(), name);
      try {
        await prefs?.setString(_lastNamePrefKey, name);
        await prefs?.setBool(_lastNameWasDefaultPrefKey, name == _dateDefaultName());
        await prefs?.setBool(_clearAfterSavePrefKey, clear);
      } catch (_) {}
      if (!mounted) return;
      if (clear) {
        setState(() => _records.clear());
        _persist();
      }
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
      _toast(
        "'${_exportService.displayName(file)}' 저장했어요",
        actionLabel: '보내기',
        onAction: () => _exportService.shareFile(file),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('저장 중 오류가 발생했어요: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool> _confirmDeleteFile(BuildContext from, String name) async {
    final ok = await showCupertinoDialog<bool>(
      context: from,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('파일 삭제'),
        content: Text("'$name' 파일을 보관함에서 지울까요?\n지우면 되돌릴 수 없어요."),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 저장한 엑셀 파일 목록(보관함). 다시 보내거나, 이름을 바꾸거나, 지울 수 있습니다.
  Future<void> _showSavedFiles() async {
    List<File> files;
    try {
      files = await _exportService.listSavedFiles();
    } catch (_) {
      files = [];
    }
    if (!mounted) return;
    final dateFormat = DateFormat('yyyy.M.d HH:mm');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppleColors.background,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> onFileTap(int i) async {
            final f = files[i];
            final name = _exportService.displayName(f);
            final choice = await showCupertinoModalPopup<String>(
              context: context,
              builder: (ctx) => CupertinoActionSheet(
                title: Text(name),
                actions: [
                  CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(ctx, 'share'),
                    child: const Text('보내기 (카톡·메일·드라이브)'),
                  ),
                  CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(ctx, 'rename'),
                    child: const Text('이름 바꾸기'),
                  ),
                  CupertinoActionSheetAction(
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(ctx, 'delete'),
                    child: const Text('삭제'),
                  ),
                ],
                cancelButton: CupertinoActionSheetAction(
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소'),
                ),
              ),
            );
            if (choice == 'share') {
              await _exportService.shareFile(f);
            } else if (choice == 'rename') {
              if (!context.mounted) return;
              final newName = await _askText(
                title: '이름 바꾸기',
                initial: name,
                placeholder: '파일 이름',
                from: context,
              );
              if (newName == null || newName.isEmpty) return;
              try {
                final renamed = await _exportService.rename(f, newName);
                setSheetState(() => files[i] = renamed);
              } catch (_) {}
            } else if (choice == 'delete') {
              if (!context.mounted) return;
              final ok = await _confirmDeleteFile(context, name);
              if (!ok) return;
              try {
                f.deleteSync();
              } catch (_) {}
              setSheetState(() => files.removeAt(i));
            }
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 2),
                    child: Text(
                      '보관함',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      files.isEmpty
                          ? '"이름 붙여 저장"한 엑셀 파일이 여기에 모여요.'
                          : '파일 ${files.length}개 · 눌러서 보내기, 이름 바꾸기, 삭제',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppleColors.secondaryLabel,
                      ),
                    ),
                  ),
                  if (files.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 24, 20, 40),
                      child: Center(
                        child: Icon(
                          Icons.folder_open_rounded,
                          size: 56,
                          color: AppleColors.chevron,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: files.length,
                        itemBuilder: (context, i) {
                          final f = files[i];
                          final name = _exportService.displayName(f);
                          String info;
                          try {
                            final kb = (f.lengthSync() / 1024).ceil();
                            info = '${dateFormat.format(f.lastModifiedSync())} · ${kb}KB';
                          } catch (_) {
                            info = '';
                          }
                          return _GroupedRow(
                            isFirst: i == 0,
                            isLast: i == files.length - 1,
                            dividerIndent: 60,
                            onTap: () => onFileTap(i),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: AppleColors.green,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.table_chart_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (info.isNotEmpty)
                                        Text(
                                          info,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: AppleColors.secondaryLabel,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.ios_share_rounded),
                                  color: AppleColors.blue,
                                  tooltip: '보내기',
                                  onPressed: () => _exportService.shareFile(f),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- 화면 ----------------

  Widget _buildSummary(int kinds, int total) {
    Widget tile(String label, String value, IconData icon, Color color) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: AppleColors.card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppleColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          tile('상품 종류', '$kinds종', Icons.checkroom_rounded, AppleColors.blue),
          const SizedBox(width: 12),
          tile('총 수량', '$total개', Icons.inventory_2_rounded, AppleColors.orange),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String trailing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 6),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, color: AppleColors.secondaryLabel),
          ),
          const Spacer(),
          Text(
            trailing,
            style: const TextStyle(fontSize: 13, color: AppleColors.secondaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(ScanRecord r, int index, int count, DateFormat dateFormat) {
    final p = r.product;
    final isFirst = index == 0;
    final isLast = index == count - 1;
    final number = count - index;
    final radius = BorderRadius.vertical(
      top: Radius.circular(isFirst ? 12 : 0),
      bottom: Radius.circular(isLast ? 12 : 0),
    );
    final subtitle = p != null
        ? '${p.itemNo}${p.variantLabel.isNotEmpty ? ' · ${p.variantLabel}' : ''}'
        : '${r.code} · 상품명 미확인 (눌러서 연결)';

    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(color: AppleColors.red, borderRadius: radius),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Text(
          '삭제',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      onDismissed: (_) => _deleteWithUndo(r),
      child: _GroupedRow(
        isFirst: isFirst,
        isLast: isLast,
        dividerIndent: 58,
        onTap: () => _showRecordActions(r),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: r.isMatched ? AppleColors.fill : const Color(0x26FF9500),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: r.isMatched ? AppleColors.secondaryLabel : AppleColors.orange,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: r.isMatched ? AppleColors.secondaryLabel : AppleColors.orange,
                    ),
                  ),
                  Text(
                    dateFormat.format(r.scannedAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppleColors.chevron,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: r.quantity > 1 ? const Color(0x1F007AFF) : AppleColors.fill,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${r.quantity}개',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: r.quantity > 1 ? AppleColors.blue : AppleColors.label,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right_rounded, color: AppleColors.chevron),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(40, 40, 40, 120),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.document_scanner_outlined, size: 72, color: AppleColors.chevron),
          SizedBox(height: 16),
          Text(
            '아직 스캔한 상품이 없어요',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4),
          ),
          SizedBox(height: 8),
          Text(
            '아래 "스캔하기"를 눌러 케어라벨을 비춰보세요.\n'
            '같은 상품은 한 줄로 합쳐 수량이 올라가고,\n'
            '다 찍으면 "저장"으로 이름을 붙여 보관할 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, height: 1.4, color: AppleColors.secondaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF2F2F2F7),
        border: Border(top: BorderSide(color: Color(0x33000000), width: 0.3)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              if (_records.isNotEmpty) ...[
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _saveNamed,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppleColors.card,
                      foregroundColor: AppleColors.blue,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: _isSaving
                        ? const CupertinoActivityIndicator()
                        : const Icon(Icons.save_alt_rounded),
                    label: const Text('저장'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _openScanner,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: const Text('스캔하기'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('M/d HH:mm');
    final totalQuantity = _records.fold<int>(0, (sum, r) => sum + r.quantity);

    final slivers = <Widget>[
      SliverAppBar.large(
        title: const Text('스캔 목록'),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_rounded),
            tooltip: '상품 목록',
            onPressed: _openCatalog,
          ),
          IconButton(
            icon: const Icon(Icons.folder_rounded),
            tooltip: '보관함',
            onPressed: _showSavedFiles,
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded),
            tooltip: '더보기',
            onPressed: _showMoreMenu,
          ),
          const SizedBox(width: 4),
        ],
      ),
    ];

    if (!_isHistoryLoaded) {
      slivers.add(const SliverFillRemaining(
        child: Center(child: CupertinoActivityIndicator(radius: 12)),
      ));
    } else if (_records.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmpty(),
      ));
    } else {
      slivers
        ..add(SliverToBoxAdapter(
          child: _buildSummary(_records.length, totalQuantity),
        ))
        ..add(SliverToBoxAdapter(
          child: _buildSectionHeader('스캔한 상품', '왼쪽으로 밀면 삭제'),
        ))
        ..add(SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: _records.length,
            itemBuilder: (context, index) =>
                _buildItem(_records[index], index, _records.length, dateFormat),
          ),
        ))
        ..add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    }

    return Scaffold(
      body: CustomScrollView(slivers: slivers),
      bottomNavigationBar: _buildBottomBar(),
    );
  }
}

/// 둥근 흰 목록(그룹)의 한 줄. 첫 줄은 위 모서리, 마지막 줄은 아래 모서리만
/// 둥글고, 줄 사이에는 왼쪽을 조금 띄운 얇은 구분선이 들어갑니다.
class _GroupedRow extends StatelessWidget {
  final bool isFirst;
  final bool isLast;
  final double dividerIndent;
  final VoidCallback? onTap;
  final Widget child;

  const _GroupedRow({
    required this.isFirst,
    required this.isLast,
    required this.child,
    this.dividerIndent = 16,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: Radius.circular(isFirst ? 12 : 0),
      bottom: Radius.circular(isLast ? 12 : 0),
    );
    return Material(
      color: AppleColors.card,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: child,
            ),
            if (!isLast)
              Container(
                margin: EdgeInsets.only(left: dividerIndent),
                height: 0.5,
                color: AppleColors.separator,
              ),
          ],
        ),
      ),
    );
  }
}
