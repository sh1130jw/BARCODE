import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../services/ocr_service.dart';
import '../services/product_lookup_service.dart';
import '../widgets/product_search_sheet.dart';

/// 카메라로 케어라벨을 촬영하고, OCR로 코드를 인식한 뒤
/// 상품 DB와 자동 매칭하거나 사용자가 직접 확인/선택하는 화면.
///
/// 확정된 결과는 [onAdd]로 바로 목록에 넣습니다.
/// - 일반 모드: 한 건 추가하면 화면을 닫고 목록으로 돌아갑니다.
/// - 연속 스캔 모드: 화면을 닫지 않고 계속 찍을 수 있고, 바코드가 정확히
///   일치하면 확인 창 없이 진동과 함께 바로 추가됩니다.
class ScanScreen extends StatefulWidget {
  final CameraDescription camera;
  final ProductLookupService productLookup;
  final AddResult Function(ScanOutcome outcome) onAdd;
  final void Function(AddResult result) onUndo;

  const ScanScreen({
    super.key,
    required this.camera,
    required this.productLookup,
    required this.onAdd,
    required this.onUndo,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const _continuousPrefKey = 'continuous_scan_mode';

  late final CameraController _controller;
  late final Future<void> _initializeControllerFuture;
  final OcrService _ocrService = OcrService();
  bool _isProcessing = false;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;

  /// 연속 스캔 모드 여부(마지막 설정을 기억합니다).
  bool _continuousMode = false;

  /// 이번에 스캔 화면을 연 뒤로 추가한 개수(연속 스캔 모드 표시용).
  int _sessionCount = 0;

  /// 연속 스캔 모드에서 방금 추가한 상품(화면 아래 알림 + 되돌리기용).
  AddResult? _lastAdded;
  Timer? _lastAddedTimer;

  @override
  void initState() {
    super.initState();
    _loadContinuousMode();
    _controller = CameraController(
      widget.camera,
      // 케어라벨 글자가 작기 때문에 해상도를 높여서 촬영합니다.
      // (너무 낮으면 초점/조명이 좋아도 작은 글자의 OCR 정확도가 떨어집니다.)
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller.initialize().then((_) async {
      if (!mounted) return;
      // 라벨처럼 가까운 거리의 작은 글자를 찍을 때는 자동 초점/노출을
      // 화면 중앙(코드가 위치하는 곳)에 맞추는 것이 인식률에 큰 영향을 줍니다.
      try {
        await _controller.setFocusMode(FocusMode.auto);
        await _controller.setExposureMode(ExposureMode.auto);
      } catch (_) {
        // 일부 기기/카메라는 지원하지 않을 수 있으므로 무시합니다.
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _ocrService.dispose();
    _focusIndicatorTimer?.cancel();
    _lastAddedTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadContinuousMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_continuousPrefKey) ?? false;
      if (mounted) setState(() => _continuousMode = saved);
    } catch (_) {
      // 설정을 못 읽어도 기본값(일반 모드)으로 동작합니다.
    }
  }

  Future<void> _setContinuousMode(bool value) async {
    setState(() => _continuousMode = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_continuousPrefKey, value);
    } catch (_) {}
  }

  /// 화면을 탭한 위치에 초점/노출을 맞춥니다. 라벨의 작은 글자를 찍을 때
  /// 자동 초점이 다른 곳(배경, 손가락 등)에 맞아버리는 경우가 많은데,
  /// 코드 부분을 직접 탭해서 초점을 맞추면 인식률이 크게 좋아집니다.
  Future<void> _onTapToFocus(TapUpDetails details, BoxConstraints constraints) async {
    final Offset relative = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    setState(() => _focusPoint = details.localPosition);
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    try {
      await _controller.setFocusPoint(relative);
      await _controller.setExposurePoint(relative);
    } catch (_) {
      // 일부 기기/카메라는 지원하지 않을 수 있으므로 무시합니다.
    }
  }

  /// 확정된 스캔 결과를 목록에 넣습니다.
  void _finish(String code, ProductInfo? product) {
    if (!mounted) return;
    final result = widget.onAdd(ScanOutcome(code: code, product: product));
    HapticFeedback.mediumImpact();

    if (_continuousMode) {
      // 화면을 닫지 않고, 아래쪽에 방금 추가한 상품을 잠깐 보여줍니다.
      _lastAddedTimer?.cancel();
      setState(() {
        _sessionCount += 1;
        _lastAdded = result;
      });
      _lastAddedTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _lastAdded = null);
      });
      return;
    }

    // 일반 모드: 목록 화면으로 돌아가면서 알림을 띄웁니다
    // (알림은 화면이 바뀌어도 목록 화면에 그대로 이어서 표시됩니다).
    final onUndo = widget.onUndo;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(_addedMessage(result)),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '되돌리기',
          onPressed: () => onUndo(result),
        ),
      ),
    );
    Navigator.pop(context);
  }

  String _addedMessage(AddResult result) {
    final record = result.record;
    final variant = record.product?.variantLabel ?? '';
    final name = variant.isEmpty
        ? record.displayName
        : '${record.displayName} ($variant)';
    return result.merged
        ? '$name · 이미 있던 상품이라 수량 ${record.quantity}개'
        : '$name · 목록에 추가';
  }

  void _undoLastAdded() {
    final result = _lastAdded;
    if (result == null) return;
    widget.onUndo(result);
    _lastAddedTimer?.cancel();
    setState(() {
      _lastAdded = null;
      if (_sessionCount > 0) _sessionCount -= 1;
    });
  }

  Future<void> _captureAndRecognize() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await _initializeControllerFuture;
      final XFile picture = await _controller.takePicture();
      final result = await _ocrService.recognize(File(picture.path));

      if (!mounted) return;

      final autoMatch = widget.productLookup.attemptAutoMatch(result.tokens);

      if (autoMatch.isMatched) {
        if (_continuousMode && autoMatch.confidence == MatchConfidence.exact) {
          // 연속 스캔 모드에서 바코드가 정확히 일치하면 확인 없이 바로 추가.
          // (근사 일치나 조합 인식처럼 틀릴 여지가 있는 경우는 확인 창을 띄웁니다.)
          _finish(autoMatch.matchedFrom, autoMatch.product);
        } else {
          _showMatchConfirmDialog(autoMatch, result);
        }
      } else if (autoMatch.isAmbiguous) {
        // 품번은 정확히 인식됐지만 색상/사이즈까지는 특정하지 못한 경우:
        // 바로 옵션 선택 화면을 띄워줍니다.
        _openProductSearch(directItemNo: autoMatch.matchedFrom, fallback: result);
      } else {
        _showCandidatePicker(result);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('인식 중 오류가 발생했습니다: $e')),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  String _confidenceLabel(MatchConfidence c) {
    switch (c) {
      case MatchConfidence.exact:
        return '바코드 일치';
      case MatchConfidence.fuzzy:
        return '근사 일치 (오인식 보정)';
      case MatchConfidence.components:
        return '품번+색상+사이즈 조합 인식';
      case MatchConfidence.none:
        return '';
    }
  }

  void _showMatchConfirmDialog(MatchResult match, OcrResult ocrResult) {
    final product = match.product!;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('상품을 찾았어요'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('품번: ${product.itemNo}'),
              if (product.hasColor) Text('색상: ${product.color}'),
              if (product.sizeLabel.isNotEmpty) Text('사이즈: ${product.sizeLabel}'),
              if (product.price != null) Text('가격: ${product.price}원'),
              const SizedBox(height: 8),
              Text(
                '인식: ${match.matchedFrom}  (${_confidenceLabel(match.confidence)})',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _showCandidatePicker(ocrResult);
              },
              child: const Text('아니에요, 직접 선택'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _finish(match.matchedFrom, product);
              },
              child: const Text('목록에 추가'),
            ),
          ],
        );
      },
    );
  }

  void _showCandidatePicker(OcrResult result) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '자동으로 상품을 찾지 못했어요',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '인식된 코드 후보를 고르거나, 상품을 직접 검색해서 연결하세요.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                if (result.candidates.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: result.candidates.map((c) {
                      return ActionChip(
                        label: Text(c),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _onCandidateTapped(c, result.fullText);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _openProductSearch();
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('상품 직접 검색 (품번/품명)'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _showManualEntryDialog(initialText: '', fullText: result.fullText);
                  },
                  child: const Text('코드만 직접 입력'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onCandidateTapped(String candidate, String fullText) {
    final match = widget.productLookup.attemptAutoMatch([candidate]);
    if (match.isMatched) {
      _showMatchConfirmDialogSimple(match);
    } else {
      _showManualEntryDialog(initialText: candidate, fullText: fullText);
    }
  }

  void _showMatchConfirmDialogSimple(MatchResult match) {
    // 후보 칩 하나로 재시도했을 때 쓰는 간단 버전(재귀적으로 후보 목록을
    // 다시 열지 않고, 취소 시 코드 수정 다이얼로그로 보냅니다).
    final product = match.product!;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('상품을 찾았어요'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('품번: ${product.itemNo}'),
              if (product.hasColor) Text('색상: ${product.color}'),
              if (product.sizeLabel.isNotEmpty) Text('사이즈: ${product.sizeLabel}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _showManualEntryDialog(initialText: match.matchedFrom, fullText: '');
              },
              child: const Text('아니에요'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _finish(match.matchedFrom, product);
              },
              child: const Text('목록에 추가'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openProductSearch({
    String initialQuery = '',
    String? directItemNo,
    OcrResult? fallback,
  }) async {
    final selected = await showModalBottomSheet<ProductInfo>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProductSearchSheet(
        lookupService: widget.productLookup,
        initialQuery: initialQuery,
        directItemNo: directItemNo,
      ),
    );
    if (selected != null) {
      _finish(selected.barcode, selected);
    } else if (fallback != null && mounted) {
      // 옵션 선택을 취소한 경우, 기존 OCR 결과로 다시 후보를 보여줍니다.
      _showCandidatePicker(fallback);
    }
  }

  void _showManualEntryDialog({
    required String initialText,
    required String fullText,
  }) {
    final controller = TextEditingController(text: initialText);
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('코드 확인/수정'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: '코드'),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _openProductSearch(initialQuery: controller.text.trim());
                },
                icon: const Icon(Icons.search, size: 18),
                label: const Text('상품에서 검색하기'),
              ),
              if (fullText.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    '인식된 전체 텍스트 보기',
                    style: TextStyle(fontSize: 13),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(fullText, style: const TextStyle(fontSize: 12)),
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
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(dialogContext);
                // 마지막으로 한 번 더 바코드를 확인합니다(정확히 일치하는
                // 것이 없으면, 오타/오인식을 감안한 근사 일치까지 시도).
                final product = widget.productLookup.findBestBarcode(value);
                _finish(value, product);
              },
              child: const Text('목록에 추가'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('케어라벨 스캔'),
        actions: [
          const Center(child: Text('연속', style: TextStyle(fontSize: 13))),
          Switch(
            value: _continuousMode,
            onChanged: _setContinuousMode,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '상품 직접 검색',
            onPressed: () => _openProductSearch(),
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('카메라를 초기화할 수 없습니다: ${snapshot.error}'),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _onTapToFocus(details, constraints),
                    child: CameraPreview(_controller),
                  );
                },
              ),
              if (_focusPoint != null)
                Positioned(
                  left: _focusPoint!.dx - 32,
                  top: _focusPoint!.dy - 32,
                  child: IgnorePointer(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.yellow, width: 2),
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _continuousMode
                          ? '연속 스캔 중 · 이번에 $_sessionCount개 추가\n(바코드가 정확히 맞으면 바로 추가되고 진동이 울립니다)'
                          : '케어라벨의 코드가 화면 중앙에 크고 선명하게 보이도록 촬영하세요\n(코드 부분을 탭하면 그 위치에 초점을 맞춥니다)',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
              if (_lastAdded != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    // 촬영 버튼 위쪽에 표시합니다.
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 150),
                    child: Material(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        child: Row(
                          children: [
                            Icon(
                              _lastAdded!.merged
                                  ? Icons.exposure_plus_1
                                  : Icons.check_circle,
                              color: Colors.greenAccent,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _addedMessage(_lastAdded!),
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                            ),
                            TextButton(
                              onPressed: _undoLastAdded,
                              child: const Text(
                                '되돌리기',
                                style: TextStyle(color: Colors.amberAccent),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 32),
                  child: FloatingActionButton.large(
                    onPressed: _isProcessing ? null : _captureAndRecognize,
                    child: _isProcessing
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          )
                        : const Icon(Icons.camera_alt),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
