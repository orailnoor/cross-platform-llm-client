import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/redact.dart';
import '../ffi/sd_ffi_bindings.dart';
import 'app_log_service.dart';
import 'device_info_service.dart';
import 'inference_service.dart';
import 'local_image_service.dart';

class CrashReportingService extends GetxService {
  bool _enabled = false;
  bool _reporting = false;
  PackageInfo? _packageInfo;
  AndroidDeviceInfo? _androidInfo;

  bool get isEnabled => _enabled;

  Future<CrashReportingService> init() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return this;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _packageInfo = await PackageInfo.fromPlatform();
      if (Platform.isAndroid) {
        _androidInfo = await DeviceInfoPlugin().androidInfo;
      }
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
      _enabled = true;
      await updateContext(reason: 'startup');
      log('Crash reporting initialized');
    } catch (e) {
      _enabled = false;
      // Firebase config is intentionally allowed to be absent in local/dev builds.
      // Once google-services.json is added, this starts reporting automatically.
      // ignore: avoid_print
      print('[CrashReporting] Disabled: $e');
    }
    return this;
  }

  Future<void> recordFlutterFatal(FlutterErrorDetails details) async {
    if (!_enabled) return;
    await updateContext(reason: 'flutter_fatal');
    await FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  }

  Future<void> recordFatal(Object error, StackTrace stack,
      {String reason = 'fatal'}) async {
    if (!_enabled) return;
    await updateContext(reason: reason);
    await FirebaseCrashlytics.instance.recordError(
      _redactError(error),
      stack,
      reason: redactSecrets(reason),
      fatal: true,
    );
  }

  Future<void> recordNonFatal(
    Object error, {
    StackTrace? stack,
    String reason = 'nonfatal',
    Map<String, Object?> extra = const {},
  }) async {
    if (!_enabled || _reporting) return;
    _reporting = true;
    try {
      await updateContext(reason: reason, extra: extra);
      await FirebaseCrashlytics.instance.recordError(
        _redactError(error),
        stack ?? StackTrace.current,
        reason: redactSecrets(reason),
        fatal: false,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[CrashReporting] Non-fatal report failed: $e');
    } finally {
      _reporting = false;
    }
  }

  void log(String message) {
    if (!_enabled) return;
    FirebaseCrashlytics.instance.log(_trim(redactSecrets(message), 1000));
  }

  Future<void> updateContext({
    String reason = 'context',
    Map<String, Object?> extra = const {},
  }) async {
    if (!_enabled) return;
    final keys = <String, Object?>{
      'report_reason': reason,
      ..._packageKeys(),
      ..._deviceKeys(),
      ..._settingsKeys(),
      ..._textModelKeys(),
      ..._imageModelKeys(),
      ..._generationKeys(),
      ...extra,
    };

    for (final entry in keys.entries) {
      await _setKey(entry.key, entry.value);
    }
    final logs = _importantLogs();
    if (logs.isNotEmpty) {
      await _setKey('recent_important_logs', logs);
      FirebaseCrashlytics.instance.log(logs);
    }
  }

  Map<String, Object?> _packageKeys() {
    final info = _packageInfo;
    if (info == null) return {};
    return {
      'app_name': info.appName,
      'app_package': info.packageName,
      'app_version': info.version,
      'app_build': info.buildNumber,
    };
  }

  Map<String, Object?> _deviceKeys() {
    final keys = <String, Object?>{
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
    };
    if (Get.isRegistered<DeviceInfoService>()) {
      final device = Get.find<DeviceInfoService>();
      keys.addAll({
        'device_total_ram_gb': device.totalRamGB.value,
        'device_available_ram_gb': device.availableRamGB.value,
        'device_tier': device.deviceTier.value,
        'device_soc_family': device.socFamily.value.name,
        'device_soc_hardware': _trim(device.socHardware.value, 120),
        'device_tensor_soc': device.isTensorSoC.value,
      });
    }
    final android = _androidInfo;
    if (android != null) {
      keys.addAll({
        'android_manufacturer': android.manufacturer,
        'android_model': android.model,
        'android_device': android.device,
        'android_hardware': android.hardware,
        'android_sdk': android.version.sdkInt,
        'android_release': android.version.release,
      });
    }
    return keys;
  }

  Map<String, Object?> _settingsKeys() {
    if (!Get.isRegistered<SettingsController>()) return {};
    final settings = Get.find<SettingsController>();
    return {
      'inference_mode': settings.inferenceMode.value,
      'image_steps': settings.imageSteps.value,
      'image_size_setting': settings.imageGenSize.value == 0
          ? 'auto'
          : settings.imageGenSize.value,
      'image_backend_setting': settings.imageGenBackend.value.displayName,
      'image_force_cpu': settings.imageGenForceCpu.value,
      'image_gpu_safety_mb': settings.imageGenGpuGuardMb.value,
      'litert_performance_mode': settings.liteRtPerformanceMode.value,
    };
  }

  Map<String, Object?> _textModelKeys() {
    if (!Get.isRegistered<InferenceService>()) return {};
    final inference = Get.find<InferenceService>();
    return {
      'text_model_loaded': inference.isModelLoaded.value,
      'text_model_name': _safeName(inference.loadedModelName.value),
      'text_model_runtime': inference.loadedModelRuntime.value,
      'text_model_backend': inference.loadedBackend.value,
      'text_gpu_accelerated': inference.isGpuAccelerated.value,
      'text_gpu_name': _trim(inference.gpuName.value, 120),
      'text_gpu_layers': inference.gpuLayersUsed.value,
      'text_context_used': inference.contextTokensUsed.value,
      'text_context_total': inference.contextTokensTotal.value,
    };
  }

  Map<String, Object?> _imageModelKeys() {
    if (!Get.isRegistered<LocalImageService>()) return {};
    final image = Get.find<LocalImageService>();
    return {
      'image_model_loaded': image.isModelLoaded.value,
      'image_model_name': _safeName(image.loadedModelName.value),
      'image_backend_actual': image.currentBackend.value.displayName,
      'image_backend_is_gpu': image.currentBackend.value != Backend.cpu,
      'image_gpu_vendor': image.gpuVendor.value,
      'image_generation_running': image.isGenerating.value,
      'image_latest_log': _trim(image.latestLog.value, 200),
    };
  }

  Map<String, Object?> _generationKeys() {
    if (!Get.isRegistered<ChatController>()) return {};
    final chat = Get.find<ChatController>();
    final start = chat.imageGenStartTime.value;
    return {
      'chat_is_loading': chat.isLoading.value,
      'chat_is_streaming': chat.isStreaming.value,
      'image_gen_step': chat.imageGenStep.value,
      'image_gen_total': chat.imageGenTotal.value,
      'image_gen_eta_secs': chat.imageGenEstimatedSecs.value,
      'image_gen_decoding': chat.imageGenDecoding.value,
      'image_gen_elapsed_secs':
          start == null ? 0 : DateTime.now().difference(start).inSeconds,
    };
  }

  String _importantLogs() {
    if (!Get.isRegistered<AppLogService>()) return '';
    final logs = Get.find<AppLogService>()
        .importantEntries
        .take(12)
        .map((entry) => entry.format())
        .join('\n---\n');
    return _trim(logs, 3500);
  }

  Future<void> _setKey(String key, Object? value) async {
    final safeKey = key.length > 40 ? key.substring(0, 40) : key;
    final safeValue = value ?? '';
    if (safeValue is bool) {
      await FirebaseCrashlytics.instance.setCustomKey(safeKey, safeValue);
    } else if (safeValue is int) {
      await FirebaseCrashlytics.instance.setCustomKey(safeKey, safeValue);
    } else if (safeValue is double) {
      await FirebaseCrashlytics.instance.setCustomKey(safeKey, safeValue);
    } else {
      await FirebaseCrashlytics.instance.setCustomKey(
          safeKey, _trim(redactSecrets(safeValue.toString()), 900));
    }
  }

  /// Keeps the original error object (for Crashlytics grouping) unless its
  /// text contains a credential, in which case a masked string is sent.
  Object _redactError(Object error) {
    final text = error.toString();
    final redacted = redactSecrets(text);
    return redacted == text ? error : redacted;
  }

  String _safeName(String value) {
    if (value.trim().isEmpty) return '';
    final normalized = value.replaceAll('\\', '/');
    return _trim(normalized.split('/').last, 160);
  }

  String _trim(String value, int max) {
    if (value.length <= max) return value;
    return '${value.substring(0, max - 3)}...';
  }
}
