import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// OCR(문자 인식) 결과.
///
/// - [fullText]: 인식된 전체 텍스트
/// - [tokens]: 공백/기호로 분리한 모든 단어(짧은 색상/사이즈 코드 포함) -
///   품번/색상/사이즈가 라벨에 각각 따로 인쇄된 경우를 매칭할 때 사용합니다.
/// - [candidates]: 그중 "코드/바코드처럼 보이는" 조금 더 긴 토큰만 추린 목록 -
///   화면에 후보 칩으로 보여줄 때 사용합니다.
class OcrResult {
  final String fullText;
  final List<String> tokens;
  final List<String> candidates;

  OcrResult({
    required this.fullText,
    required this.tokens,
    required this.candidates,
  });
}

/// Google ML Kit의 온디바이스 텍스트 인식을 이용한 OCR 서비스.
/// 인터넷 연결 없이 기기에서 바로 동작합니다.
class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  Future<OcrResult> recognize(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final RecognizedText recognizedText =
        await _recognizer.processImage(inputImage);

    final tokens = _extractTokens(recognizedText.text);
    final candidates = _selectCandidates(tokens);

    return OcrResult(
      fullText: recognizedText.text,
      tokens: tokens,
      candidates: candidates,
    );
  }

  /// 인식된 전체 텍스트를 영문/숫자/하이픈 이외의 문자 기준으로 나눠
  /// 개별 단어(토큰)를 뽑아냅니다. 품번은 물론, "BU"/"S"/"FRE" 같은
  /// 짧은 색상·사이즈 코드도 놓치지 않기 위해 길이 제한을 두지 않습니다.
  List<String> _extractTokens(String text) {
    final raw = text.split(RegExp(r'[^A-Za-z0-9\-]+'));
    final seen = <String>{};
    final tokens = <String>[];
    for (final t in raw) {
      final cleaned = t.trim();
      if (cleaned.isEmpty) continue;
      if (seen.add(cleaned.toUpperCase())) tokens.add(cleaned);
    }
    return tokens;
  }

  /// 화면에 "코드 후보"로 보여줄 만한, 조금 더 길고 바코드/품번처럼 보이는
  /// 토큰만 추립니다. (짧은 단순 색상/사이즈 코드는 후보 칩에서는 제외하되
  /// [OcrResult.tokens]에는 남겨서 자동 매칭에는 계속 활용합니다.)
  List<String> _selectCandidates(List<String> tokens) {
    return tokens.where((t) {
      if (t.length < 4) return false;
      final hasDigit = RegExp(r'[0-9]').hasMatch(t);
      final hasLetter = RegExp(r'[A-Za-z]').hasMatch(t);
      return hasDigit || (hasLetter && t.length >= 6);
    }).toList();
  }

  void dispose() {
    _recognizer.close();
  }
}
