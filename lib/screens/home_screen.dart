import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

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

  // ---------------- 목록 ----------------

  Future<void> _confirmClearAll() async {
    if (_records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('전체 삭제'),
        content: Text(
          '지금 스캔 목록 ${_records.length}건을 모두 삭제할까요?\n'
          '(보관함에 저장하지 않았다면 복구할 수 없습니다)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _records.clear());
      _persist();
    }
  }

  /// 틀리게 읽힌 라벨을 바로잡아준 기록(자동으로 쌓임)을 지웁니다.
  /// 잘못 고른 상품이 기억돼서 계속 엉뚱하게 찾을 때 사용합니다.
  Future<void> _confirmClearLearned() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('인식 학습 기록 지우기'),
        content: const Text(
          '틀리게 읽힌 라벨을 바로잡아준 기록을 모두 지울까요?\n'
          '스캔 목록은 그대로 남습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.productLookup.clearLearned();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('인식 학습 기록을 지웠어요.')),
      );
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

  Future<void> _editQuantity(ScanRecord record) async {
    var value = record.quantity;
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('수량 변경'),
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
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    icon: const Icon(Icons.remove),
                    onPressed: value > 1 ? () => setDialogState(() => value -= 1) : null,
                  ),
                  SizedBox(
                    width: 72,
                    child: Text(
                      '$value',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.add),
                    onPressed: () => setDialogState(() => value += 1),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: const Text('저장'),
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

  void _deleteRecord(String id) {
    setState(() {
      _records.removeWhere((r) => r.id == id);
    });
    _persist();
  }

  Future<void> _editRecord(ScanRecord record) async {
    final controller = TextEditingController(text: record.code);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('코드 수정'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장할 스캔 기록이 없습니다.')),
      );
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

    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('이름 붙여 저장'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '지금 스캔 목록(${_records.length}종 · $total개)을 엑셀 파일로 보관함에 저장해요.',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '파일 이름',
                    hintText: '예: 1번 박스, 10월 입고분',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) =>
                      Navigator.pop(dialogContext, (v.trim(), clearAfter)),
                ),
                const SizedBox(height: 4),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: clearAfter,
                  title: const Text('저장한 뒤 스캔 목록 비우기'),
                  subtitle: const Text('다음 목록을 새로 시작할 때 켜두세요'),
                  onChanged: (v) => setDialogState(() => clearAfter = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, (controller.text.trim(), clearAfter)),
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
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentMaterialBanner();
      messenger.showSnackBar(
        SnackBar(
          content: Text("'${_exportService.displayName(file)}' 저장했어요 (보관함)"),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '보내기',
            onPressed: () => _exportService.shareFile(file),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 중 오류가 발생했습니다: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<String?> _askName(BuildContext context, String title, String initial) async {
    final controller = TextEditingController(text: initial);
    controller.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '파일 이름'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDeleteFile(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text("'$name' 파일을 보관함에서 지울까요?\n지우면 되돌릴 수 없어요."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
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
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '보관함 (저장한 파일 ${files.length}개)',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '"이름 붙여 저장"한 엑셀 파일이 여기에 남아요. 보내기 버튼으로 카톡·드라이브·메일로 보낼 수 있어요.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (files.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('아직 저장한 파일이 없어요.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: files.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
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
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(info),
                          onTap: () => _exportService.shareFile(f),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.ios_share),
                                tooltip: '보내기',
                                onPressed: () => _exportService.shareFile(f),
                              ),
                              PopupMenuButton<String>(
                                tooltip: '더보기',
                                onSelected: (value) async {
                                  if (value == 'rename') {
                                    final newName =
                                        await _askName(context, '이름 바꾸기', name);
                                    if (newName == null || newName.isEmpty) return;
                                    try {
                                      final renamed =
                                          await _exportService.rename(f, newName);
                                      setSheetState(() => files[i] = renamed);
                                    } catch (_) {}
                                  } else if (value == 'delete') {
                                    final ok = await _confirmDeleteFile(context, name);
                                    if (!ok) return;
                                    try {
                                      f.deleteSync();
                                    } catch (_) {}
                                    setSheetState(() => files.removeAt(i));
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Text('이름 바꾸기'),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('삭제'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 화면 ----------------

  Widget _buildItem(ScanRecord r, int number, DateFormat dateFormat) {
    final p = r.product;
    return ListTile(
      onTap: () => _editQuantity(r),
      leading: CircleAvatar(
        backgroundColor: r.isMatched ? null : Colors.orange.shade100,
        child: Text('$number'),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              r.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: r.quantity > 1
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${r.quantity}개',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        p != null
            ? '${p.itemNo}${p.variantLabel.isNotEmpty ? ' · ${p.variantLabel}' : ''}\n${r.code}  ·  ${dateFormat.format(r.scannedAt)}'
            : '${r.code}  ·  ${dateFormat.format(r.scannedAt)}  ·  상품명 미확인',
      ),
      isThreeLine: p != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!r.isMatched)
            IconButton(
              icon: const Icon(Icons.link),
              tooltip: '상품 연결',
              onPressed: () => _attachProduct(r),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '코드 수정',
            onPressed: () => _editRecord(r),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '삭제',
            onPressed: () => _deleteRecord(r.id),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MM/dd HH:mm:ss');
    final totalQuantity = _records.fold<int>(0, (sum, r) => sum + r.quantity);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '스캔 ${_records.length}종 · $totalQuantity개',
          style: const TextStyle(fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '상품 목록',
            onPressed: _openCatalog,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
            tooltip: '이름 붙여 저장',
            onPressed: _isSaving ? null : _saveNamed,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: '보관함',
            onPressed: _showSavedFiles,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'catalog') _openCatalog();
              if (value == 'save') _saveNamed();
              if (value == 'saved_files') _showSavedFiles();
              if (value == 'clear_all') _confirmClearAll();
              if (value == 'clear_learned') _confirmClearLearned();
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: 'catalog',
                child: Text('상품 목록 보기'),
              ),
              const PopupMenuItem<String>(
                value: 'save',
                child: Text('이름 붙여 저장'),
              ),
              const PopupMenuItem<String>(
                value: 'saved_files',
                child: Text('보관함 (저장한 파일)'),
              ),
              PopupMenuItem<String>(
                value: 'clear_all',
                enabled: _records.isNotEmpty,
                child: const Text('스캔 목록 전체 삭제'),
              ),
              PopupMenuItem<String>(
                value: 'clear_learned',
                child: Text(
                  '인식 학습 기록 지우기 (${widget.productLookup.learnedCount}건)',
                ),
              ),
            ],
          ),
        ],
      ),
      body: !_isHistoryLoaded
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '아직 스캔한 코드가 없습니다.\n'
                      '오른쪽 아래 버튼을 눌러 케어라벨을 촬영하세요.\n\n'
                      '같은 상품을 여러 번 찍으면 한 줄로 합쳐 수량이 올라가요.\n'
                      '다 찍었으면 위의 저장 버튼으로 이름을 붙여(예: 1번 박스)\n'
                      '엑셀 파일로 보관함에 저장하세요.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) => _buildItem(
                    _records[index],
                    _records.length - index,
                    dateFormat,
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.camera_alt),
        label: const Text('스캔'),
      ),
    );
  }
}
