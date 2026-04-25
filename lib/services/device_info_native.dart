import 'dart:io';

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Native (Android/iOS/macOS/Linux) device info implementation.
Future<Map<String, double>> getDeviceInfo() async {
  double totalRam = 4.0;
  double availableRam = 2.0;

  try {
    if (Platform.isAndroid || Platform.isLinux) {
      final meminfo = await File('/proc/meminfo').readAsString();
      final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
      if (totalMatch != null) {
        totalRam = int.parse(totalMatch.group(1)!) / 1024 / 1024;
      }
      final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
      if (availMatch != null) {
        availableRam = int.parse(availMatch.group(1)!) / 1024 / 1024;
      }
    } else if (Platform.isIOS) {
      final plugin = LlamaHostApi();
      final gpuInfo = await plugin.detectGpu();
      totalRam = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      availableRam = gpuInfo.freeRamBytes / (1024 * 1024 * 1024);
    } else if (Platform.isMacOS) {
      totalRam = 16.0;
      availableRam = 8.0;
    }
  } catch (e) {
    print('[DeviceInfo] Failed to read RAM: $e');
  }

  return {'totalRamGB': totalRam, 'availableRamGB': availableRam};
}
