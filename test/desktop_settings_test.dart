import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/cloud_model_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/hive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HiveService hive;

  setUp(() async {
    Get.testMode = true;
    directory = await Directory.systemTemp.createTemp('desktop_settings_test');
    Hive.init(directory.path);
    hive = await HiveService().init();
    Get.put(hive);
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Windows persists local mode on first launch', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final settings = Get.put(SettingsController());
    expect(settings.inferenceMode.value, 'local');
    expect(hive.getSetting<String>(AppConstants.keyInferenceMode), 'local');
  });

  test('Windows preserves remembered local mode', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    final settings = Get.put(SettingsController());
    expect(settings.inferenceMode.value, 'local');
    expect(hive.getSetting<String>(AppConstants.keyInferenceMode), 'local');
  });

  test('Windows preserves an existing API selection', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await hive.setSetting(AppConstants.keyInferenceMode, 'cloud');
    final settings = Get.put(SettingsController());
    expect(settings.inferenceMode.value, 'cloud');
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform preserves local as the first-launch default', () {
      debugDefaultTargetPlatformOverride = platform;
      final settings = Get.put(SettingsController());
      expect(settings.inferenceMode.value, 'local');
    });
  }

  test('Custom API accepts a local server without an API key', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    Get.put(SettingsController());
    final cloud = Get.put(CloudModelController());
    cloud.customNameController.text = 'Local server';
    cloud.customBaseUrlController.text = 'http://127.0.0.1:1234/v1';
    cloud.customModelController.text = 'local-model';
    expect(cloud.validateCustomProvider(), isNull);
    await cloud.saveCustomProvider();
    expect(cloud.customProviderError.value, isEmpty);
    expect(cloud.isConfigured('custom'), isTrue);
    expect(cloud.canSelectModel('custom'), isTrue);
    expect(hive.getSetting<String>(AppConstants.keyCustomCloudKey), isEmpty);
    expect(hive.getSetting<String>(AppConstants.keyCloudProvider), 'custom');
    expect(hive.getSetting<String>(AppConstants.keyInferenceMode), 'cloud');
  });

  test('Custom API still validates URL and model ID', () {
    Get.put(SettingsController());
    final cloud = Get.put(CloudModelController());
    cloud.customBaseUrlController.text = 'file:///model';
    expect(
      cloud.validateCustomProvider(),
      'Enter a valid OpenAI-compatible base URL.',
    );
    cloud.customBaseUrlController.text = 'http://localhost:11434/v1';
    expect(cloud.validateCustomProvider(), 'Model ID is required.');
  });
}
