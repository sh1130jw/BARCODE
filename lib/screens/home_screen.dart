import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../models/scan_record.dart';
import '../services/excel_export_service.dart';
import '../services/product_lookup_service.dart';
import '../services/scan_history_service.dart';
import '../widgets/product_search_sheet.dart';
import 'scan_screen.dart';

/// 스캔된 코드/상품 목록을 누적해서 보여주고,
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

class _HomeScreenState extends State<HomeScreen> {
  final List<ScanRecord> _records = [];
  final Uuid _uuid = const Uuid();
  final ExcelExportService _exportService = ExcelExportService();
  final ScanHistoryService _historyService = ScanHistoryService();
  bool _isExporting = false;
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

  Future<void> _confirmClearAll() async {
    if (_records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('전체 삭제'),
        content: Text('저장된 스캔 기록 ${_records.length}건을 모두 삭제할까요?\n(엑셀로 내보내지 않았다면 복구할 수 없습니다)'),
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

  Future<void> _openScanner() async {
    final outcome = await Navigator.push<ScanOutcome>(
      context,
      MaterialPageRoute<ScanOutcome>(
        builder: (_) => ScanScreen(
          camera: widget.camera,
          productLookup: widget.productLookup,
        ),
      ),
    );
    if (outcome != null) {
      setState(() {
        _records.insert(
          0,
          ScanRecord(
            id: _uuid.v4(),
            code: outcome.code,
            scannedAt: DateTime.now(),
            product: outcome.product,
          ),
        );
      });
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
        // 정확히 일치하는 바코드가 있는 경우에만 다시 연결합니다.
        record.product = widget.productLookup.findExactBarcode(result);
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

  Future<void> _export() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 스캔 기록이 없습니다.')),
      );
      return;
    }
    setState(() => _isExporting = true);
    try {
      // 리스트는 최신순(내림차순)으로 쌓이므로, 엑셀에는 오래된 순으로 내보냅니다.
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

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MM/dd HH:mm:ss');
    return Scaffold(
      appBar: AppBar(
        title: Text('케어라벨 스캔 (${_records.length}건)'),
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
        ],
      ),
      body: !_isHistoryLoaded
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '아직 스캔한 코드가 없습니다.\n오른쪽 아래 버튼을 눌러 케어라벨을 촬영하세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final r = _records[index];
                final p = r.product;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: r.isMatched ? null : Colors.orange.shade100,
                    child: Text('${_records.length - index}'),
                  ),
                  title: Text(
                    r.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
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
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.camera_alt),
        label: const Text('스캔'),
      ),
    );
  }
}
