import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/crash_reporting_service.dart';
import 'package:privatelm/services/device_info_native.dart';
import 'package:privatelm/services/image_generation_notification_service.dart';
import 'package:privatelm/services/download_native.dart' as downloads;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows reads installed and available memory from the host', () async {
    DeviceInfoPlusWindowsPlugin.registerWith();
    final info = await getDeviceInfo();
    final total = info['totalRamGB'] as double;
    final available = info['availableRamGB'] as double;
    expect(total, greaterThan(0));
    expect(available, greaterThan(0));
    expect(available, lessThanOrEqualTo(total));
    expect(info['socHardware'], isNotEmpty);
  }, skip: !Platform.isWindows);

  test('Windows startup does not initialize mobile crash reporting', () async {
    final service = await CrashReportingService().init();
    expect(service.isEnabled, isFalse);
  }, skip: !Platform.isWindows);

  test('Windows startup does not initialize mobile notifications', () async {
    final service = ImageGenerationNotificationService();
    await service.init();
    await service.configureBackgroundService();
  }, skip: !Platform.isWindows);

  test('Windows model scans return filenames, including uppercase GGUF files', () async {
    final directory = await Directory.systemTemp.createTemp('privatelm_models');
    try {
      await File('${directory.path}\\model.GGUF').writeAsBytes([1]);
      await File('${directory.path}\\notes.txt').writeAsString('not a model');
      expect(await downloads.getDownloadedModels(directory.path), ['model.GGUF']);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
