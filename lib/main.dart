import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'controllers/settings_controller.dart';
import 'core/theme.dart';
import 'core/routes.dart';
import 'services/hive_service.dart';
import 'services/inference_service.dart';
import 'services/cloud_service.dart';
import 'services/download_service.dart';
import 'services/device_info_service.dart';
import 'core/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait (mobile only)
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // Initialize Hive
  await Hive.initFlutter();

  // Register global services
  await Get.putAsync(() => HiveService().init());
  await Get.putAsync(() => DeviceInfoService().init());

  // Settings controller must be initialized before runApp for theme support
  final settingsController = Get.put(SettingsController());

  Get.put(InferenceService());
  Get.put(CloudService());
  Get.put(DownloadService());

  // Auto-configure inference settings based on device RAM
  _autoConfigureForDevice();

  // Try to reload last used local model (only on platforms that support it)
  _tryReloadModel();

  runApp(const AIChatApp());

  // Apply system UI after frame is rendered so Get.mediaQuery is available
  WidgetsBinding.instance.addPostFrameCallback((_) {
    settingsController.setThemeMode(settingsController.themeMode.value);
  });
}

/// If a model was previously loaded, try to reload it on startup.
void _tryReloadModel() async {
  final inference = Get.find<InferenceService>();
  if (!inference.supportsLocalInference) return;

  final hive = Get.find<HiveService>();
  final modelPath = hive.getSetting<String>('local_model_path');
  final modelName = hive.getSetting<String>('local_model_name');
  if (modelPath != null && modelPath.isNotEmpty) {
    await inference.loadModel(modelPath, modelName: modelName);
  }
}

/// Auto-set optimized inference params based on device RAM (only on first launch).
void _autoConfigureForDevice() {
  final hive = Get.find<HiveService>();
  final device = Get.find<DeviceInfoService>();

  // Only auto-configure if user hasn't already set values (first launch)
  final hasConfigured =
      hive.getSetting<bool>('device_auto_configured') ?? false;
  if (hasConfigured) return;

  hive.setSetting(AppConstants.keyContextSize, device.recommendedContextSize);
  hive.setSetting(AppConstants.keyMaxTokens, device.recommendedMaxTokens);
  hive.setSetting(AppConstants.keyTemperature, 0.3);
  hive.setSetting('device_auto_configured', true);

  print('[AutoConfig] Set context=${device.recommendedContextSize}, '
      'maxTokens=${device.recommendedMaxTokens} for ${device.totalRamGB.value.toStringAsFixed(1)}GB RAM');
}

class AIChatApp extends StatelessWidget {
  const AIChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    return Obx(() => GetMaterialApp(
          title: 'AI Chat',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: settings.themeMode.value,
          initialRoute: AppRoutes.home,
          getPages: AppPages.pages,
        ));
  }
}
