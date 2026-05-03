import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

// dart:io is conditionally available — only used behind kIsWeb guards
import 'device_info_native.dart' if (dart.library.html) 'device_info_web.dart'
    as platform_info;

/// Device capability detection — reads RAM to set safe inference limits.
/// Cross-platform: works on Android/iOS natively, defaults on web.
class DeviceInfoService extends GetxService {
  final totalRamGB = 0.0.obs;
  final availableRamGB = 0.0.obs;
  final deviceTier = ''.obs; // 'low', 'mid', 'high', 'ultra'

  // Recommended limits based on device RAM
  int get recommendedContextSize => _tierConfig['contextSize']!;
  int get recommendedMaxTokens => _tierConfig['maxTokens']!;
  int get maxSafeContextSize => _tierConfig['maxContextSize']!;
  int get maxSafeTokens => _tierConfig['maxSafeTokens']!;

  Map<String, int> get _tierConfig {
    final ram = totalRamGB.value;
    if (ram <= 4) {
      return {
        'contextSize': 1024,
        'maxTokens': 256,
        'maxContextSize': 2048,
        'maxSafeTokens': 512,
      };
    } else if (ram <= 6) {
      return {
        'contextSize': 2048,
        'maxTokens': 512,
        'maxContextSize': 4096,
        'maxSafeTokens': 1024,
      };
    } else if (ram <= 8) {
      return {
        'contextSize': 4096,
        'maxTokens': 1024,
        'maxContextSize': 8192,
        'maxSafeTokens': 2048,
      };
    } else if (ram <= 12) {
      return {
        'contextSize': 4096,
        'maxTokens': 2048,
        'maxContextSize': 8192,
        'maxSafeTokens': 4096,
      };
    } else {
      return {
        'contextSize': 8192,
        'maxTokens': 4096,
        'maxContextSize': 16384,
        'maxSafeTokens': 4096,
      };
    }
  }

  Future<DeviceInfoService> init() async {
    await refreshMemoryInfo();

    // Classify device tier
    final ram = totalRamGB.value;
    if (ram <= 4) {
      deviceTier.value = 'low';
    } else if (ram <= 6) {
      deviceTier.value = 'mid';
    } else if (ram <= 8) {
      deviceTier.value = 'high';
    } else {
      deviceTier.value = 'ultra';
    }

    print('[DeviceInfo] RAM: ${totalRamGB.value.toStringAsFixed(1)}GB total, '
        '${availableRamGB.value.toStringAsFixed(1)}GB available, '
        'tier: ${deviceTier.value}');
    return this;
  }

  Future<void> refreshMemoryInfo() async {
    final info = await platform_info.getDeviceInfo();
    totalRamGB.value = info['totalRamGB'] as double;
    availableRamGB.value = info['availableRamGB'] as double;
  }

  String get tierDescription {
    switch (deviceTier.value) {
      case 'low':
        return '⚠️ Low RAM (${totalRamGB.value.toStringAsFixed(1)}GB) — Use small models only';
      case 'mid':
        return '📱 Mid-range (${totalRamGB.value.toStringAsFixed(1)}GB) — Good for 1-3B models';
      case 'high':
        return '💪 High-end (${totalRamGB.value.toStringAsFixed(1)}GB) — Can run 3-7B models';
      case 'ultra':
        return '🚀 Ultra (${totalRamGB.value.toStringAsFixed(1)}GB) — Full performance mode';
      default:
        return '📱 ${totalRamGB.value.toStringAsFixed(1)}GB RAM detected';
    }
  }
}
