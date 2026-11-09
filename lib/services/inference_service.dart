import 'dart:async';
import 'package:get/get.dart';
import 'hive_service.dart';
import '../core/constants.dart';
import 'device_info_service.dart';
import 'app_log_service.dart';
import 'cluster_service.dart';
import 'stop_sequence_filter.dart';
import 'companion_files.dart';
import 'generation_options.dart';
export 'generation_options.dart';

// Conditionally import llama_flutter_android — only on Android
import 'inference_android.dart' if (dart.library.html) 'inference_stub.dart'
    as platform;

/// Cross-platform inference service.
/// - Android / iOS: uses llama_flutter_android for local GGUF models
/// - Android: uses flutter_litert_lm for LiteRT-LM models
/// - Web: cloud-only mode (local inference coming soon)
class InferenceService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  // ── Observable State ──
  final isModelLoaded = false.obs;
  final isGenerating = false.obs;
  final isLoadingModel = false.obs;
  final isVisionLoaded = false.obs;
  final loadingModelName = ''.obs;
  final loadedModelName = ''.obs;
  final tokenCount = 0.obs;
  final tokensPerSecond = 0.0.obs;
  final contextTokensUsed = 0.obs;
  final contextTokensTotal = 0.obs;
  final modelLoadProgress = 0.0.obs;
  final generationSource = ''.obs;
  final streamingText = ''.obs;
  final gpuName = ''.obs;
  final gpuLayersUsed = 0.obs;
  int _generationId = 0;

  /// Incremented whenever a generation is stopped early (by the user, a
  /// newer generation, or a disconnecting server client). Callers compare it
  /// before/after generate() to detect that their result was cut short.
  int get stopCount => _stopCount;
  int _stopCount = 0;
  final isGpuAccelerated = false.obs;
  final loadedModelRuntime = ''.obs;
  final loadedBackend = ''.obs;

  /// Whether the current platform supports local inference.
  bool get supportsLocalInference => platform.supportsLocalInference;

  // Platform-specific engine
  platform.InferenceEngine? _engine;
  String _sessionNativeRuntime = '';

  String get sessionNativeRuntime => _sessionNativeRuntime;

  /// The loaded GGUF model has a working vision projector (images allowed).
  /// With lazy vision on, also true while the projector waits for an image.
  bool get ggufVisionLoaded => _engine?.ggufVisionLoaded ?? false;

  /// Stats of the last generate() call (null before the first one).
  GenerationStats? get lastStats => _lastStats;
  GenerationStats? _lastStats;

  /// MTP status of the loaded GGUF model ('' when MTP is off).
  String get mtpStatus => _engine?.mtpStatus ?? '';

  /// Path of the loaded model ('' when none).
  final loadedModelPath = ''.obs;

  /// Vision projector chosen for the loaded GGUF model (null: none).
  String? get loadedMmprojPath => _loadedMmprojPath;
  String? _loadedMmprojPath;

  // Keep-alive: the model is unloaded after this long without a request and
  // reloaded by the next generate().
  Timer? _keepAliveTimer;
  _LoadArgs? _lastLoadArgs;
  _LoadArgs? _idleUnloadedArgs;

  /// The model was unloaded for being idle and reloads on the next request.
  bool get isIdleUnloaded => _idleUnloadedArgs != null;
  Future<String>? _reloading;

  /// Set by the bench admin API after it pushed engine options for the next
  /// load; that load then skips the global engine settings.
  static bool externalEngineOptions = false;

  /// Global CPU engine settings (Settings > Advanced), sent before every GGUF load.
  Map<String, dynamic> _engineSettings() {
    final threads = _hive.getSetting<int>(AppConstants.keyCpuThreads) ?? 0;
    final kv = _hive.getSetting<String>(AppConstants.keyKvCacheType) ?? 'f16';
    final repack = _hive.getSetting<bool>(AppConstants.keyCpuRepack) ?? true;
    final mask =
        (_hive.getSetting<String>(AppConstants.keyCpuAffinityMask) ?? '').trim();
    return {
      'threads': threads > 0 ? threads : -1,
      'typeK': kv,
      'typeV': kv,
      'repack': repack ? -1 : 0,
      'cpuMask': mask,
    };
  }

  Future<String> loadModel(
    String modelPath, {
    String? modelName,
    String? modelRuntime,
    bool enableLiteRtVision = false,
    String? mmprojPath,
  }) async {
    _idleUnloadedArgs = null;
    _keepAliveTimer?.cancel();
    if (!supportsLocalInference) {
      return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
    }
    if (isLoadingModel.value) return 'ERROR: Model is already loading.';

    if (platform.isRunning32Bit) {
      final lower = modelPath.toLowerCase();
      if (_runtimeFor(modelPath, modelRuntime) == 'litert') {
        return 'ERROR: LiteRT models need 64-bit Android. This phone runs '
            '32-bit Android; use a small GGUF model (under 1.5 GB) instead.';
      }
      // A 32-bit process can't map a model this large next to everything else.
      if (lower.endsWith('.gguf') &&
          await _fileBytes(modelPath) > 1536 * 1024 * 1024) {
        return 'ERROR: This model is too large for 32-bit Android. Choose a '
            'GGUF model under 1.5 GB (for example a 1B Q4 model).';
      }
    }

    if (modelPath.toLowerCase().endsWith('.safetensors')) {
      return 'ERROR: Cannot load image generation models (.safetensors) into the local text engine. Native local image generation requires the upcoming stable-diffusion engine update. Use Cloud Stability AI for now.';
    }

    try {
      final runtime = _runtimeFor(modelPath, modelRuntime);
      final isLiteRt = runtime == 'litert';
      final liteRtMode = _hive.getSetting<String>(
            AppConstants.keyLiteRtPerformanceMode,
            defaultValue: AppConstants.defaultLiteRtPerformanceMode,
          ) ??
          AppConstants.defaultLiteRtPerformanceMode;
      // The Performance setting alone decides: CPU safe never uses the GPU;
      // Auto fast and GPU fast always try it. A crash doesn't pause the GPU
      // for later loads (Auto fast still falls back to CPU if a GPU load
      // itself fails).
      final cpuOnly = liteRtMode == 'cpu_safe';
      final forceLiteRtCpu = isLiteRt && cpuOnly;
      final shouldTryLiteRtGpu = isLiteRt && !cpuOnly;
      final allowGgufGpu = !isLiteRt && !cpuOnly;
      // Clear crash state left by older versions of the app.
      await _hive.setSetting(AppConstants.keyLiteRtGpuCrashDetected, false);
      await _hive.setSetting(AppConstants.keyLiteRtGpuLoadPending, false);
      await _hive.setSetting(AppConstants.keyGgufGpuPending, false);

      await unloadModel();
      isLoadingModel.value = true;
      loadingModelName.value = modelName ?? modelPath.split('/').last;
      modelLoadProgress.value = 0.0;

      _engine = platform.InferenceEngine();

      final contextSize = _hive.getSetting<int>(
            AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize,
          ) ??
          AppConstants.defaultContextSize;

      final finalContextSize =
          isLiteRt ? contextSize.clamp(512, 4096) : contextSize;

      final lastLoadedContext =
          _hive.getSetting<int>('last_loaded_context_size') ?? 0;
      final contextChanged = isLiteRt && lastLoadedContext != finalContextSize;

      final deviceTier = _getDeviceTier();
      final isTensorSoC = _getIsTensorSoC();

      // Phone cluster: GGUF layers spread across worker phones. This phone
      // then runs its share on the CPU.
      var clusterWorkers = 0;
      if (!isLiteRt && Get.isRegistered<ClusterService>()) {
        clusterWorkers = await Get.find<ClusterService>()
            .applyForNextLoad(modelPath, modelName: modelName);
      }

      final requestedModelName = modelName ?? modelPath.split('/').last;
      var activeModelName = requestedModelName;

      // GGUF helper files next to the model: vision projector (catalogue,
      // per-model override, or found by name) and MTP draft head.
      final modelFile = modelPath.split('/').last;
      String? resolvedMmproj = mmprojPath;
      bool mtpEnabled = false;
      String? mtpDraftPath;
      final mtpTokens = (_hive.getSetting<int>(AppConstants.keyMtpDraftTokens) ??
              AppConstants.defaultMtpDraftTokens)
          .clamp(1, 16);
      if (!isLiteRt) {
        resolvedMmproj = await CompanionFiles.applyOverride(
          _overrideFor(AppConstants.keyMmprojOverrides, modelFile),
          () async => mmprojPath ?? await CompanionFiles.findMmproj(modelPath),
        );
        if (resolvedMmproj != null) {
          print('[InferenceService] Vision projector: $resolvedMmproj');
        }
        mtpEnabled = (_hive.getSetting<bool>(AppConstants.keyMtpEnabled) ??
                false) &&
            clusterWorkers == 0;
        if (mtpEnabled) {
          mtpDraftPath = await CompanionFiles.applyOverride(
            _overrideFor(AppConstants.keyMtpOverrides, modelFile),
            () => CompanionFiles.findMtp(modelPath),
          );
        }
      }
      final lazyVision =
          _hive.getSetting<bool>(AppConstants.keyVisionLazyLoad) ?? false;
      // Global GGUF engine settings, unless the bench admin API just pushed
      // its own options for this one load.
      Map<String, dynamic>? engineOptions;
      if (externalEngineOptions) {
        externalEngineOptions = false;
      } else if (!isLiteRt) {
        engineOptions = _engineSettings();
      }
      var result = await _loadModelOnEngine(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: finalContextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtMode,
        forceLiteRtCpu: forceLiteRtCpu,
        clearLiteRtCache: contextChanged,
        tryLiteRtGpu: shouldTryLiteRtGpu,
        enableLiteRtVision: enableLiteRtVision,
        allowGgufGpu: allowGgufGpu && clusterWorkers == 0,
        mmprojPath: resolvedMmproj,
        lazyVision: lazyVision,
        mtpEnabled: mtpEnabled,
        mtpDraftPath: mtpDraftPath,
        mtpDraftTokens: mtpTokens,
        engineOptions: engineOptions,
      );

      if (!result.success) {
        isModelLoaded.value = false;
        isLoadingModel.value = false;
        loadingModelName.value = '';
        modelLoadProgress.value = 0.0;
        loadedModelName.value = '';
        loadedModelRuntime.value = '';
        loadedBackend.value = '';
        gpuName.value = '';
        gpuLayersUsed.value = 0;
        isGpuAccelerated.value = false;
        Get.find<AppLogService>().error(
          'Local model load failed',
          details:
              'model=$requestedModelName, runtime=$runtime, backend=${result.backend}, message=${result.message}',
        );
        return result.message;
      }

      isModelLoaded.value = result.success;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 1.0;
      loadedModelName.value = activeModelName;
      loadedModelRuntime.value = result.runtime;
      if (result.runtime == 'llama' || result.runtime == 'litert') {
        _sessionNativeRuntime = result.runtime;
      }
      loadedBackend.value = result.backend;
      gpuName.value = result.gpuName;
      gpuLayersUsed.value = result.gpuLayers;
      isGpuAccelerated.value = result.backend == 'gpu' || result.gpuLayers > 0;
      contextTokensUsed.value = 0;
      contextTokensTotal.value = finalContextSize;
      loadedModelPath.value = modelPath;
      _loadedMmprojPath = isLiteRt ? null : resolvedMmproj;
      if (!isLiteRt) isVisionLoaded.value = ggufVisionLoaded;
      _lastLoadArgs = _LoadArgs(modelPath, modelName, modelRuntime,
          enableLiteRtVision, mmprojPath);
      _armKeepAlive();

      await _hive.setSetting(AppConstants.keyLocalModelPath, modelPath);
      await _hive.setSetting(
          AppConstants.keyLocalModelName, loadedModelName.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelRuntime, loadedModelRuntime.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelBackend, loadedBackend.value);

      if (isLiteRt) {
        await _hive.setSetting('last_loaded_context_size', finalContextSize);
      }

      if (clusterWorkers > 0) {
        final cluster = Get.find<ClusterService>();
        await cluster.refreshSplit(modelPath);
        return 'Model loaded across ${cluster.splitSummary ?? '${clusterWorkers + 1} phones'}.';
      }
      return result.message;
    } catch (e) {
      isModelLoaded.value = false;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 0.0;
      loadedBackend.value = '';
      Get.find<AppLogService>().error('Failed to load local model', details: e);
      return 'ERROR: Failed to load model — $e';
    }
  }

  Future<void> unloadModel() async {
    _keepAliveTimer?.cancel();
    _idleUnloadedArgs = null;
    await _unloadEngine();
  }

  Future<void> _unloadEngine() async {
    final engine = _engine;
    _engine = null;
    loadedModelPath.value = '';
    _loadedMmprojPath = null;
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().clearSplit();
    }
    if (engine != null) {
      await stopGeneration();
      await engine.dispose();
    }
    isModelLoaded.value = false;
    isVisionLoaded.value = false;
    loadedModelName.value = '';
    loadingModelName.value = '';
    loadedModelRuntime.value = '';
    loadedBackend.value = '';
    gpuLayersUsed.value = 0;
    isGpuAccelerated.value = false;
    gpuName.value = '';
    contextTokensUsed.value = 0;
    contextTokensTotal.value = 0;
    _sessionNativeRuntime = '';
  }

  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    GenerationOptions options = GenerationOptions.none,
    void Function(String token)? onToken,
  }) async {
    _lastStats = null;
    if (_idleUnloadedArgs != null && !isModelLoaded.value) {
      final reload = await reloadIfIdle();
      if (reload != null && reload.startsWith('ERROR')) return reload;
    }
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return 'ERROR: No model loaded. Go to Models tab to download and load one.';
    }
    _keepAliveTimer?.cancel();

    if (isGenerating.value) {
      // Wait for previous generation
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!isGenerating.value) break;
      }
      if (isGenerating.value) {
        await stopGeneration();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    // Identifies this generation so a stopped one that finishes late can't
    // reset the state of the generation that replaced it.
    final generationId = ++_generationId;
    bool isCurrent() => generationId == _generationId;

    isGenerating.value = true;
    tokenCount.value = 0;
    tokensPerSecond.value = 0.0;
    generationSource.value = source;
    streamingText.value = '';

    final startTime = DateTime.now();
    DateTime? firstVisibleTokenAt;
    Timer? tokenFlushTimer;
    final tokenFlushBuffer = StringBuffer();

    void flushTokenBuffer() {
      if (tokenFlushBuffer.isEmpty) return;
      final text = tokenFlushBuffer.toString();
      tokenFlushBuffer.clear();
      onToken?.call(text);
    }

    final stopFilter = StopSequenceFilter(stopSequences);
    var stopSequenceHit = false;

    try {
      final temperature = options.temperature ??
          _hive.getSetting<double>(
            AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature,
          ) ??
          AppConstants.defaultTemperature;

      final settingMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      // The setting is only the default: a caller's max_tokens wins, capped
      // by the context size (the native side also stops at a full context).
      var effectiveMaxTokens =
          (maxTokens != null && maxTokens > 0) ? maxTokens : settingMaxTokens;
      final ctxTotal = contextTokensTotal.value;
      if (ctxTotal > 0 && effectiveMaxTokens > ctxTotal) {
        effectiveMaxTokens = ctxTotal;
      }

      final result = await _engine!.generate(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        modelName: loadedModelName.value,
        maxTokens: effectiveMaxTokens,
        temperature: temperature,
        imagePath: imagePath,
        audioPath: audioPath,
        source: source,
        options: options,
        onToken: (rawToken) {
          if (!isCurrent()) return;
          var token = rawToken;
          if (stopFilter.isActive) {
            token = stopFilter.add(rawToken);
            if (stopFilter.stopped && !stopSequenceHit) {
              stopSequenceHit = true;
              // Halt the engine directly: this is a normal finish, not a
              // user/server interruption, so stopCount must not change.
              unawaited(
                  _engine?.stop().catchError((_) {}) ?? Future<void>.value());
            }
            if (token.isEmpty) return;
          }
          firstVisibleTokenAt ??= DateTime.now();
          tokenCount.value++;
          streamingText.value += token;
          final speedStart = firstVisibleTokenAt ?? startTime;
          final elapsedSeconds =
              DateTime.now().difference(speedStart).inMilliseconds / 1000.0;
          if (elapsedSeconds > 0) {
            tokensPerSecond.value = tokenCount.value / elapsedSeconds;
          }
          if (loadedModelRuntime.value == 'litert') {
            tokenFlushBuffer.write(token);
            tokenFlushTimer ??= Timer(const Duration(milliseconds: 60), () {
              tokenFlushTimer = null;
              flushTokenBuffer();
            });
          } else {
            onToken?.call(token);
          }
        },
      );
      tokenFlushTimer?.cancel();
      if (!isCurrent()) return result;
      if (stopFilter.isActive) {
        final tail = stopFilter.flush();
        if (tail.isNotEmpty) {
          streamingText.value += tail;
          tokenFlushBuffer.write(tail);
        }
      }
      flushTokenBuffer();
      final finalText = stopSequenceHit ? stopFilter.text : result;
      _lastStats = _statsFor(_engine?.lastStats, prompt, finalText,
          stopSequenceHit: stopSequenceHit,
          maxTokens: effectiveMaxTokens,
          emittedTokens: tokenCount.value);
      _armKeepAlive();

      await refreshContextInfo();
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
      }

      // Detect Tensor SoC + Gemma Q4_K_M corruption: model outputs only
      // special tokens and terminates immediately with empty result.
      if (result.trim().isEmpty &&
          tokenCount.value < 5 &&
          loadedModelName.value.toLowerCase().contains('gemma')) {
        final isTensor = _getIsTensorSoC();
        if (isTensor) {
          return '⚠️ This Gemma model is incompatible with your Pixel\'s Google Tensor chip. '
              'The Q4_K_M quantization format has a known bug on Tensor SoC that produces empty responses.\n\n'
              'Try one of these fixes:\n'
              '1. Download a Q4_0 or Q5_K_M version of the same model\n'
              '2. Use a different model (Qwen, Phi, or Llama-3)\n'
              '3. Switch to Cloud mode in Settings';
        }
      }

      return finalText;
    } catch (e) {
      tokenFlushTimer?.cancel();
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
        streamingText.value = '';
        flushTokenBuffer();
      }
      Get.find<AppLogService>().error('Local generation failed', details: e);
      return 'ERROR: $e';
    }
  }

  Future<void> stopGeneration() async {
    _generationId++;
    _stopCount++;
    isGenerating.value = false;
    tokenCount.value = 0;
    generationSource.value = '';
    streamingText.value = '';
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.stop().timeout(const Duration(seconds: 1)).catchError(
            (_) {},
          ));
    }
  }

  /// Reset the native conversation context. Call this whenever the user
  /// switches to a different chat session so old context doesn't leak.
  Future<void> resetConversation() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resetConversation();
    }
  }

  Future<void> refreshContextInfo() async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return;
    }

    final info = await _engine!.getContextInfo();
    if (info == null) return;

    contextTokensUsed.value = info.tokensUsed;
    contextTokensTotal.value = info.contextSize;
  }

  String _getDeviceTier() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.deviceTier.value;
    } catch (_) {
      return 'mid';
    }
  }

  bool _getIsTensorSoC() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.isTensorSoC.value;
    } catch (_) {
      return false;
    }
  }

  Future<platform.LoadResult> _loadModelOnEngine({
    required String modelPath,
    required String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    required String liteRtPerformanceMode,
    required bool forceLiteRtCpu,
    required bool clearLiteRtCache,
    required bool tryLiteRtGpu,
    required bool enableLiteRtVision,
    bool allowGgufGpu = false,
    String? mmprojPath,
    bool lazyVision = false,
    bool mtpEnabled = false,
    String? mtpDraftPath,
    int mtpDraftTokens = 3,
    Map<String, dynamic>? engineOptions,
  }) async {
    // Auto fast: if a LiteRT GPU load fails, retry this load on the CPU.
    // Nothing is remembered — the next load tries the GPU again.
    final fallbackToCpu = tryLiteRtGpu && liteRtPerformanceMode == 'auto_fast';
    Future<platform.LoadResult> loadOnCpu() {
      modelLoadProgress.value = 0.0;
      return _engine!.loadModel(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: contextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtPerformanceMode,
        forceLiteRtCpu: true,
        clearLiteRtCache: true,
        enableLiteRtVision: enableLiteRtVision,
        onProgress: (p) => modelLoadProgress.value = _normalizeProgress(p),
      );
    }

    try {
      final result = await _engine!.loadModel(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: contextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtPerformanceMode,
        forceLiteRtCpu: forceLiteRtCpu,
        clearLiteRtCache: clearLiteRtCache,
        enableLiteRtVision: enableLiteRtVision,
        allowGgufGpu: allowGgufGpu,
        mmprojPath: mmprojPath,
        lazyVision: lazyVision,
        mtpEnabled: mtpEnabled,
        mtpDraftPath: mtpDraftPath,
        mtpDraftTokens: mtpDraftTokens,
        engineOptions: engineOptions,
        onProgress: (p) => modelLoadProgress.value = _normalizeProgress(p),
      );
      if (result.success || !fallbackToCpu) return result;
      return await loadOnCpu();
    } catch (e) {
      if (fallbackToCpu) {
        try {
          return await loadOnCpu();
        } catch (cpuError) {
          return platform.LoadResult(
            success: false,
            message: 'ERROR: Failed to load model - $cpuError',
          );
        }
      }
      return platform.LoadResult(
        success: false,
        message: 'ERROR: Failed to load model - $e',
      );
    }
  }

  Future<int> _fileBytes(String path) async {
    try {
      return await platform.fileLength(path);
    } catch (_) {
      return 0;
    }
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  String _runtimeFor(String modelPath, String? modelRuntime) {
    final runtime = modelRuntime?.toLowerCase();
    if (runtime == 'litert' || runtime == 'llama') return runtime!;
    return modelPath.toLowerCase().endsWith('.litertlm') ? 'litert' : 'llama';
  }

  // ── Helper files, keep-alive, stats, embeddings ──

  String? _overrideFor(String key, String modelFile) {
    final raw = _hive.getSetting<Map>(key);
    final value = raw?[modelFile];
    return value is String ? value : null;
  }

  /// Sets (or with null/'' clears) a per-model helper-file override:
  /// a path, or [CompanionFiles.none] to turn the helper off.
  Future<void> setHelperOverride(
      String key, String modelFile, String? value) async {
    final map = Map<String, dynamic>.from(_hive.getSetting<Map>(key) ?? {});
    if (value == null || value.isEmpty) {
      map.remove(modelFile);
    } else {
      map[modelFile] = value;
    }
    await _hive.setSetting(key, map);
  }

  String? helperOverride(String key, String modelFile) =>
      _overrideFor(key, modelFile);

  /// (Re)starts the keep-alive countdown after a load or a reply.
  void _armKeepAlive() {
    _keepAliveTimer?.cancel();
    final minutes = _hive.getSetting<int>(AppConstants.keyKeepAliveMinutes) ?? 0;
    if (minutes <= 0 || !isModelLoaded.value) return;
    _keepAliveTimer = Timer(Duration(minutes: minutes), () async {
      if (isGenerating.value || isLoadingModel.value || !isModelLoaded.value) {
        _armKeepAlive();
        return;
      }
      final args = _lastLoadArgs;
      if (args == null) return;
      Get.find<AppLogService>().info('Keep-alive: unloading idle model',
          details: '${loadedModelName.value} after $minutes min');
      await _unloadEngine();
      _idleUnloadedArgs = args;
    });
  }

  /// Settings changed: restart the countdown with the new value.
  void refreshKeepAlive() => _armKeepAlive();

  /// Reloads a model the keep-alive unloaded. Returns the load message, or
  /// null when nothing had to be reloaded. Concurrent callers share one load.
  Future<String?> reloadIfIdle() async {
    final args = _idleUnloadedArgs;
    if (args == null || isModelLoaded.value) return null;
    final pending = _reloading;
    if (pending != null) return pending;
    final future = loadModel(args.path,
        modelName: args.name,
        modelRuntime: args.runtime,
        enableLiteRtVision: args.liteRtVision,
        mmprojPath: args.mmproj);
    _reloading = future;
    try {
      final result = await future;
      if (!isModelLoaded.value) _idleUnloadedArgs = args;
      return result;
    } finally {
      _reloading = null;
    }
  }

  GenerationStats _statsFor(
    GenerationStats? native,
    String prompt,
    String text, {
    required bool stopSequenceHit,
    required int maxTokens,
    required int emittedTokens,
  }) {
    if (native != null) {
      var finish = native.finish;
      if (stopSequenceHit || finish == 'abort' || finish == 'error') {
        finish = 'stop';
      }
      return GenerationStats(
        promptTokens: native.promptTokens,
        completionTokens: native.completionTokens,
        cachedTokens: native.cachedTokens,
        finish: finish,
        mtpDrafted: native.mtpDrafted,
        mtpAccepted: native.mtpAccepted,
        promptMs: native.promptMs,
        genMs: native.genMs,
      );
    }
    final completion = emittedTokens > 0 ? emittedTokens : (text.length / 4).ceil();
    return GenerationStats(
      promptTokens: (prompt.length / 4).ceil(),
      completionTokens: completion,
      finish: !stopSequenceHit && completion >= maxTokens ? 'length' : 'stop',
      estimated: true,
    );
  }

  /// Exact prompt-token count of the generation running/just stopped (GGUF).
  Future<int?> nativePromptTokens() async =>
      (await _engine?.nativeStats())?.promptTokens;

  bool get _isGguf =>
      _engine != null && isModelLoaded.value && loadedModelRuntime.value != 'litert';

  /// GGUF tokenizer. Null when no GGUF model is loaded.
  Future<List<int>?> tokenize(String text,
      {bool addSpecial = true, bool parseSpecial = true}) async {
    if (!_isGguf) return null;
    return _engine!.tokenize(text, addSpecial: addSpecial, parseSpecial: parseSpecial);
  }

  Future<String?> detokenize(List<int> tokens) async {
    if (!_isGguf) return null;
    return _engine!.detokenize(tokens);
  }

  /// Pooled embedding from the loaded GGUF model (clears its chat cache).
  /// Null when no GGUF model is loaded.
  Future<List<double>?> embed(String text) async {
    if (!_isGguf) return null;
    if (isGenerating.value) throw StateError('Model is busy');
    isGenerating.value = true;
    generationSource.value = 'embeddings';
    try {
      return await _engine!.embed(text);
    } finally {
      isGenerating.value = false;
      generationSource.value = '';
      _armKeepAlive();
    }
  }

  /// GGUF chat template render with tools (see LlamaExt.chatPrepare).
  Future<Map<String, dynamic>?> chatPrepare(Map<String, dynamic> request) async {
    if (!_isGguf) return null;
    return _engine!.chatPrepare(request);
  }

  Future<Map<String, dynamic>?> chatParse(String text) async {
    if (!_isGguf) return null;
    return _engine!.chatParse(text);
  }

  Future<String?> jsonSchemaToGrammar(Object schema) async {
    if (!_isGguf) return null;
    return _engine!.jsonSchemaToGrammar(schema);
  }

  Future<Map<String, dynamic>> mtpInfo() async =>
      await _engine?.mtpInfo() ?? const {};
}

class _LoadArgs {
  final String path;
  final String? name;
  final String? runtime;
  final bool liteRtVision;
  final String? mmproj;
  _LoadArgs(this.path, this.name, this.runtime, this.liteRtVision, this.mmproj);
}
