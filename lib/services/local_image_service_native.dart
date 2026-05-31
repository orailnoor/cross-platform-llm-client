import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:sd_flutter_android/sd_flutter_android.dart';
import '../core/constants.dart';
import '../ffi/sd_ffi_bindings.dart';
import 'app_log_service.dart';
import 'hive_service.dart';
import 'sd_isolate_processor.dart';

class LocalImageService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  final isModelLoaded = false.obs;
  final isLoadingModel = false.obs;
  final isGenerating = false.obs;
  final progress = 0.0.obs;
  final loadedModelName = ''.obs;
  final gpuVendor = 'unknown'.obs;
  final isUsingGpu = false.obs;
  final latestLog = ''.obs;
  final currentBackend = Backend.cpu.obs;
  final currentQuantization = QuantizationType.q4_0.obs;

  SdIsolateProcessor? _processor;

  String? get lastModelPath =>
      _hive.getSetting<String>(AppConstants.keyImageModelPath);
  String? get lastModelName =>
      _hive.getSetting<String>(AppConstants.keyImageModelName);

  /// Pick the best GPU backend for a detected vendor.
  /// Returns null if no GPU backend is suitable.
  List<Backend> _backendPreference(String vendor) {
    switch (vendor) {
      case 'adreno':
        // Adreno: OpenCL is best — Vulkan is blacklisted due to GGML shader compiler crashes
        return [Backend.opencl, Backend.cpu];
      case 'mali':
      // Mali: Vulkan is generally more stable and faster than OpenCL
      case 'xclipse':
        return [Backend.vulkan, Backend.cpu];
      case 'powervr':
      case 'imagination':
        // PowerVR / Imagination: try Vulkan
        return [Backend.vulkan, Backend.cpu];
      case 'nvidia':
        // NVIDIA Tegra: Vulkan preferred, OpenCL fallback
        return [Backend.vulkan, Backend.opencl, Backend.cpu];
      case 'intel':
        return [Backend.vulkan, Backend.opencl, Backend.cpu];
      case 'amd':
        return [Backend.vulkan, Backend.opencl, Backend.cpu];
      default:
        return [Backend.vulkan, Backend.opencl, Backend.cpu];
    }
  }

  List<Backend> _availableBackendsFor(String vendor, bool useGpu) {
    if (!useGpu) return [Backend.cpu];
    final available = <Backend>[];
    for (final backend in _backendPreference(vendor)) {
      if (backend == Backend.cpu || backend.isAvailable) {
        available.add(backend);
      }
    }
    if (!available.contains(Backend.cpu)) available.add(Backend.cpu);
    return available;
  }

  Future<bool> _tryLoadWithBackend({
    required Backend backend,
    required String modelPath,
    required String? taesdPath,
    required double maxVramGb,
  }) async {
    final isGpuBackend = backend != Backend.cpu;
    print(
        '[LocalImageService] Creating SdIsolateProcessor (backend=${backend.displayName}, quant=${currentQuantization.value.displayName})...');
    _processor = SdIsolateProcessor(
      modelPath: modelPath,
      nThreads: 0,
      flashAttn: !isGpuBackend,
      vaeTiling: true,
      taesdPath: taesdPath,
      backend: backend,
      quantizationType: currentQuantization.value,
      offloadParamsToCpu: isGpuBackend,
      enableMmap: true,
      keepVaeOnCpu: isGpuBackend,
      maxVram: maxVramGb,
    );

    _processor!.logStream.listen((log) {
      latestLog.value = log.message;
    });

    final modelLoaded = await _processor!.modelLoaded
        .timeout(const Duration(seconds: 120), onTimeout: () => false);
    if (!modelLoaded) {
      await _processor?.dispose();
      _processor = null;
    }
    return modelLoaded;
  }

  @override
  void onInit() {
    super.onInit();
    // Restore saved backend / quantization preferences
    final savedBackendIndex = _hive.getSetting<int>(
        AppConstants.keyImageGenBackend,
        defaultValue: Backend.cpu.index);
    final savedQuantIndex = _hive.getSetting<int>(
        AppConstants.keyImageGenQuantization,
        defaultValue: QuantizationType.q4_0.index);
    if (savedBackendIndex != null &&
        savedBackendIndex >= 0 &&
        savedBackendIndex < Backend.values.length) {
      currentBackend.value = Backend.values[savedBackendIndex];
    }
    if (savedQuantIndex != null &&
        savedQuantIndex >= 0 &&
        savedQuantIndex < QuantizationType.values.length) {
      currentQuantization.value = QuantizationType.values[savedQuantIndex];
    }
    // Force Q4_0 for speed — override any saved FP16 setting
    currentQuantization.value = QuantizationType.q4_0;
  }

  Future<String> loadModel(String modelPath,
      {String? modelName, String? taesdPath}) async {
    if (isLoadingModel.value) return 'ERROR: Model is already loading.';

    try {
      if (isModelLoaded.value) {
        await unloadModel();
      }

      isLoadingModel.value = true;
      progress.value = 0.0;

      print('[LocalImageService] loadModel called with path: $modelPath');
      if (taesdPath != null) {
        print('[LocalImageService] TAESD path: $taesdPath');
      }

      int modelSizeMb = 0;
      try {
        final file = File(modelPath);
        final exists = await file.exists();
        print('[LocalImageService] File exists: $exists');
        if (exists) {
          final length = await file.length();
          modelSizeMb = (length / (1024 * 1024)).round();
          print('[LocalImageService] File size: $length bytes');
        }
      } catch (e) {
        print('[LocalImageService] File check error: $e');
      }

      String vendor = 'unknown';
      bool useGpu = true;
      if (Platform.isAndroid) {
        try {
          vendor = await SdFlutterAndroid.detectGpuVendor();
          gpuVendor.value = vendor;
          print('[LocalImageService] GPU vendor detected: $vendor');
        } catch (e) {
          print('[LocalImageService] GPU detection failed: $e');
        }
      }

      final forceCpu = _hive.getSetting<bool>(
              AppConstants.keyImageGenForceCpu,
              defaultValue: AppConstants.defaultImageGenForceCpu) ??
          AppConstants.defaultImageGenForceCpu;
      if (forceCpu) {
        useGpu = false;
        print('[LocalImageService] User override - forcing CPU');
      }

      final gpuGuardMb = _hive.getSetting<int>(
              AppConstants.keyImageGenGpuGuardMb,
              defaultValue: AppConstants.defaultImageGenGpuGuardMb) ??
          AppConstants.defaultImageGenGpuGuardMb;
      if (useGpu && gpuGuardMb > 0 && modelSizeMb >= gpuGuardMb) {
        useGpu = false;
        print(
            '[LocalImageService] Model ${modelSizeMb}MB exceeds GPU safety ${gpuGuardMb}MB; using CPU for mobile stability');
      }

      final requestedBackend = currentBackend.value;
      if (!useGpu && requestedBackend != Backend.cpu) {
        print(
            '[LocalImageService] Ignoring saved GPU backend ${requestedBackend.displayName} for this model/device');
      }
      final candidateBackends = requestedBackend == Backend.cpu || !useGpu
          ? _availableBackendsFor(vendor, useGpu)
          : <Backend>[requestedBackend, Backend.cpu];
      print(
          '[LocalImageService] Backend candidates for $vendor: ${candidateBackends.map((b) => b.displayName).join(' -> ')}');

      int totalRamMb = 4096;
      if (Platform.isAndroid) {
        try {
          totalRamMb = await SdFlutterAndroid.getDeviceMemory();
          print('[LocalImageService] Device RAM: ${totalRamMb}MB');
        } catch (e) {
          print('[LocalImageService] Memory detection failed: $e');
        }
      }
      final maxVramGb = candidateBackends.first == Backend.cpu
          ? 0.0
          : (totalRamMb / 1024 * 0.22).clamp(0.75, 1.75);
      print(
          '[LocalImageService] Max graph VRAM limit: ${maxVramGb.toStringAsFixed(2)}GB');

      for (final backend in candidateBackends) {
        print('[LocalImageService] Trying backend: ${backend.displayName}');
        final modelLoaded = await _tryLoadWithBackend(
          backend: backend,
          modelPath: modelPath,
          taesdPath: taesdPath,
          maxVramGb: backend == Backend.cpu ? 0.0 : maxVramGb,
        );
        if (!modelLoaded) {
          print(
              '[LocalImageService] Backend failed: ${backend.displayName}; trying fallback');
          continue;
        }

        currentBackend.value = backend;
        isUsingGpu.value = backend != Backend.cpu;
        isModelLoaded.value = true;
        isLoadingModel.value = false;
        loadedModelName.value = modelName ?? modelPath.split('/').last;
        await _hive.setSetting(AppConstants.keyImageModelPath, modelPath);
        await _hive.setSetting(
            AppConstants.keyImageModelName, loadedModelName.value);
        await _hive.setSetting(
            AppConstants.keyImageGenBackend, currentBackend.value.index);
        await _hive.setSetting(AppConstants.keyImageGenQuantization,
            currentQuantization.value.index);
        return 'Image model loaded successfully.';
      }

      isModelLoaded.value = false;
      isLoadingModel.value = false;
      Get.find<AppLogService>().error(
        'Image model load failed',
        details:
            'All backend candidates failed. model=${modelName ?? modelPath.split('/').last}, vendor=$vendor, sizeMb=$modelSizeMb',
      );
      return 'Could not load this model. Try CyberRealistic, Realistic Vision, or AbsoluteReality - these work reliably on most devices.\n\nTechnical detail: All backend candidates failed.';
    } catch (e) {
      isModelLoaded.value = false;
      isLoadingModel.value = false;
      Get.find<AppLogService>().error('Image model load exception',
          details:
              'model=${modelName ?? modelPath.split('/').last}, error=$e');
      return 'Could not load this model. Try CyberRealistic, Realistic Vision, or AbsoluteReality - these work reliably on most devices.\n\nTechnical detail: $e';
    }
  }

  Future<void> unloadModel() async {
    await _processor?.dispose();
    _processor = null;
    isModelLoaded.value = false;
    loadedModelName.value = '';
    gpuVendor.value = 'unknown';
    isUsingGpu.value = false;
    await _hive.setSetting(AppConstants.keyImageModelPath, '');
    await _hive.setSetting(AppConstants.keyImageModelName, '');
  }

  /// Change the inference backend (CPU / Vulkan / etc).
  /// The new backend takes effect on the next [loadModel] call.
  void setBackend(Backend backend) {
    currentBackend.value = backend;
    _hive.setSetting(AppConstants.keyImageGenBackend, backend.index);
  }

  /// Change the model quantization type.
  /// The new quantization takes effect on the next [loadModel] call.
  void setQuantization(QuantizationType type) {
    currentQuantization.value = type;
    _hive.setSetting(AppConstants.keyImageGenQuantization, type.index);
  }

  void cancelGeneration() {
    if (isGenerating.value) {
      print('[LocalImageService] Generation cancelled by user');
      isGenerating.value = false;
    }
  }

  Future<Uint8List?> generateImage({
    required String prompt,
    void Function(int step, int totalSteps)? onProgress,
  }) async {
    if (!isModelLoaded.value || _processor == null) return null;
    if (isGenerating.value) return null;

    isGenerating.value = true;
    StreamSubscription? progressSub;
    StreamSubscription? logSub;

    try {
      final requestedSteps = _hive.getSetting<int>(AppConstants.keyImageSteps,
              defaultValue: AppConstants.defaultImageSteps) ??
          AppConstants.defaultImageSteps;
      final effectiveSteps = currentBackend.value == Backend.cpu
          ? requestedSteps.clamp(1, 20).toInt()
          : requestedSteps.clamp(1, 8).toInt();

      int availableRamMb = 0;
      if (Platform.isAndroid) {
        try {
          availableRamMb = await SdFlutterAndroid.getAvailableMemory();
        } catch (e) {
          print('[LocalImageService] Available memory check failed: $e');
        }
      }

      final selectedImageSize = _hive.getSetting<int>(
              AppConstants.keyImageGenSize,
              defaultValue: AppConstants.defaultImageGenSize) ??
          AppConstants.defaultImageGenSize;
      final autoImageSize = currentBackend.value == Backend.cpu
          ? (availableRamMb > 0 && availableRamMb < 1800 ? 320 : 384)
          : (availableRamMb > 0 && availableRamMb < 1800 ? 256 : 320);
      final imageSize = selectedImageSize == 0
          ? autoImageSize
          : selectedImageSize.clamp(256, 512).toInt();

      print(
          '[LocalImageService] generateImage start: prompt="$prompt", backend=${currentBackend.value.displayName}, size=${imageSize}x$imageSize, steps=$effectiveSteps, availableRam=${availableRamMb}MB, sizeMode=${selectedImageSize == 0 ? "auto" : "fixed"}');

      // Subscribe to progress and log streams
      progressSub = _processor!.progressStream.listen((update) {
        print(
            '[LocalImageService] Progress: step ${update.step}/${update.totalSteps}');
        onProgress?.call(update.step, update.totalSteps);
      });
      logSub = _processor!.logStream.listen((log) {
        print('[LocalImageService] Log [L${log.level}]: ${log.message}');
        latestLog.value = log.message;
      });

      final result = await _processor!.generate(
        prompt: prompt,
        width: imageSize,
        height: imageSize,
        steps: effectiveSteps,
        // Future: expose width, height, seed, cfg, negativePrompt, sampleMethod from settings
      );

      await progressSub.cancel();
      await logSub.cancel();

      print(
          '[LocalImageService] Generation result: error=${result.error}, bytes=${result.rgbBytes?.length}, ${result.width}x${result.height}');

      if (result.error != null || result.rgbBytes == null) {
        print('[LocalImageService] Generation failed: ${result.error}');
        Get.find<AppLogService>().error(
          'Local image generation failed',
          details:
              'backend=${currentBackend.value.displayName}, model=${loadedModelName.value}, error=${result.error ?? "empty image bytes"}',
        );
        isGenerating.value = false;
        return null;
      }

      // Convert raw RGB to PNG
      // TODO: switch to ui.decodeImageFromPixels for GPU-accelerated decode
      print(
          '[LocalImageService] Encoding ${result.width}x${result.height} RGB to PNG...');
      final image = img.Image.fromBytes(
        width: result.width,
        height: result.height,
        bytes: result.rgbBytes!.buffer,
        numChannels: 3,
      );
      final pngBytes = Uint8List.fromList(img.encodePng(image));
      print('[LocalImageService] PNG encoded: ${pngBytes.length} bytes');

      isGenerating.value = false;
      return pngBytes;
    } catch (e, stack) {
      await progressSub?.cancel();
      await logSub?.cancel();
      isGenerating.value = false;
      print('[LocalImageService] Native Generation Error: $e');
      print('[LocalImageService] Stack: $stack');
      Get.find<AppLogService>().error('Local image generation exception',
          details:
              'backend=${currentBackend.value.displayName}, model=${loadedModelName.value}, error=$e');
      return null;
    }
  }
}
