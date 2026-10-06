import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'ocr_service.dart';

/// "자세히 읽기"용 도우미.
///
/// 한 번 읽어서 바코드가 정확히 맞지 않으면, 찍은 고해상도 사진에서
/// 코드가 있을 만한 부분만 잘라내 크게 키우고(작은 글자를 크게), 흑백으로
/// 바꿔 대비를 높인 뒤(흐린 인쇄를 진하게) 다시 읽습니다. 구겨지거나 둥근
/// 라벨에서 글자가 작고 찌그러져 틀리는 경우에 효과가 있습니다.

/// 처음 읽은 결과에서 "코드처럼 보이는" 줄의 위치를 고릅니다.
/// 영문과 숫자가 섞인 5글자 이상 덩어리가 있는 줄만 고르고(전화번호, 날짜,
/// 세탁 표시 같은 줄은 제외), 가장 긴 덩어리가 있는 줄부터 [maxLines]개.
/// 반환값: 각 줄의 [left, top, width, height] (사진 픽셀 단위).
List<List<double>> pickCodeLineRects(List<OcrLine> lines, {int maxLines = 2}) {
  final runPattern = RegExp(r'[A-Za-z0-9\-]{5,}');
  final digit = RegExp(r'[0-9]');
  final letter = RegExp(r'[A-Za-z]');

  final scored = <MapEntry<OcrLine, int>>[];
  for (final line in lines) {
    if (line.width <= 0 || line.height <= 0) continue;
    var best = 0;
    for (final m in runPattern.allMatches(line.text)) {
      final run = m.group(0)!;
      if (digit.hasMatch(run) && letter.hasMatch(run) && run.length > best) {
        best = run.length;
      }
    }
    if (best > 0) scored.add(MapEntry(line, best));
  }
  scored.sort((a, b) => b.value.compareTo(a.value));
  return scored
      .take(maxLines)
      .map((e) => <double>[e.key.left, e.key.top, e.key.width, e.key.height])
      .toList();
}

/// 사진 한 장에서 다시 읽을 조각 이미지들을 만들어 파일로 저장하고, 그 경로들을
/// 반환합니다. 사진을 푸는 작업이 무거워서 화면이 멈추지 않도록 별도
/// 작업(isolate)에서 돌리는 것을 전제로 합니다(`compute`로 호출).
///
/// [args]:
/// - `path`: 찍은 사진 파일 경로
/// - `outDir`: 조각 이미지를 저장할 폴더
/// - `rects`: [pickCodeLineRects]로 고른 줄 위치들
Future<List<String>> makeRecognitionCrops(Map<String, dynamic> args) async {
  final path = args['path'] as String;
  final outDir = args['outDir'] as String;
  final rects = (args['rects'] as List)
      .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
      .toList();

  final bytes = await File(path).readAsBytes();
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return const <String>[];

  // 사진 방향 정보(EXIF)가 있으면 실제로 돌려서, 글자 인식기가 본 방향과 맞춥니다.
  final orientation = decoded.exif.imageIfd.orientation;
  final photo = (orientation == null || orientation == 1)
      ? decoded
      : img.bakeOrientation(decoded);
  final w = photo.width;
  final h = photo.height;

  final outputs = <String>[];
  var index = 0;

  Future<void> save(img.Image image) async {
    final out =
        '$outDir/sinoon_crop_${DateTime.now().microsecondsSinceEpoch}_${index++}.jpg';
    await File(out).writeAsBytes(img.encodeJpg(image, quality: 95));
    outputs.add(out);
  }

  // 흑백 + 대비 늘리기(흐리거나 번진 인쇄를 또렷하게)
  img.Image enhance(img.Image src) =>
      img.normalize(img.grayscale(img.Image.from(src)), min: 0, max: 255);

  // 1) 코드가 있던 줄: 위아래·좌우로 여유를 두고 잘라서, 글자 높이가
  //    충분히 커지도록(줄 높이 약 90픽셀) 키웁니다.
  for (final r in rects) {
    final left = r[0], top = r[1], rw = r[2], rh = r[3];
    // 위치가 사진 크기와 맞지 않으면(기기별 좌표 차이) 건너뜁니다.
    if (rw <= 0 || rh <= 0 || left + rw > w * 1.05 || top + rh > h * 1.05) {
      continue;
    }
    final marginX = math.max(rh * 1.2, w * 0.03);
    final marginY = rh * 0.9;
    final x0 = math.max(0.0, left - marginX);
    final y0 = math.max(0.0, top - marginY);
    final x1 = math.min(w.toDouble(), left + rw + marginX);
    final y1 = math.min(h.toDouble(), top + rh + marginY);
    final cropW = (x1 - x0).round();
    final cropH = (y1 - y0).round();
    if (cropW < 8 || cropH < 8) continue;

    var crop = img.copyCrop(
      photo,
      x: x0.round(),
      y: y0.round(),
      width: cropW,
      height: cropH,
    );
    var scale = (90 / rh).clamp(1.0, 3.0).toDouble();
    if (cropW * scale > 2400) scale = 2400 / cropW;
    if (scale > 1.05) {
      crop = img.copyResize(
        crop,
        width: (cropW * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    }
    await save(crop);
    await save(enhance(crop));
  }

  // 2) 화면 가운데 띠: 코드 줄을 못 찾았거나 줄 위치가 틀렸을 때를 대비해,
  //    사용자가 코드를 두는 화면 가운데 부분도 잘라서 한 번 더 읽습니다.
  {
    final x0 = (w * 0.06).round();
    final y0 = (h * 0.28).round();
    final cropW = (w * 0.88).round();
    final cropH = (h * 0.44).round();
    if (cropW >= 8 && cropH >= 8) {
      var crop = img.copyCrop(photo, x: x0, y: y0, width: cropW, height: cropH);
      var scale = 1.6;
      if (cropW * scale > 2600) scale = 2600 / cropW;
      if (scale > 1.05) {
        crop = img.copyResize(
          crop,
          width: (cropW * scale).round(),
          interpolation: img.Interpolation.cubic,
        );
      }
      await save(enhance(crop));
    }
  }

  return outputs;
}
