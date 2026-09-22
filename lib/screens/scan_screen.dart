import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../services/ocr_service.dart';
import '../services/product_lookup_service.dart';
import '../widgets/product_search_sheet.dart';

/// 카메라로 케어라벨을 촬영하고, OCR로 코드를 인식한 뒤
/// 상품 DB와 자동 매칭하거나 사용자가 직접 확인/선택하는 화면.
///
/// 확정된 결과를 [ScanOutcome]으로 [Navigator.pop]에 담아 반환합니다.
class ScanScreen extends StatefulWidget {
  final CameraDescription camera;
  final ProductLookupService productLookup;

  const ScanScreen({
    super.key,
    required this.camera,
    required this.productLookup,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final CameraController _controller;
  late final Future<void> _initializeControllerFuture;
  final OcrService _ocrService = OcrService();
  bool _isProcessing = false;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
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

  void _finish(String code, ProductInfo? product) {
    if (!mounted) return;
    Navigator.pop(context, ScanOutcome(code: code, product: product));
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
        _showMatchConfirmDialog(autoMatch, result);
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
                // 마지막으로 한 번 더 정확히 일치하는 바코드가 있는지 확인합니다.
                final product = widget.productLookup.findExactBarcode(value);
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
                    child: const Text(
                      '케어라벨의 코드가 화면 중앙에 크고 선명하게 보이도록 촬영하세요\n(코드 부분을 탭하면 그 위치에 초점을 맞춥니다)',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
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
