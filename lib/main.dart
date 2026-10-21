import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'services/product_lookup_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = [];
  }

  final productLookup = ProductLookupService();

  runApp(CareLabelScannerApp(cameras: cameras, productLookup: productLookup));
}

/// 앱 전체에서 쓰는 애플(iOS) 느낌의 색상
class AppleColors {
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const red = Color(0xFFFF3B30);
  static const orange = Color(0xFFFF9500);
  static const background = Color(0xFFF2F2F7); // 회색 바탕(설정 앱 같은)
  static const card = Colors.white;
  static const label = Color(0xFF000000);
  static const secondaryLabel = Color(0xFF8E8E93);
  static const separator = Color(0xFFC6C6C8);
  static const fill = Color(0x1F767680); // 검색창·칩 같은 옅은 회색 채움
  static const chevron = Color(0xFFC7C7CC);
}

/// 둥근 모서리, 그림자 없는 카드, 파란 강조색, 물결(잉크) 효과 없음,
/// 옆으로 밀리는 화면 전환 등 아이폰 앱과 비슷한 느낌의 테마.
ThemeData buildAppleTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppleColors.blue,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppleColors.blue,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFDCEBFF),
    onPrimaryContainer: AppleColors.blue,
    secondaryContainer: const Color(0xFFE5E5EA),
    onSecondaryContainer: AppleColors.label,
    surface: AppleColors.card,
    onSurface: AppleColors.label,
    onSurfaceVariant: AppleColors.secondaryLabel,
    surfaceContainerHighest: const Color(0xFFE9E9EB),
    surfaceTint: Colors.transparent,
    error: AppleColors.red,
    outline: AppleColors.separator,
    outlineVariant: AppleColors.separator,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.apply(
    bodyColor: AppleColors.label,
    displayColor: AppleColors.label,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppleColors.background,
    // 누를 때 물결이 퍼지는 효과 대신, 살짝 어두워지기만 하도록
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x14000000),
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      bodyLarge: text.bodyLarge?.copyWith(letterSpacing: -0.2),
      bodyMedium: text.bodyMedium?.copyWith(letterSpacing: -0.1),
    ),
    // 화면이 오른쪽에서 밀려 들어오고, 왼쪽 끝을 밀어서 뒤로 가기
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppleColors.background,
      foregroundColor: AppleColors.label,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: AppleColors.label,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      iconTheme: IconThemeData(color: AppleColors.blue),
      actionsIconTheme: IconThemeData(color: AppleColors.blue),
      systemOverlayStyle: SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardTheme(
      color: AppleColors.card,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: AppleColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: const TextStyle(
        color: AppleColors.label,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppleColors.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppleColors.chevron,
      dragHandleSize: Size(36, 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
    ),
    bannerTheme: const MaterialBannerThemeData(
      backgroundColor: AppleColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      dividerColor: AppleColors.separator,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppleColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xF21C1C1E),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      actionTextColor: const Color(0xFF64D2FF),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppleColors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppleColors.blue,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    // 카메라 화면의 촬영 버튼: 동그란 파란 버튼
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppleColors.blue,
      foregroundColor: Colors.white,
      elevation: 2,
      highlightElevation: 0,
      shape: CircleBorder(
        side: BorderSide(color: Colors.white, width: 4),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppleColors.fill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: const TextStyle(color: AppleColors.secondaryLabel),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppleColors.fill,
      selectedColor: const Color(0xFFDCEBFF),
      labelStyle: const TextStyle(color: AppleColors.label, fontSize: 14),
      side: BorderSide.none,
      showCheckmark: false,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppleColors.secondaryLabel,
      subtitleTextStyle: TextStyle(color: AppleColors.secondaryLabel, fontSize: 13),
    ),
    dividerTheme: const DividerThemeData(
      color: AppleColors.separator,
      thickness: 0.5,
      space: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppleColors.green
            : const Color(0xFFE9E9EA),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: const BorderSide(color: AppleColors.chevron, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? AppleColors.blue : Colors.transparent,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppleColors.secondaryLabel,
    ),
  );
}

class CareLabelScannerApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  final ProductLookupService productLookup;

  const CareLabelScannerApp({
    super.key,
    required this.cameras,
    required this.productLookup,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SINOON',
      debugShowCheckedModeBanner: false,
      theme: buildAppleTheme(),
      home: cameras.isEmpty
          ? const _NoCameraScreen()
          : _AppStartup(camera: cameras.first, productLookup: productLookup),
    );
  }
}

/// 상품 바코드 데이터(assets/product_barcodes.json)를 불러온 뒤
/// 홈 화면으로 넘어가는 시작 화면.
class _AppStartup extends StatefulWidget {
  final CameraDescription camera;
  final ProductLookupService productLookup;

  const _AppStartup({required this.camera, required this.productLookup});

  @override
  State<_AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<_AppStartup> {
  late final Future<void> _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = widget.productLookup.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'SINOON',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  SizedBox(height: 20),
                  CupertinoActivityIndicator(radius: 12),
                ],
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '상품 데이터를 불러오지 못했습니다.\n(assets/product_barcodes.json 확인 필요)\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        return HomeScreen(
          camera: widget.camera,
          productLookup: widget.productLookup,
        );
      },
    );
  }
}

class _NoCameraScreen extends StatelessWidget {
  const _NoCameraScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '카메라를 사용할 수 없습니다.\n실제 기기에서 실행하고 카메라 권한을 허용해주세요.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
