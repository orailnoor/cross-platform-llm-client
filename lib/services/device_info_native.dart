import 'dart:io';
import 'dart:ffi';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhysical;
  @Uint64()
  external int availablePhysical;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int availableExtendedVirtual;
}

double _windowsAvailableRamGB() {
  final status = calloc<_MemoryStatus>();
  try {
    status.ref.length = sizeOf<_MemoryStatus>();
    final readMemory = DynamicLibrary.open('kernel32.dll').lookupFunction<
        Int32 Function(Pointer<_MemoryStatus>),
        int Function(Pointer<_MemoryStatus>)>('GlobalMemoryStatusEx');
    if (readMemory(status) == 0) {
      throw StateError('GlobalMemoryStatusEx failed');
    }
    return status.ref.availablePhysical / (1024 * 1024 * 1024);
  } finally {
    calloc.free(status);
  }
}

/// Detected SoC family.
enum SocFamily {
  apple,
  snapdragon,
  mediatek,
  exynos,
  googleTensor,
  unisoc,
  rockchip,
  hisilicon,
  unknown,
}

extension SocFamilyExt on SocFamily {
  String get displayName {
    switch (this) {
      case SocFamily.apple:
        return 'Apple Silicon';
      case SocFamily.snapdragon:
        return 'Qualcomm Snapdragon';
      case SocFamily.mediatek:
        return 'MediaTek Dimensity';
      case SocFamily.exynos:
        return 'Samsung Exynos';
      case SocFamily.googleTensor:
        return 'Google Tensor';
      case SocFamily.unisoc:
        return 'Unisoc';
      case SocFamily.rockchip:
        return 'Rockchip';
      case SocFamily.hisilicon:
        return 'Huawei Kirin';
      case SocFamily.unknown:
        return 'Unknown';
    }
  }

  String get recommendedQuant {
    switch (this) {
      case SocFamily.apple:
        return 'Q4_K_M (safe default) · Q5_K_M for quality';
      case SocFamily.snapdragon:
        return 'Q4_K_M (recommended) · Q4_0_4_8 on X Elite';
      case SocFamily.mediatek:
        return 'Q4_K_M (recommended)';
      case SocFamily.exynos:
        return 'Q4_K_M (recommended)';
      case SocFamily.googleTensor:
        return 'Q4_0 or Q5_K_M · AVOID Q4_K_M';
      case SocFamily.unisoc:
        return 'Q4_K_M (recommended)';
      case SocFamily.rockchip:
        return 'Q4_K_M (recommended)';
      case SocFamily.hisilicon:
        return 'Q4_K_M (recommended)';
      case SocFamily.unknown:
        return 'Q4_K_M (universal default)';
    }
  }

  String? get quantWarning {
    switch (this) {
      case SocFamily.googleTensor:
        return 'Google Tensor has a known bug with Q4_K_M quantization that produces empty or garbled responses. Use Q4_0 or Q5_K_M models instead.';
      default:
        return null;
    }
  }
}

SocFamily _detectSocFamily(String cpuinfo, String hardware) {
  final lower = cpuinfo.toLowerCase();
  final hwLower = hardware.toLowerCase();

  // Google Tensor (Pixel 6/7/8/9)
  if (RegExp(r'gs\d{3}').hasMatch(hwLower) ||
      lower.contains('google tensor')) {
    return SocFamily.googleTensor;
  }

  // Qualcomm Snapdragon
  if (hwLower.contains('qcom') ||
      hwLower.contains('qualcomm') ||
      hwLower.contains('snapdragon') ||
      RegExp(r'\bsm\d{4,}').hasMatch(hwLower) ||
      lower.contains('snapdragon')) {
    return SocFamily.snapdragon;
  }

  // MediaTek Dimensity / Helio
  if (hwLower.contains('mt6') ||
      hwLower.contains('mt8') ||
      lower.contains('mediatek') ||
      lower.contains('dimensity') ||
      lower.contains('helio')) {
    return SocFamily.mediatek;
  }

  // Samsung Exynos
  if (hwLower.contains('exynos') || lower.contains('exynos')) {
    return SocFamily.exynos;
  }

  // Unisoc
  if (hwLower.contains('unisoc') ||
      hwLower.contains('spreadtrum') ||
      RegExp(r'\bsc\d{4}').hasMatch(hwLower)) {
    return SocFamily.unisoc;
  }

  // Rockchip
  if (hwLower.contains('rockchip') || RegExp(r'\brk\d').hasMatch(hwLower)) {
    return SocFamily.rockchip;
  }

  // Huawei Hisilicon / Kirin
  if (hwLower.contains('hisilicon') ||
      lower.contains('kirin') ||
      lower.contains('hisi')) {
    return SocFamily.hisilicon;
  }

  // Apple (iOS path doesn't hit this, but keep for completeness)
  if (lower.contains('apple')) {
    return SocFamily.apple;
  }

  return SocFamily.unknown;
}

/// Native device info implementation.
Future<Map<String, dynamic>> getDeviceInfo() async {
  double totalRam = 4.0;
  double availableRam = 2.0;
  SocFamily socFamily = SocFamily.unknown;
  String hardware = '';

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

      // Detect SoC family from /proc/cpuinfo
      try {
        final cpuinfo = await File('/proc/cpuinfo').readAsString();
        hardware = RegExp(r'Hardware\s*:\s*(.+)', caseSensitive: false)
                .firstMatch(cpuinfo)
                ?.group(1)
                ?.trim() ??
            '';
        socFamily = _detectSocFamily(cpuinfo, hardware);
      } catch (_) {}
    } else if (Platform.isIOS) {
      final plugin = LlamaHostApi();
      final gpuInfo = await plugin.detectGpu();
      totalRam = gpuInfo.deviceLocalMemoryBytes / (1024 * 1024 * 1024);
      availableRam = gpuInfo.freeRamBytes / (1024 * 1024 * 1024);
      socFamily = SocFamily.apple;
    } else if (Platform.isWindows) {
      final info = await DeviceInfoPlugin().windowsInfo;
      totalRam = info.systemMemoryInMegabytes / 1024;
      availableRam = _windowsAvailableRamGB();
      hardware = info.productName;
    } else if (Platform.isMacOS) {
      totalRam = 16.0;
      availableRam = 8.0;
      socFamily = SocFamily.apple;
    }
  } catch (e) {
    print('[DeviceInfo] Failed to read device info: $e');
  }

  return {
    'totalRamGB': totalRam,
    'availableRamGB': availableRam,
    'isTensorSoC': socFamily == SocFamily.googleTensor ? 1.0 : 0.0,
    'socFamily': socFamily.index,
    'socHardware': hardware,
  };
}
