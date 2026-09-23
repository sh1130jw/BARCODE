import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

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
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
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
            body: Center(child: CircularProgressIndicator()),
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
