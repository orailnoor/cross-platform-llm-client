import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:google_fonts/src/google_fonts_base.dart' as fonts;
import 'package:hive/hive.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/controllers/cloud_model_controller.dart';
import 'package:privatelm/controllers/model_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/platform_capabilities.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/core/ui.dart' show AppRow;
import 'package:privatelm/services/device_info_service.dart';
import 'package:privatelm/services/download_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/local_image_service.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/views/cluster_view.dart';
import 'package:privatelm/views/server_view.dart';
import 'package:privatelm/views/model_view.dart';
import 'package:privatelm/views/settings_view.dart';

class _InferenceService extends InferenceService {
  @override
  bool get supportsLocalInference =>
      PlatformCapabilities.supportsLocalInference;
}

class _ModelController extends ModelController {
  @override
  Future<void> refreshDownloaded() async {}
}

class _ClusterService extends ClusterService {
  @override
  Future<void> refreshWorkerStatus() async {}
  @override
  Future<void> refreshWifiAddress() async {
    wifiAddress.value = '192.168.1.25';
  }
  @override
  Future<List<ClusterWorker>> relocateWorkers() async => [];
}

class _CloudModelController extends CloudModelController {
  Future<void>? pendingSave;

  @override
  Future<void> saveCustomProvider() {
    final save = super.saveCustomProvider();
    pendingSave = save;
    return save;
  }
}

class _FontManifest implements AssetManifest {
  @override
  List<String> listAssets() => [
        for (final family in ['Inter', 'FiraCode'])
          for (final weight in [
            'Thin',
            'ExtraLight',
            'Light',
            'Regular',
            'Medium',
            'SemiBold',
            'Bold',
            'ExtraBold',
            'Black',
          ])
            '$family-$weight.ttf',
      ];

  @override
  List<AssetMetadata>? getAssetVariants(String key) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SettingsController settings;
  late _CloudModelController cloud;
  late ModelController models;

  setUp(() async {
    Get.testMode = true;
    fonts.assetManifest = _FontManifest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = const StringCodec().decodeMessage(message);
      if (key == 'AssetManifest.bin') {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      if (key != null && key == 'assets/icons/appicon.png') {
        return ByteData.sublistView(
            await File.fromUri(Directory.current.uri.resolve(key)).readAsBytes());
      }
      return key != null && key.endsWith('.ttf') ? ByteData(0) : null;
    });
    directory = await Directory.systemTemp.createTemp('model_view_test');
    Hive.init(directory.path);
    Get.put(await HiveService().init());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await directory.delete(recursive: true);
    fonts.assetManifest = null;
    fonts.clearCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  Future<void> showModels(WidgetTester tester) async {
    await tester.runAsync(() async {
      settings = Get.put(SettingsController());
      cloud = _CloudModelController();
      Get.put<CloudModelController>(cloud);
      Get.put(DownloadService());
      Get.put<InferenceService>(_InferenceService());
      Get.put(LocalImageService());
      models = Get.put<ModelController>(_ModelController());
      await Get.find<HiveService>().settingsBox.flush();
    });
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GetMaterialApp(home: ModelView()));
    await tester.pumpAndSettle();
  }

  testWidgets('Windows shows API providers without reactive build errors',
      (tester) async {
    await showModels(tester);
    await tester.tap(find.text('Cloud'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Custom API'), findsOneWidget);
    expect(find.text('Import'), findsNothing);
    expect(find.text('My models'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'Windows can configure and select an unauthenticated local server',
      (tester) async {
    await showModels(tester);
    await tester.tap(find.text('Cloud'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Custom API'));
    await tester.tap(find.text('Custom API'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Custom provider'), findsOneWidget);

    Finder field(TextEditingController controller) => find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller == controller);
    await tester.enterText(field(cloud.customNameController), 'LM Studio');
    await tester.enterText(
        field(cloud.customBaseUrlController), 'http://127.0.0.1:1234/v1');
    await tester.enterText(field(cloud.customModelController), 'local-model');
    await tester.ensureVisible(find.text('Save and select'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save and select'));
      await cloud.pendingSave!;
    });
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(cloud.customProviderError.value, isEmpty);
    expect(settings.cloudProvider.value, 'custom');
    expect(settings.customCloudKey.value, isEmpty);
    expect(find.text('Custom provider'), findsNothing);
    expect(find.text('LM Studio'), findsWidgets);
    expect(find.text('local-model'), findsWidgets);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  for (final platform in [
    TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.windows,
  ]) {
    testWidgets('$platform retains local model navigation', (tester) async {
      await showModels(tester);
      expect(tester.takeException(), isNull);
      expect(models.modelScope.value, 'local');
      expect(find.text('My models'), findsOneWidget);
      expect(find.text('Browse'), findsOneWidget);
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Import'), findsWidgets);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('Windows master exposes LAN pairing without a mobile QR scanner',
      (tester) async {
    await showModels(tester);
    final cluster = Get.put<ClusterService>(_ClusterService());
    cluster.enabled.value = true;
    await tester.pumpWidget(const GetMaterialApp(home: ClusterView()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Device cluster'), findsOneWidget);
    expect(find.text('Master'), findsOneWidget);
    expect(find.text('Worker'), findsOneWidget);
    expect(find.text('Add worker IP or pairing link'), findsOneWidget);
    expect(find.text('Find nearby'), findsOneWidget);
    expect(find.text('Scan a worker\'s QR code'), findsNothing);
    expect(find.textContaining('no authentication'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows local inference does not enable mobile API hosting',
      (tester) async {
    await showModels(tester);
    await tester.pumpWidget(const GetMaterialApp(home: ServerView()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('API model hosting is currently supported'), findsOneWidget);
    expect(find.text('Allow network access'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows saves worker memory choice and locks it while sharing',
      (tester) async {
    await showModels(tester);
    Get.put(DeviceInfoService());
    final cluster = Get.put<ClusterService>(_ClusterService());
    expect(cluster.workerUsesGpu.value, isTrue);
    await tester.pumpWidget(const GetMaterialApp(home: SettingsView()));
    await tester.pumpAndSettle();
    final memorySwitch = find.descendant(
        of: find.widgetWithText(AppRow, 'Use GPU memory for workers'),
        matching: find.byType(Switch));
    await tester.ensureVisible(memorySwitch);
    expect(tester.widget<Switch>(memorySwitch).value, isTrue);
    await tester.runAsync(() async {
      await tester.tap(memorySwitch);
      await Get.find<HiveService>().settingsBox.flush();
    });
    await tester.pumpAndSettle();
    expect(cluster.workerUsesGpu.value, isFalse);
    expect(
        Get.find<HiveService>()
            .getSetting<bool>(AppConstants.keyClusterWorkerUsesGpu),
        isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await Get.delete<ClusterService>(force: true);
    final restored = Get.put<ClusterService>(_ClusterService());
    expect(restored.workerUsesGpu.value, isFalse);
    restored.worker.value = const ClusterWorkerStatus(
        state: 'running', peer: '192.168.1.24', memoryBackend: 'ram');
    await tester.pumpWidget(const GetMaterialApp(home: SettingsView()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(memorySwitch);
    expect(tester.widget<Switch>(memorySwitch).onChanged, isNull);
    expect(find.text('Set Device cluster to Off before changing memory.'),
        findsOneWidget);
    restored.worker.value = const ClusterWorkerStatus(state: 'stopped');
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(memorySwitch).onChanged, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(memorySwitch);
      await Get.find<HiveService>().settingsBox.flush();
    });
    await tester.pumpAndSettle();
    expect(restored.workerUsesGpu.value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await Get.delete<ClusterService>(force: true);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform does not expose Windows worker memory settings',
        (tester) async {
      await showModels(tester);
      Get.put(DeviceInfoService());
      Get.put<ClusterService>(_ClusterService());
      await tester.pumpWidget(const GetMaterialApp(home: SettingsView()));
      await tester.pumpAndSettle();
      expect(find.text('Use GPU memory for workers'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  for (final backend in ['gpu', 'ram']) {
    testWidgets('Windows worker labels $backend memory accurately',
        (tester) async {
      await showModels(tester);
      final cluster = Get.put<ClusterService>(_ClusterService());
      cluster.worker.value = ClusterWorkerStatus(
          state: 'running', peer: '192.168.1.24', memoryBackend: backend);
      await tester.pumpWidget(const GetMaterialApp(home: ClusterView()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(backend == 'gpu' ? 'GPU budget' : 'Available system RAM'),
          findsOneWidget);
      expect(find.text('Process RAM'), findsOneWidget);
      expect(find.text('System RAM speed'), findsOneWidget);
      expect(find.text('Free at start'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await Get.delete<ClusterService>(force: true);
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
  }
}
