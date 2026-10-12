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
import 'scan_screen.dart';

/// 스캔된 코드/상품 목록을 박스별로 보여주고,
/// 엑셀로 내보내기(공유)할 수 있는 홈 화면.
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

/// 목록 화면의 한 줄: 박스 제목 줄이거나 상품 줄입니다.
class _ListRow {
  final String? boxHeader; // 박스 제목 줄이면 박스 값('' = 미지정)
  final ScanRecord? record;
  final int number; // 박스 안에서의 번호

  const _ListRow.header(String box)
      : boxHeader = box,
        record = null,
        number = 0;

  const _ListRow.item(ScanRecord this.record, this.number) : boxHeader = null;
}

class _HomeScreenState extends State<HomeScreen> {
  static const _currentBoxPrefKey = 'current_box';

  final List<ScanRecord> _records = [];
  final Uuid _uuid = const Uuid();
  final ExcelExportService _exportService = ExcelExportService();
  final ScanHistoryService _historyService = ScanHistoryService();

  /// 지금 담고 있는 박스. 스캔하는 상품마다 이 박스가 붙습니다.
  /// 스캔 화면에서도 같이 보이고 바꿀 수 있도록 ValueNotifier로 둡니다.
  final ValueNotifier<String> _currentBox = ValueNotifier<String>('1');

  bool _isExporting = false;
  bool _isHistoryLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadCurrentBox();
  }

  @override
  void dispose() {
    _currentBox.dispose();
    super.dispose();
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

  // ---------------- 박스 ----------------

  Future<void> _loadCurrentBox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_currentBoxPrefKey);
      if (saved != null && saved.trim().isNotEmpty && mounted) {
        _currentBox.value = saved.trim();
      }
    } catch (_) {}
  }

  Future<void> _setCurrentBox(String box) async {
    final value = box.trim();
    if (value.isEmpty) return;
    _currentBox.value = value;
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_currentBoxPrefKey, value);
    } catch (_) {}
  }

  /// 다음 박스로 넘어갑니다. 숫자면 1 올리고(3 → 4), 이름이면 새 이름을 묻습니다.
  void _nextBox() {
    final number = int.tryParse(_currentBox.value.trim());
    if (number != null) {
      _setCurrentBox('${number + 1}');
    } else {
      _editCurrentBox();
    }
  }

  void _previousBox() {
    final number = int.tryParse(_currentBox.value.trim());
    if (number != null && number > 1) _setCurrentBox('${number - 1}');
  }

  Future<void> _editCurrentBox() async {
    final controller = TextEditingController(text: _currentBox.value);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('박스 번호'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '박스 번호 또는 이름',
            hintText: '예: 3  또는  A-2',
          ),
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
    if (result != null && result.isNotEmpty) await _setCurrentBox(result);
  }

  // ---------------- 목록 ----------------

  Future<void> _confirmClearAll() async {
    if (_records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('전체 삭제'),
        content: Text(
          '저장된 스캔 기록 ${_records.length}건을 모두 삭제할까요?\n'
          '박스 번호도 1번으로 돌아갑니다.\n'
          '(엑셀로 내보내지 않았다면 복구할 수 없습니다)',
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
      await _setCurrentBox('1');
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
          currentBox: _currentBox,
          onNextBox: _nextBox,
        ),
      ),
    );
  }

  /// 스캔 결과를 지금 박스에 넣습니다. 같은 박스에 같은 상품이 이미 있으면
  /// 새 줄을 만들지 않고 수량을 1 올린 뒤 맨 위로 올립니다.
  AddResult _addOutcome(ScanOutcome outcome) {
    final incoming = ScanRecord(
      id: _uuid.v4(),
      code: outcome.code,
      scannedAt: DateTime.now(),
      product: outcome.product,
      box: _currentBox.value,
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

  /// 수량과 박스를 고칩니다. 다른 박스로 옮겼는데 그 박스에 같은 상품이
  /// 이미 있으면 한 줄로 합칩니다.
  Future<void> _editRecordDetails(ScanRecord record) async {
    var value = record.quantity;
    final boxController = TextEditingController(text: record.box ?? '');
    final result = await showDialog<(int, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('수량 · 박스 변경'),
          content: SingleChildScrollView(
            child: Column(
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
                const SizedBox(height: 16),
                TextField(
                  controller: boxController,
                  decoration: const InputDecoration(
                    labelText: '박스',
                    hintText: '예: 3  또는  A-2',
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                  ),
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
                  Navigator.pop(dialogContext, (value, boxController.text.trim())),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final (newQuantity, newBoxText) = result;
    final String? newBox = newBoxText.isEmpty ? null : newBoxText;

    setState(() {
      record.quantity = newQuantity;
      if ((record.box ?? '') != (newBox ?? '')) {
        record.box = newBox;
        // 옮긴 박스에 같은 상품이 이미 있으면 그 줄에 합칩니다.
        final other = _records.indexWhere(
          (r) => r.id != record.id && r.mergeKey == record.mergeKey,
        );
        if (other >= 0) {
          _records[other].quantity += record.quantity;
          _records.removeWhere((r) => r.id == record.id);
        }
      }
    });
    _persist();
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

  // ---------------- 엑셀 / 보관함 ----------------

  Future<void> _export() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 스캔 기록이 없습니다.')),
      );
      return;
    }
    setState(() => _isExporting = true);
    try {
      // 리스트는 최신순(내림차순)으로 쌓이므로, 엑셀에는 오래된 순으로 내보냅니다
      // (엑셀 안에서는 박스 순서대로 다시 정렬됩니다).
      final ordered = _records.reversed.toList();
      await _exportService.exportAndShare(ordered);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('내보내기 중 오류가 발생했습니다: $e')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 지금까지 내보낸 엑셀 파일 목록(보관함). 다시 보내거나 지울 수 있습니다.
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '보관함 (내보낸 엑셀 파일)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '엑셀로 내보낼 때마다 여기에 자동으로 남아요. 공유 버튼으로 카톡·드라이브·내 파일에 다시 보낼 수 있어요.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                if (files.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('아직 내보낸 파일이 없어요.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: files.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final f = files[i];
                        final name = f.path.split('/').last;
                        String info;
                        try {
                          final kb = (f.lengthSync() / 1024).ceil();
                          info = '${dateFormat.format(f.lastModifiedSync())} · ${kb}KB';
                        } catch (_) {
                          info = '';
                        }
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          subtitle: Text(info),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.ios_share),
                                tooltip: '보내기',
                                onPressed: () => _exportService.shareFile(f),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '삭제',
                                onPressed: () {
                                  try {
                                    f.deleteSync();
                                  } catch (_) {}
                                  setSheetState(() => files.removeAt(i));
                                },
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

  /// 박스별로 묶은 목록(최근 박스가 위로).
  List<_ListRow> _buildRows() {
    final groups = <String, List<ScanRecord>>{};
    for (final r in _records) {
      groups.putIfAbsent((r.box ?? '').trim(), () => []).add(r);
    }
    // 최근 박스(번호가 큰 박스)가 위로, 미지정 박스는 항상 맨 아래로
    final boxes = groups.keys.toList();
    boxes.sort((a, b) {
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
      return compareBoxes(b, a);
    });
    final rows = <_ListRow>[];
    for (final box in boxes) {
      final items = groups[box]!;
      rows.add(_ListRow.header(box));
      for (var i = 0; i < items.length; i++) {
        rows.add(_ListRow.item(items[i], items.length - i));
      }
    }
    return rows;
  }

  Widget _buildBoxBar() {
    final current = _currentBox.value;
    final inBox = _records.where((r) => (r.box ?? '').trim() == current.trim());
    final count = inBox.fold<int>(0, (sum, r) => sum + r.quantity);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Row(
          children: [
            const Icon(Icons.inventory_2_outlined, size: 20),
            const SizedBox(width: 8),
            const Text('지금 담는 박스', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _editCurrentBox,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  '${boxLabel(current)} · $count개',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: '이전 박스',
              onPressed: int.tryParse(current) != null && int.parse(current) > 1
                  ? _previousBox
                  : null,
            ),
            FilledButton.tonalIcon(
              onPressed: _nextBox,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('다음 박스'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBoxHeader(String box) {
    final items = _records.where((r) => (r.box ?? '').trim() == box);
    final kinds = items.length;
    final total = items.fold<int>(0, (sum, r) => sum + r.quantity);
    final isCurrent = box.isNotEmpty && box == _currentBox.value.trim();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Text(
            boxLabel(box),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '지금 담는 중',
                style: TextStyle(fontSize: 11, color: scheme.onPrimary),
              ),
            ),
          ],
          const Spacer(),
          Text('$kinds종 · $total개'),
        ],
      ),
    );
  }

  Widget _buildItem(ScanRecord r, int number, DateFormat dateFormat) {
    final p = r.product;
    return ListTile(
      onTap: () => _editRecordDetails(r),
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
    final rows = _buildRows();
    return Scaffold(
      appBar: AppBar(
        title: Text('스캔 ${_records.length}종 · $totalQuantity개'),
        actions: [
          IconButton(
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            tooltip: '엑셀로 내보내기',
            onPressed: _isExporting ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '전체 삭제',
            onPressed: _records.isEmpty ? null : _confirmClearAll,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'saved_files') _showSavedFiles();
              if (value == 'clear_learned') _confirmClearLearned();
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: 'saved_files',
                child: Text('보관함 (내보낸 엑셀 파일)'),
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _buildBoxBar(),
        ),
      ),
      body: !_isHistoryLoaded
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '아직 스캔한 코드가 없습니다.\n'
                      '위에서 박스 번호를 확인하고, 오른쪽 아래 버튼을 눌러 케어라벨을 찍으세요.\n\n'
                      '박스를 다 채우면 "다음 박스"를 누르세요. 찍는 상품마다 박스 번호가 붙고,\n'
                      '엑셀로 내보내면 박스별로 정리돼요.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final header = row.boxHeader;
                    if (header != null) return _buildBoxHeader(header);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildItem(row.record!, row.number, dateFormat),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.camera_alt),
        label: ValueListenableBuilder<String>(
          valueListenable: _currentBox,
          builder: (_, box, __) => Text('${boxLabel(box)} 스캔'),
        ),
      ),
    );
  }
}
