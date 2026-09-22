# 케어라벨 스캐너 (Flutter)

케어라벨을 카메라로 촬영하면 OCR(문자 인식)로 라벨에 적힌 코드를 자동으로
인식하고, 보내주신 `상품바코드조회.xlsx`(품번/품명/색상/사이즈/바코드 데이터)와
대조해서 **상품명까지 함께 보여주는** 앱입니다. 인식된 결과는 앱 안에서
리스트로 누적되고, 엑셀(.xlsx) 파일로 내보내(공유) 완료됩니다.

## 주요 특징

- 실제 바코드/QR 심볼이 아니라 **라벨에 인쇄된 영문숫자 텍스트**를 대상으로
  하므로, 바코드 스캐너가 아니라 **온디바이스 OCR**(Google ML Kit Text
  Recognition)을 사용합니다. 인터넷 연결 없이 기기에서 바로 동작합니다.
- 보내주신 `상품바코드조회.xlsx`를 `assets/product_barcodes.json`(약 4,037개
  품목)으로 변환해서 앱에 내장했습니다. 인터넷 연결 없이도 인식된 코드로
  품번/품명/색상/사이즈/가격을 즉시 조회합니다.
- **케어라벨 두 가지 형태를 모두 지원**합니다.
  1. 라벨에 "바코드" 한 줄(품번+색상+사이즈 조합, 예: `EW2A2BB001TLFRE`)이
     그대로 인쇄된 경우 → OCR로 읽은 문자열을 바코드 목록과 정확히
     대조합니다. OCR이 한두 글자를 잘못 읽어도(예: `O`↔`0`) 편집거리 기반
     근사 매칭으로 가장 가까운 바코드를 찾아줍니다.
  2. 라벨에 품번·색상·사이즈가 **각각 따로** 인쇄된 경우 → 인식된 단어들
     중 품번처럼 보이는 토큰과, 실제 데이터에 있는 색상 코드(BU, TL 등)·
     사이즈 코드(S, M, FRE, 230 등)로 보이는 토큰을 자동으로 찾아 조합해서
     상품을 특정합니다. 색상/사이즈까지는 못 읽었지만 품번은 확실할 때는
     "옵션 선택" 화면을 바로 띄워 색상/사이즈만 골라 확정하게 했습니다.
- 자동 매칭이 안 되는 경우를 위해 **"상품 직접 검색"** 화면을 제공합니다.
  품번이나 품명 일부를 입력하면 목록이 뜨고, 옵션(색상/사이즈)이 여러 개면
  한 번 더 골라서 확정합니다. 완전히 새로운/미등록 상품은 코드만 직접
  입력해서 목록에 남길 수도 있습니다(이 경우 "상품명 미확인"으로 표시되고,
  나중에 리스트 화면에서 연결 아이콘으로 상품을 붙일 수 있습니다).
- "엑셀로 내보내기" 버튼을 누르면 품번/품명/색상/사이즈/인식코드/매칭여부
  열을 포함한 .xlsx 파일을 만들어 카카오톡/이메일/파일 저장 등으로 공유할
  수 있습니다.

## 폴더 구조

```
care_label_scanner/
├── pubspec.yaml                       # 의존성 + assets 등록
├── assets/
│   └── product_barcodes.json          # 상품바코드조회.xlsx를 변환한 상품 마스터 데이터
├── tools/
│   └── convert_barcode_xlsx_to_json.py  # 엑셀 → json 변환 스크립트 (데이터 갱신용)
├── lib/
│   ├── main.dart                      # 앱 진입점: 카메라 초기화 + 상품 DB 로딩
│   ├── models/
│   │   ├── product_info.dart          # 상품 1건(품번/품명/색상/사이즈/바코드 등)
│   │   ├── scan_record.dart           # 스캔 1건(코드 + 매칭된 상품)
│   │   └── scan_outcome.dart          # 스캔 화면 → 홈 화면 전달용 값
│   ├── services/
│   │   ├── ocr_service.dart           # OCR 실행 + 토큰/후보 추출
│   │   ├── product_lookup_service.dart# 상품 DB 로딩 + 정확/근사/조합 매칭
│   │   └── excel_export_service.dart  # 엑셀 생성 + 공유
│   ├── screens/
│   │   ├── home_screen.dart           # 누적 리스트 화면
│   │   └── scan_screen.dart           # 촬영 + 자동 매칭 + 확인 화면
│   └── widgets/
│       └── product_search_sheet.dart  # 품번/품명 직접 검색 + 옵션 선택 바텀시트
└── platform_config/
    ├── android_manifest_additions.xml   # AndroidManifest.xml에 추가할 내용
    └── ios_info_plist_additions.xml     # Info.plist에 추가할 내용
```

이 폴더에는 `lib/`, `assets/`, `tools/`, `pubspec.yaml`만 들어 있고,
`android/`, `ios/` 같은 플랫폼별 프로젝트 폴더는 들어 있지 않습니다(용량이
크고 Flutter SDK 버전마다 자동 생성되는 내용이라, 아래 절차대로 직접
생성하는 것이 가장 안전합니다).

## 처음 실행하는 방법

### 1. Flutter SDK 설치

아직 설치하지 않았다면 https://docs.flutter.dev/get-started/install 안내를
따라 설치하세요. 설치 후 터미널에서 다음을 실행해 정상 설치를 확인합니다.

```bash
flutter doctor
```

### 2. 빈 Flutter 프로젝트 생성

아래처럼 새 프로젝트를 하나 생성합니다(자동으로 android/ios 폴더까지 만들어
줍니다).

```bash
flutter create --org com.sinoon.carelabel care_label_scanner_app
```

### 3. 제공된 코드/데이터 덮어쓰기

방금 만든 `care_label_scanner_app` 폴더 안의 `pubspec.yaml`과 `lib/` 폴더를
이 zip 안에 있는 내용으로 교체(덮어쓰기)하고, `assets/`, `tools/` 폴더를
추가로 복사합니다.

```bash
cd care_label_scanner_app
rm -rf lib
cp -r /path/to/care_label_scanner/lib .
cp -r /path/to/care_label_scanner/assets .
cp -r /path/to/care_label_scanner/tools .
cp /path/to/care_label_scanner/pubspec.yaml .
```

`android/`, `ios/` 폴더는 2번 단계에서 생성된 것을 그대로 둡니다.

### 4. 카메라 권한 추가

- `platform_config/android_manifest_additions.xml`의 안내에 따라
  `android/app/src/main/AndroidManifest.xml`에 카메라 권한을 추가하세요.
- `platform_config/ios_info_plist_additions.xml`의 안내에 따라
  `ios/Runner/Info.plist`에 카메라 사용 목적 문구를 추가하세요.

### 5. 패키지 설치 및 실행

```bash
flutter pub get
flutter run
```

에뮬레이터에는 카메라가 없는 경우가 많으므로, 실제 스마트폰을 USB로 연결해
`flutter run`으로 실행해 보는 것을 권장합니다.

## 상품 데이터(바코드 DB)가 바뀌었을 때

`상품바코드조회.xlsx`가 갱신되면(신상품 추가, 가격 변경 등) 앱에 새로 담아야
최신 상품명이 뜹니다. 다음처럼 다시 변환하고 앱을 재빌드하세요.

```bash
cd care_label_scanner_app
pip install openpyxl
python3 tools/convert_barcode_xlsx_to_json.py 새로운_상품바코드조회.xlsx
flutter run   # 또는 flutter build apk / flutter build ios
```

원본 엑셀의 컬럼 순서가 지금과 같다면(품번, 품명, 색상, 사이즈, 사이즈표기,
바코드, 사이즈구분명, 사이즈범위, 사이즈위치, 성별구분명, 최초판매가, 택가
순서) 그대로 실행하면 되고, 순서가 다르면 스크립트 상단의 `COLUMN_INDEX`
값을 실제 열 번호에 맞게 고치면 됩니다.

## 인식이 잘 안 될 때 함께 확인해보면 좋은 것들

- **바코드가 한 줄로 인쇄된 라벨**: `EW2A2BB001TLFRE`처럼 공백 없이 촘촘하게
  인쇄되어 있으면 OCR이 통째로 한 단어처럼 잘 읽는 편입니다. 화면 중앙에
  코드가 크고 수평으로 보이도록 촬영해주세요.
- **품번/컬러/사이즈가 각각 인쇄된 라벨**: 예를 들어 "EW2A2BB001", "TL",
  "FREE"가 서로 다른 줄에 있는 경우, 세 부분이 모두 화면 안에 들어오도록
  촬영해야 자동 조합 인식이 됩니다. 색상 코드(BU, TL 등)나 사이즈 표기
  (FREE, SMALL 등)가 데이터에 없는 새로운 코드라면 자동 매칭이 안 될 수
  있으니, 이런 경우를 발견하시면 알려주시면 `product_lookup_service.dart`의
  인식 로직을 보강해 드릴 수 있습니다.
- **완전히 실패할 때**: 스캔 화면 오른쪽 위 돋보기 아이콘(또는 인식 실패 시
  뜨는 바텀시트의 "상품 직접 검색")으로 품번/품명을 타이핑해서 바로 찾을 수
  있습니다.

## 다음 단계로 다듬으면 좋은 부분

- **목록 보관**: 지금은 앱을 완전히 종료하면 스캔 목록이 초기화됩니다(메모리
  저장). 여러 날에 걸쳐 목록을 유지하고 싶다면 `sqflite`나 `hive` 같은 로컬
  저장소를 추가해 앱을 껐다 켜도 목록이 남도록 확장할 수 있습니다.
- **엑셀 서식**: 지금은 번호/품번/품명/색상/사이즈/인식코드/매칭여부/
  인식일시/메모 열이 있습니다. 실제 업무 양식(발주서, 검수표 등)에 맞춰
  열을 추가하거나 헤더 스타일을 지정할 수 있습니다.
- **촬영 가이드**: 라벨의 정확한 부분만 인식하도록 화면에 사각형 가이드
  프레임을 추가하고, 그 영역만 잘라서 OCR에 넘기면 인식률을 더 높일 수
  있습니다.
- **매칭 로직 튜닝**: 실제 라벨 사진 몇 장을 테스트해보면서, 색상/사이즈
  코드 인식 우선순위나 근사 매칭 허용 오차(현재 편집거리 2)를 데이터에
  맞게 조정할 수 있습니다.

원하시면 위 항목들도 이어서 구현해 드릴 수 있습니다.
