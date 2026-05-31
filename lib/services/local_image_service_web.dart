import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:web/web.dart' as web;
import '../core/constants.dart';
import '../ffi/sd_ffi_bindings.dart'
    if (dart.library.html) '../ffi/sd_ffi_bindings_web.dart';
import 'hive_service.dart';

// ── JS interop types for the WebGPU engine ──

@JS()
extension type JSWindow._(JSObject _) implements JSObject {
  external set onWebGpuImageLog(JSFunction? value);
  external set onWebGpuImageReady(JSFunction? value);
  external set onWebGpuImageResult(JSFunction? value);
  external set onWebGpuImageProgress(JSFunction? value);
  external set onWebGpuImageError(JSFunction? value);
  external set onWebGpuImageProgressDart(JSFunction? value);

  external JSFunction? get initWebGpuImageEngine;
  external JSFunction? get generateWebGpuImage;

  external JSObject? get webGpuImageEngine;
}

@JS()
extension type JSEngine(JSObject _) implements JSObject {
  external JSFunction get isReady;
}

/// Web-specific image generation service using WebGPU via JS interop.
/// Communicates with web/webgpu_engine.js which runs HuggingFace Transformers.js
/// with WebGPU backend (implemented on Metal on macOS/iOS Safari).
class LocalImageService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  final isModelLoaded = false.obs;
  final isLoadingModel = false.obs;
  final isGenerating = false.obs;
  final progress = 0.0.obs;
  final loadedModelName = ''.obs;
  final gpuVendor = 'webgpu'.obs;
  final isUsingGpu = true.obs;
  final latestLog = ''.obs;
  final currentBackend = Backend.cpu.obs;
  final currentQuantization = QuantizationType.q4_0.obs;

  String? get lastModelPath => null;
  String? get lastModelName =>
      _hive.getSetting<String>(AppConstants.keyImageModelName);

  Completer<String>? _loadCompleter;
  Completer<Uint8List?>? _generateCompleter;
  Timer? _initTimeout;

  JSWindow get _win => web.window as JSWindow;

  @override
  void onInit() {
    super.onInit();
    _setupJsCallbacks();
    _syncReadyState();
  }

  void _syncReadyState() {
    try {
      final engine = JSEngine(_win.webGpuImageEngine!);
      final result = engine.isReady.callAsFunction(engine);
      if (result.dartify() == true) {
        isModelLoaded.value = true;
        isLoadingModel.value = false;
        loadedModelName.value = 'dreamshaper-8-lcm (WebGPU)';
        gpuVendor.value = 'webgpu';
        isUsingGpu.value = true;
      }
    } catch (_) {
      // Engine not initialized yet
    }
  }

  void _setupJsCallbacks() {
    _win.onWebGpuImageLog = ((JSAny msg) {
      final s = msg.dartify()?.toString() ?? '';
      latestLog.value = s;
      print('[WebGPU Image] $s');
    }).toJS;

    _win.onWebGpuImageReady = ((JSAny ready) {
      final r = ready.dartify() == true;
      isModelLoaded.value = r;
      isLoadingModel.value = false;
      if (r) {
        loadedModelName.value = 'dreamshaper-8-lcm (WebGPU)';
        gpuVendor.value = 'webgpu';
        isUsingGpu.value = true;
      }
      _loadCompleter?.complete(
          'WebGPU engine ${r ? 'ready' : 'not ready'}');
      _loadCompleter = null;
      _initTimeout?.cancel();
    }).toJS;

    _win.onWebGpuImageResult = ((JSAny base64) {
      final s = base64.dartify()?.toString() ?? '';
      print('[WebGPU Image] Result received, length=${s.length}');
      Uint8List? bytes;
      if (s.startsWith('data:image/png;base64,')) {
        bytes = base64Decode(s.substring('data:image/png;base64,'.length));
      } else if (s.startsWith('data:image/')) {
        final commaIdx = s.indexOf(',');
        if (commaIdx > 0) {
          bytes = base64Decode(s.substring(commaIdx + 1));
        }
      }
      _generateCompleter?.complete(bytes);
      _generateCompleter = null;
      isGenerating.value = false;
      progress.value = 1.0;
    }).toJS;

    _win.onWebGpuImageProgress = ((JSAny step, JSAny total) {
      final s = step.dartify() as num? ?? 0;
      final t = total.dartify() as num? ?? 1;
      if (t > 0) {
        progress.value = s.toDouble() / t.toDouble();
      }
    }).toJS;

    _win.onWebGpuImageError = ((JSAny error) {
      final msg = error.dartify()?.toString() ?? '';
      print('[WebGPU Image] Error: $msg');
      latestLog.value = msg;
      _loadCompleter?.complete('ERROR: $msg');
      _loadCompleter = null;
      _generateCompleter?.complete(null);
      _generateCompleter = null;
      isLoadingModel.value = false;
      isGenerating.value = false;
      _initTimeout?.cancel();
    }).toJS;
  }

  Future<String> loadModel(String modelPath,
      {String? modelName, String? taesdPath}) async {
    if (isLoadingModel.value) return 'ERROR: Model is already loading.';
    if (isModelLoaded.value) return 'WebGPU engine already ready.';

    _syncReadyState();
    if (isModelLoaded.value) return 'WebGPU engine already ready.';

    isLoadingModel.value = true;
    progress.value = 0.0;
    _loadCompleter = Completer<String>();

    try {
      _win.initWebGpuImageEngine?.callAsFunction(null);
    } catch (e) {
      print('[WebGPU Image] Init call failed: $e');
    }

    _initTimeout = Timer(const Duration(seconds: 120), () {
      if (!isModelLoaded.value && isLoadingModel.value) {
        isLoadingModel.value = false;
        _loadCompleter?.complete('ERROR: WebGPU engine init timed out.');
        _loadCompleter = null;
      }
    });

    return await _loadCompleter!.future;
  }

  Future<void> unloadModel() async {
    isModelLoaded.value = false;
    loadedModelName.value = '';
    gpuVendor.value = 'unknown';
    isUsingGpu.value = false;
  }

  void setBackend(Backend backend) {
    currentBackend.value = backend;
  }

  void setQuantization(QuantizationType type) {
    currentQuantization.value = type;
  }

  void cancelGeneration() {
    if (isGenerating.value) {
      print('[WebGPU Image] Generation cancelled by user');
      isGenerating.value = false;
      _generateCompleter?.complete(null);
      _generateCompleter = null;
    }
  }

  Future<Uint8List?> generateImage({
    required String prompt,
    void Function(int step, int totalSteps)? onProgress,
  }) async {
    if (!isModelLoaded.value) return null;
    if (isGenerating.value) return null;

    isGenerating.value = true;
    progress.value = 0.0;
    _generateCompleter = Completer<Uint8List?>();

    try {
      final steps = _hive.getSetting<int>(AppConstants.keyImageSteps,
              defaultValue: AppConstants.defaultImageSteps) ??
          AppConstants.defaultImageSteps;

      _win.onWebGpuImageProgressDart =
          ((JSAny step, JSAny total) {
        final s = step.dartify() as num? ?? 0;
        final t = total.dartify() as num? ?? 1;
        onProgress?.call(s.toInt(), t.toInt());
      }).toJS;

      _win.generateWebGpuImage?.callAsFunction(
          null, prompt.toJS, ''.toJS, steps.toJS);

      Timer(const Duration(minutes: 5), () {
        if (isGenerating.value) {
          isGenerating.value = false;
          _generateCompleter?.complete(null);
          _generateCompleter = null;
        }
      });

      return await _generateCompleter!.future;
    } catch (e) {
      isGenerating.value = false;
      _generateCompleter = null;
      print('[WebGPU Image] Generate error: $e');
      return null;
    }
  }
}
