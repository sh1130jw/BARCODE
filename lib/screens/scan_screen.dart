import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    show
        InputImage,
        InputImageFormat,
        InputImageFormatValue,
        InputImageMetadata,
        InputImageRotationValue;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/product_info.dart';
import '../models/scan_outcome.dart';
import '../services/ocr_service.dart';
import '../services/precise_ocr.dart';
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

  /// 자동 재촬영 중일 때 화면 위쪽에 보여줄 안내(예: "다시 읽는 중... (1/2)")
  String? _statusText;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;

  /// 연속 스캔 모드 여부(마지막 설정을 기억합니다).
  bool _continuousMode = false;

  /// 이번에 스캔 화면을 연 뒤로 추가한 개수(연속 스캔 모드 표시용).
  int _sessionCount = 0;

  /// 연속 스캔 모드에서 방금 추가한 상품(화면 아래 알림 + 되돌리기용).
  AddResult? _lastAdded;
  Timer? _lastAddedTimer;

  /// 줌(확대) 상태. 기기마다 지원 범위가 달라서 카메라를 연 뒤 읽어옵니다.
  static const _zoomPrefKey = 'scan_zoom_level';
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _zoomAtPinchStart = 1.0;
  bool _isPinching = false;

  /// 이번 스캔에서 읽힌 글자들. 사용자가 상품을 확정하면 "틀리게 읽힌 글자 ->
  /// 맞는 상품" 짝을 기억하는 데 씁니다(다음에 같은 라벨을 바로 찾도록).
  List<String> _lastScanTokens = const [];

  // ---- 라이브 인식(셔터 없이 미리보기 화면을 계속 읽기) ----
  static const _livePrefKey = 'live_scan_enabled';
  bool _liveEnabled = true;
  bool _liveStreamRunning = false;
  bool _liveBusy = false;
  DateTime _lastLiveRun = DateTime.fromMillisecondsSinceEpoch(0);

  /// 방금 추가한 뒤 잠깐 쉬는 시간(같은 라벨을 연달아 넣지 않도록)
  DateTime _livePausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 최근 몇 번의 화면에서 정확히 읽힌 바코드(없으면 null).
  /// 서로 다른 두 순간에 같은 바코드가 읽혀야 확정합니다.
  final List<String?> _liveWindow = [];

  /// 방금 추가한 바코드. 화면에서 한 번 사라졌다가 다시 보여야 또 추가합니다
  /// (같은 상품 여러 벌을 연속으로 셀 때를 위해 "사라짐"만 확인).
  String? _liveCooldownBarcode;
  int _liveCooldownMissFrames = 0;

  /// 라이브로 읽고 있는 글자(화면에 참고용으로 보여줌)
  String? _liveHint;

  static const Map<DeviceOrientation, int> _deviceOrientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _loadContinuousMode();
    _controller = CameraController(
      widget.camera,
      // 케어라벨 글자가 작고, 구겨지거나 둥글면 글자 모양이 찌그러지기 때문에
      // 기기가 지원하는 가장 높은 해상도로 찍습니다(예전 1080p보다 글자 한 개에
      // 들어가는 픽셀이 훨씬 많아져서 인식이 안정적입니다).
      ResolutionPreset.max,
      enableAudio: false,
      // 라이브 인식용 미리보기 형식(안드로이드 글자 인식기가 바로 읽는 형식)
      imageFormatGroup: ImageFormatGroup.nv21,
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
      await _initZoom();
      await _loadLiveEnabled();
      await _startLive();
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

  /// 기기의 줌 범위를 읽고, 마지막에 쓰던 배율로 맞춥니다.
  Future<void> _initZoom() async {
    try {
      final minZoom = await _controller.getMinZoomLevel();
      final maxZoom = await _controller.getMaxZoomLevel();
      double saved = 1.0;
      try {
        final prefs = await SharedPreferences.getInstance();
        saved = prefs.getDouble(_zoomPrefKey) ?? 1.0;
      } catch (_) {}
      // 광각(1x 미만)은 라벨 글자가 더 작아져서 쓰지 않습니다.
      final lower = minZoom > 1.0 ? minZoom : 1.0;
      final upper = maxZoom < lower ? lower : maxZoom;
      final start = saved.clamp(lower, upper).toDouble();
      if (!mounted) return;
      setState(() {
        _minZoom = lower;
        _maxZoom = upper;
        _currentZoom = start;
      });
      if (start != 1.0) {
        await _controller.setZoomLevel(start);
      }
    } catch (_) {
      // 줌을 지원하지 않는 기기는 1x로만 동작합니다.
    }
  }

  /// 배율 버튼에 보여줄 값들(기기가 지원하는 범위 안에서만).
  List<double> get _zoomPresets {
    const candidates = [1.0, 2.0, 3.0, 5.0];
    final presets = candidates.where((z) => z <= _maxZoom + 0.01).toList();
    return presets.isEmpty ? [1.0] : presets;
  }

  void _applyZoom(double zoom, {bool save = true}) {
    final z = zoom.clamp(_minZoom, _maxZoom).toDouble();
    if ((z - _currentZoom).abs() < 0.01) return;
    setState(() => _currentZoom = z);
    _controller.setZoomLevel(z).catchError((_) {});
    if (save) _saveZoom(z);
  }

  Future<void> _saveZoom(double zoom) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_zoomPrefKey, zoom);
    } catch (_) {}
  }

  Future<void> _loadLiveEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_livePrefKey) ?? true;
      if (mounted) setState(() => _liveEnabled = saved);
    } catch (_) {}
  }

  Future<void> _toggleLive() async {
    final value = !_liveEnabled;
    setState(() {
      _liveEnabled = value;
      _liveHint = null;
    });
    if (value) {
      await _startLive();
    } else {
      await _stopLive();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_livePrefKey, value);
    } catch (_) {}
  }

  Future<void> _startLive() async {
    if (!_liveEnabled || _liveStreamRunning || !mounted) return;
    if (!_controller.value.isInitialized) return;
    try {
      await _controller.startImageStream(_onLiveFrame);
      _liveStreamRunning = true;
    } catch (_) {
      // 이 기기에서 라이브 인식이 안 되면 셔터 방식으로만 동작합니다.
      _liveStreamRunning = false;
    }
  }

  Future<void> _stopLive() async {
    if (!_liveStreamRunning) return;
    _liveStreamRunning = false;
    try {
      await _controller.stopImageStream();
    } catch (_) {}
    // 읽고 있던 화면이 끝날 때까지 잠깐 기다립니다.
    for (var i = 0; i < 20 && _liveBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    try {
      final sensor = widget.camera.sensorOrientation;
      final device = _deviceOrientationDegrees[_controller.value.deviceOrientation];
      if (device == null) return null;
      final degrees = widget.camera.lensDirection == CameraLensDirection.front
          ? (sensor + device) % 360
          : (sensor - device + 360) % 360;
      final rotation = InputImageRotationValue.fromRawValue(degrees);
      final raw = image.format.raw;
      final format = raw is int ? InputImageFormatValue.fromRawValue(raw) : null;
      if (rotation == null || format != InputImageFormat.nv21) return null;
      if (image.planes.length != 1) return null;
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format!,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void _onLiveFrame(CameraImage image) {
    if (!mounted || _liveBusy || _isProcessing || !_liveEnabled) return;
    // 확인 창이나 후보 목록이 떠 있는 동안에는 읽지 않습니다.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final now = DateTime.now();
    if (now.isBefore(_livePausedUntil)) return;
    if (now.difference(_lastLiveRun).inMilliseconds < 250) return;
    _lastLiveRun = now;

    final input = _toInputImage(image);
    if (input == null) return;
    _liveBusy = true;
    _ocrService.recognizeInput(input).then((result) {
      if (!mounted || _isProcessing || !_liveEnabled) return;
      _handleLiveResult(result);
    }).catchError((_) {}).whenComplete(() {
      _liveBusy = false;
    });
  }

  void _handleLiveResult(OcrResult result) {
    final match = widget.productLookup
        .attemptAutoMatch(result.tokens, withSuggestions: false);

    // 라이브에서는 확실한 것만: 바코드가 정확히 일치하거나, 예전에 두 번 이상
    // 확인해준 기록과 똑같이 읽힌 경우만 셉니다.
    String? barcode;
    if (match.isMatched &&
        (match.confidence == MatchConfidence.exact ||
            (match.confidence == MatchConfidence.learned &&
                match.learnedCount >= 2))) {
      barcode = match.product!.barcode;
    }

    // 방금 추가한 상품이 아직 화면에 있으면 무시하고, 사라진 게 확인되면 풀어줍니다.
    if (_liveCooldownBarcode != null) {
      if (barcode == _liveCooldownBarcode) {
        _liveCooldownMissFrames = 0;
        barcode = null;
      } else {
        _liveCooldownMissFrames += 1;
        if (_liveCooldownMissFrames >= 2) _liveCooldownBarcode = null;
      }
    }

    _liveWindow.add(barcode);
    if (_liveWindow.length > 5) _liveWindow.removeAt(0);

    // 화면에 "읽는 중" 글자를 보여줘서, 어느 정도 읽히고 있는지 알 수 있게 합니다.
    String? hint;
    for (final c in result.candidates) {
      final current = hint;
      if (current == null || c.length > current.length) hint = c;
    }
    final newHint = hint;
    if (newHint != _liveHint) setState(() => _liveHint = newHint);

    if (barcode != null && _liveWindow.where((b) => b == barcode).length >= 2) {
      _liveWindow.clear();
      _liveCooldownBarcode = barcode;
      _liveCooldownMissFrames = 0;
      _livePausedUntil = DateTime.now().add(const Duration(milliseconds: 1200));
      _lastScanTokens = const [];
      _finish(match.product!.barcode, match.product);
    }
  }

  String _zoomLabel(double z) {
    final rounded = (z * 10).round() / 10;
    return rounded == rounded.roundToDouble()
        ? '${rounded.toInt()}x'
        : '${rounded.toStringAsFixed(1)}x';
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
    // 이번 스캔에서 틀리게 읽힌 글자가 있었다면, 사용자가 확정한 상품과의 짝을
    // 기억해둡니다(다음에 같은 라벨이 같은 식으로 틀려도 바로 찾도록).
    if (product != null && _lastScanTokens.isNotEmpty) {
      widget.productLookup.learnCorrection(_lastScanTokens, product);
    }
    _lastScanTokens = const [];
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

  /// 한 장 찍어서 글자를 읽고, 찍은 사진 파일은 바로 지웁니다.
  Future<OcrResult> _takeAndRecognize() async {
    final XFile picture = await _controller.takePicture();
    try {
      return await _ocrService.recognize(File(picture.path));
    } finally {
      try {
        await File(picture.path).delete();
      } catch (_) {}
    }
  }

  /// 여러 장에서 읽은 글자를 합칩니다. 장마다 다른 글자가 제대로 읽히는
  /// 경우가 많아서(구겨진 부분, 빛 반사 위치가 조금씩 달라짐), 합쳐서 보면
  /// 맞는 상품을 찾을 확률이 올라갑니다.
  OcrResult _mergeOcr(OcrResult a, OcrResult b) {
    final seen = <String>{};
    final candidates = <String>[];
    for (final c in [...a.candidates, ...b.candidates]) {
      if (seen.add(c.toUpperCase())) candidates.add(c);
    }
    return OcrResult(
      fullText: '${a.fullText}\n\n${b.fullText}',
      tokens: [...a.tokens, ...b.tokens],
      candidates: candidates,
    );
  }

  Future<void> _captureAndRecognize() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    _lastScanTokens = const [];

    String? firstPhotoPath;
    try {
      await _initializeControllerFuture;
      await _stopLive(); // 사진을 찍는 동안에는 라이브 인식을 멈춥니다.
      final firstPhoto = await _controller.takePicture();
      firstPhotoPath = firstPhoto.path;
      var result = await _ocrService.recognize(File(firstPhoto.path));
      if (!mounted) return;
      var autoMatch = widget.productLookup.attemptAutoMatch(result.tokens);

      // 2단계 "자세히 읽기": 바코드가 정확히 맞지 않으면, 방금 찍은 고해상도
      // 사진에서 코드가 있는 줄(과 화면 가운데)을 잘라 크게 키우고 대비를
      // 높여 다시 읽습니다. 새로 찍는 게 아니라서 라벨을 움직여도 괜찮아요.
      if (autoMatch.confidence != MatchConfidence.exact) {
        setState(() => _statusText = '자세히 읽는 중...');
        final precise = await _preciseRecognize(firstPhoto.path, result);
        if (!mounted) return;
        if (precise != null) {
          final preciseMatch =
              widget.productLookup.attemptAutoMatch(precise.tokens);
          result = _mergeOcr(result, precise);
          if (preciseMatch.confidence == MatchConfidence.exact) {
            autoMatch = preciseMatch;
          } else {
            final merged = widget.productLookup.attemptAutoMatch(result.tokens);
            if (_matchRank(merged) >= _matchRank(autoMatch)) autoMatch = merged;
          }
        }
      }

      // 못 찾았으면 사용자가 다시 누르지 않아도 두 장 더 찍어서 읽어봅니다.
      // (손떨림, 순간적인 초점, 구겨진 부분의 빛 반사 때문에 한 장에서만
      // 틀리는 경우가 많습니다.)
      const maxExtraShots = 2;
      var extraShot = 0;
      while (!autoMatch.isMatched &&
          !autoMatch.isAmbiguous &&
          extraShot < maxExtraShots) {
        extraShot += 1;
        setState(() => _statusText = '다시 읽는 중... ($extraShot/$maxExtraShots)\n라벨을 그대로 비춰주세요');
        final next = await _takeAndRecognize();
        if (!mounted) return;
        final nextMatch = widget.productLookup.attemptAutoMatch(next.tokens);
        result = _mergeOcr(result, next);
        if (nextMatch.isMatched || nextMatch.isAmbiguous) {
          autoMatch = nextMatch;
          break;
        }
        // 지금까지 찍은 사진들의 글자를 모두 합쳐서 다시 찾아봅니다.
        autoMatch = widget.productLookup.attemptAutoMatch(result.tokens);
      }
      if (mounted) setState(() => _statusText = null);
      // 바코드가 정확히 읽혔으면 바로잡을 게 없으니 기억하지 않습니다.
      _lastScanTokens = autoMatch.confidence == MatchConfidence.exact
          ? const []
          : result.tokens;

      final sureEnough = autoMatch.confidence == MatchConfidence.exact ||
          (autoMatch.confidence == MatchConfidence.learned &&
              autoMatch.learnedCount >= 2);
      if (autoMatch.isMatched) {
        if (_continuousMode && sureEnough) {
          // 연속 스캔 모드에서 바코드가 정확히 일치하면 확인 없이 바로 추가.
          // (근사 일치나 조합 인식처럼 틀릴 여지가 있는 경우는 확인 창을 띄웁니다.)
          _finish(autoMatch.matchedFrom, autoMatch.product);
        } else {
          _showMatchConfirmDialog(autoMatch, result);
        }
      } else if (autoMatch.isAmbiguous) {
        // 품번은 정확히 인식됐지만 색상/사이즈까지는 특정하지 못한 경우:
        // 바로 옵션 선택 화면을 띄워줍니다.
        _openProductSearch(
          directItemNo: autoMatch.matchedFrom,
          fallback: result,
          fallbackSuggestions: autoMatch.suggestions,
        );
      } else {
        _showCandidatePicker(result, suggestions: autoMatch.suggestions);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('인식 중 오류가 발생했습니다: $e')),
      );
    } finally {
      if (firstPhotoPath != null) {
        try {
          await File(firstPhotoPath).delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusText = null;
        });
        await _startLive();
      }
    }
  }

  /// 매칭 결과의 믿을 만한 정도(클수록 좋음). 여러 결과 중 나은 쪽을 고를 때 사용.
  int _matchRank(MatchResult m) {
    if (m.isMatched) {
      switch (m.confidence) {
        case MatchConfidence.exact:
          return 5;
        case MatchConfidence.components:
          return 4;
        case MatchConfidence.learned:
          return 4;
        case MatchConfidence.fuzzy:
          return 3;
        case MatchConfidence.none:
          return 1;
      }
    }
    if (m.isAmbiguous) return 2;
    return 1;
  }

  /// 사진에서 코드 부분만 잘라 크게 키워 다시 읽습니다(자세히 읽기).
  /// 조각마다 읽은 글자를 합쳐서 돌려주고, 실패하면 null.
  Future<OcrResult?> _preciseRecognize(String photoPath, OcrResult first) async {
    List<String> crops = const [];
    try {
      final rects = pickCodeLineRects(first.lines);
      crops = await compute(makeRecognitionCrops, <String, dynamic>{
        'path': photoPath,
        'outDir': File(photoPath).parent.path,
        'rects': rects,
      });
      OcrResult? merged;
      for (final cropPath in crops) {
        final r = await _ocrService.recognize(File(cropPath));
        merged = merged == null ? r : _mergeOcr(merged, r);
        // 이 조각에서 바코드가 정확히 읽혔으면 더 볼 필요가 없습니다.
        if (widget.productLookup.attemptAutoMatch(r.tokens).confidence ==
            MatchConfidence.exact) {
          break;
        }
      }
      return merged;
    } catch (_) {
      return null;
    } finally {
      for (final cropPath in crops) {
        try {
          await File(cropPath).delete();
        } catch (_) {}
      }
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
      case MatchConfidence.learned:
        return '예전에 바로잡은 기록으로 인식';
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
                // 방금 보여준 상품을 뺀 나머지 비슷한 후보들을 보여줍니다.
                _showCandidatePicker(
                  ocrResult,
                  suggestions: match.suggestions
                      .where((s) => s.product.barcode != product.barcode)
                      .toList(),
                );
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

  void _showCandidatePicker(
    OcrResult result, {
    List<ProductSuggestion> suggestions = const [],
  }) {
    final hasSuggestions = suggestions.isNotEmpty;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
            ),
            child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasSuggestions ? '혹시 이 상품인가요?' : '자동으로 상품을 찾지 못했어요',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  hasSuggestions
                      ? '라벨 글자가 일부만 읽혔어요. 맞는 상품을 누르면 바로 추가돼요.'
                      : '인식된 코드 후보를 고르거나, 상품을 직접 검색해서 연결하세요.',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                if (hasSuggestions) ...[
                  ...suggestions.map(
                    (s) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(
                          s.product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          s.product.variantLabel.isEmpty
                              ? s.product.itemNo
                              : '${s.product.itemNo} · ${s.product.variantLabel}',
                        ),
                        trailing: const Icon(Icons.add_circle_outline),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _finish(s.product.barcode, s.product);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (result.candidates.isNotEmpty) ...[
                  const Text(
                    '읽힌 글자',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
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
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _showManualEntryDialog(initialText: '', fullText: result.fullText);
                      },
                      child: const Text('코드만 직접 입력'),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('다시 찍기'),
                    ),
                  ],
                ),
              ],
            ),
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
    List<ProductSuggestion> fallbackSuggestions = const [],
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
      _showCandidatePicker(fallback, suggestions: fallbackSuggestions);
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

  String _hintText() {
    final session = _continuousMode ? '연속 스캔 · 이번에 $_sessionCount개 추가\n' : '';
    if (_liveEnabled && _liveStreamRunning) {
      final reading = _liveHint == null ? '' : '\n읽는 중: $_liveHint';
      return '$session라벨의 코드를 비추면 자동으로 읽어요'
          '\n(잘 안 되면 라벨을 펴거나 살짝 기울이고, 셔터를 눌러도 돼요)$reading';
    }
    return '$session케어라벨의 코드가 화면 중앙에 크고 선명하게 보이도록 촬영하세요'
        '\n(코드를 탭하면 초점, 너무 가까우면 흐려지니 2x로 조금 떨어져서 찍어보세요)';
  }

  /// 삼성 카메라처럼 1x · 2x · 3x 버튼을 보여줍니다. 선택된 배율은 노란색으로,
  /// 손가락으로 확대 중이거나 버튼 사이 배율이면 현재 배율(예: 2.4x)을 표시합니다.
  Widget _buildZoomBar() {
    final presets = _zoomPresets;
    // 현재 배율과 가장 가까운 버튼을 "선택됨"으로 표시합니다.
    double nearest = presets.first;
    for (final p in presets) {
      if ((p - _currentZoom).abs() < (nearest - _currentZoom).abs()) nearest = p;
    }
    final onPreset = (nearest - _currentZoom).abs() < 0.05;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: presets.map((p) {
          final selected = p == nearest;
          final label = selected && !onPreset ? _zoomLabel(_currentZoom) : _zoomLabel(p);
          return GestureDetector(
            onTap: () => _applyZoom(p),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: selected ? 48 : 38,
              height: selected ? 48 : 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Colors.black87 : Colors.black54,
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.yellow : Colors.white,
                  fontSize: selected ? 14 : 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        }).toList(),
      ),
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
            icon: Icon(
              _liveEnabled ? Icons.center_focus_strong : Icons.center_focus_weak,
            ),
            tooltip: _liveEnabled ? '자동 인식 끄기' : '자동 인식 켜기',
            onPressed: _toggleLive,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '상품 직접 검색',
            onPressed: () {
              _lastScanTokens = const []; // 스캔과 무관한 검색이라 기억하지 않음
              _openProductSearch();
            },
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
                    // 두 손가락으로 벌리거나 오므려서 확대/축소
                    onScaleStart: (_) {
                      _zoomAtPinchStart = _currentZoom;
                    },
                    onScaleUpdate: (details) {
                      if (details.pointerCount < 2) return;
                      if (!_isPinching) setState(() => _isPinching = true);
                      _applyZoom(_zoomAtPinchStart * details.scale, save: false);
                    },
                    onScaleEnd: (_) {
                      if (_isPinching) {
                        setState(() => _isPinching = false);
                        _saveZoom(_currentZoom);
                      }
                    },
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
                      _statusText ?? _hintText(),
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 200),
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
              if (_maxZoom > 1.0)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 140),
                    child: _buildZoomBar(),
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
