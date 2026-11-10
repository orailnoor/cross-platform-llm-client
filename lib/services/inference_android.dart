import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform, Directory, File;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Whether the current platform supports local inference.
bool get supportsLocalInference =>
    Platform.isAndroid || Platform.isIOS || Platform.isWindows;

/// True when the app runs as a 32-bit process (32-bit Android, e.g. Android
/// Go phones). LiteRT ships 64-bit only, and the address space limits model
/// size.
bool get isRunning32Bit =>
    Abi.current() == Abi.androidArm || Abi.current() == Abi.androidIA32;

Future<int> fileLength(String path) => File(path).length();

/// Result from model loading.
class LoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  final String runtime;
  final String backend;
  LoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
    this.runtime = '',
    this.backend = '',
  });
}

/// Android & iOS inference engine — wraps llama_flutter_android.
class InferenceEngine {
  LlamaController? _controller;
  LiteLmEngine? _liteEngine;
  LiteLmConversation? _liteConversation;
  StreamSubscription? _subscription;
  StreamSubscription? _loadProgressSub;
  Timer? _idleTimer;
  void Function()? _onStop;
  bool _isLiteRt = false;
  // GGUF model loaded together with a working vision projector.
  bool _ggufVisionLoaded = false;
  bool get ggufVisionLoaded => _ggufVisionLoaded;
  bool _disposed = false;
  bool _hasLoadedModel = false;
  String? _liteConversationSystemPrompt;
  double? _liteConversationTemperature;
  bool _liteConversationHasMessages = false;
  // Which caller (chat/server/task) the native LiteRT conversation belongs to.
  // A different caller must never continue another's conversation.
  String? _liteConversationOwner;

  Future<LoadResult> loadModel({
    required String modelPath,
    String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    String liteRtPerformanceMode = 'auto_fast',
    bool forceLiteRtCpu = false,
    bool clearLiteRtCache = false,
    bool enableLiteRtVision = false,
    bool allowGgufGpu = true,
    String? mmprojPath,
    void Function(double)? onProgress,
  }) async {
    _disposed = false;
    final runtime = _runtimeFor(modelPath, modelRuntime);
    if (runtime == 'litert') {
      return _loadLiteRtModel(
        modelPath,
        contextSize: contextSize,
        performanceMode: liteRtPerformanceMode,
        forceCpu: forceLiteRtCpu,
        clearCache: clearLiteRtCache,
        enableVision: enableLiteRtVision,
        onProgress: onProgress,
      );
    }

    _isLiteRt = false;
    _ggufVisionLoaded = false;
    _controller = LlamaController();

    // The native plugin can still hold a model this engine never loaded
    // (e.g. after a Dart hot restart, or if an earlier unload was skipped).
    // Free it first so the model the user picked actually loads.
    try {
      if (await _controller!.isModelLoaded()) {
        print('[Inference] Freeing a stale native model before loading');
        await _controller!.dispose();
        _controller = LlamaController();
      }
    } catch (_) {}

    // ── GPU Detection ──
    int gpuLayers = 0;
    String gpuNameStr = '';

    try {
      if (!allowGgufGpu) {
        throw StateError('GPU disabled by CPU Safe mode');
      }
      final gpu = await _controller!.detectGpu();
      gpuNameStr = gpu.gpuName;

      print('[Inference] GPU: ${gpu.gpuName}');
      print('[Inference]   Vulkan: ${gpu.vulkanSupported}');
      print('[Inference]   Free RAM: ${gpu.freeRamBytes ~/ 1024 ~/ 1024}MB');
      print('[Inference]   Recommended layers: ${gpu.recommendedGpuLayers}');

      // The plugin decides eligibility (SoC/driver blocklist, free RAM).
      if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
        // On phones the GPU shares system RAM, and offloading copies the
        // weights into GPU buffers (CPU mode maps the file instead). If the
        // model + vision file won't fit in free RAM with that copy, Android's
        // low-memory killer closes the app — so stay on the CPU.
        final modelBytes = await _fileLength(modelPath);
        final visionBytes =
            mmprojPath == null ? 0 : await _fileLength(mmprojPath);
        final needed = ((modelBytes + visionBytes) * 1.25).round();
        final free = gpu.freeRamBytes;
        if (!Platform.isWindows && free > 0 && needed > free) {
          print('[Inference] Model needs ~${needed ~/ (1024 * 1024)}MB for GPU '
              'offload but only ${free ~/ (1024 * 1024)}MB is free — using CPU');
        } else {
          gpuLayers = gpu.recommendedGpuLayers;
          print(
              '[Inference] ✓ GPU offload: $gpuLayers layers on ${gpu.gpuName}');
        }
      }
    } catch (e) {
      print('[Inference] GPU detection failed: $e — CPU fallback');
    }

    // ── Thread Tuning ──
    int threads;
    if (gpuLayers > 0) {
      threads = deviceTier == 'ultra'
          ? 4
          : deviceTier == 'high'
              ? 4
              : 4;
    } else {
      threads = deviceTier == 'ultra'
          ? 6
          : deviceTier == 'high'
              ? 5
              : deviceTier == 'mid'
                  ? 4
                  : 3;
    }

    // Google Tensor SoC (Pixel 6/7/8) has known Q4_K_M dequant bugs
    // that corrupt logits at >1 thread on Gemma models. Force single-threaded
    // to eliminate KV cache races in the quantization dot-product path.
    final modelName = modelPath.toLowerCase();
    if (isTensorSoC && modelName.contains('gemma')) {
      threads = 1;
      print(
          '[Inference] Tensor SoC + Gemma detected — forcing single-threaded inference');
    }

    // ── Load Progress ──
    await _loadProgressSub?.cancel();
    _loadProgressSub = null;
    try {
      _loadProgressSub = _controller!.loadProgress.listen((progress) {
        onProgress?.call(_normalizeProgress(progress));
      });
    } catch (_) {}

    // ── Load ──
    final visionError = await _controller!.loadModel(
      modelPath: modelPath,
      threads: threads,
      contextSize: contextSize,
      gpuLayers: gpuLayers,
      mmprojPath: mmprojPath,
    );
    _hasLoadedModel = true;
    gpuLayers = _controller!.loadedGpuLayers ?? gpuLayers;
    _ggufVisionLoaded = mmprojPath != null && visionError == null;
    if (visionError != null) {
      print('[Inference] Vision projector not loaded: $visionError');
    }

    final accel = gpuLayers > 0
        ? 'GPU ($gpuLayers layers, $gpuNameStr)'
        : 'CPU ($threads threads)';
    print('[Inference] ✓ Model loaded: $accel, ctx=$contextSize');

    return LoadResult(
      success: true,
      message: 'Model loaded ($accel).',
      gpuName: gpuNameStr,
      gpuLayers: gpuLayers,
      runtime: 'llama',
      backend: gpuLayers > 0 ? 'gpu' : 'cpu',
    );
  }

  Future<LoadResult> _loadLiteRtModel(
    String modelPath, {
    required int contextSize,
    required String performanceMode,
    required bool forceCpu,
    required bool clearCache,
    required bool enableVision,
    void Function(double)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'LiteRT-LM is enabled for Android only in this app.');
    }

    _isLiteRt = true;
    _controller = null;

    final tempDir = await getTemporaryDirectory();
    final cacheDir = Directory('${tempDir.path}/litert_cache');
    final backend = forceCpu || performanceMode == 'cpu_safe'
        ? LiteLmBackend.cpu
        : LiteLmBackend.gpu;
    final backendLabel = backend == LiteLmBackend.gpu ? 'GPU' : 'CPU';

    try {
      onProgress?.call(0.05);
      if (clearCache && await cacheDir.exists()) {
        try {
          await cacheDir.delete(recursive: true);
        } catch (_) {}
      }
      await cacheDir.create(recursive: true);
      onProgress?.call(0.18);

      _liteEngine = await _createLiteRtEngine(
        modelPath: modelPath,
        contextSize: contextSize,
        cacheDir: cacheDir.path,
        backend: backend,
        enableVision: enableVision,
      );
      _hasLoadedModel = true;
      onProgress?.call(0.92);
      print(
          '[Inference] LiteRT-LM loaded with $backendLabel backend, ctx=$contextSize');
      return LoadResult(
        success: true,
        message: 'LiteRT-LM model loaded ($backendLabel backend).',
        gpuName: backend == LiteLmBackend.gpu ? 'LiteRT GPU' : '',
        gpuLayers: backend == LiteLmBackend.gpu ? 1 : 0,
        runtime: 'litert',
        backend: backend.name,
      );
    } catch (error) {
      print('[Inference] LiteRT-LM load failed: $error');
      final errorStr = error.toString();
      if (errorStr.contains('TF_LITE_VISION_ENCODER')) {
        return LoadResult(
          success: false,
          message:
              'This LiteRT-LM file is text-only, but it was loaded as a vision model. Turn off Vision for this model or re-import it as a normal chat model.',
        );
      }
      if (enableVision && errorStr.contains('exactly one signature but got')) {
        print(
            '[Inference] Vision encoder signature mismatch. Falling back to text-only mode.');
        try {
          _liteEngine = await _createLiteRtEngine(
            modelPath: modelPath,
            contextSize: contextSize,
            cacheDir: cacheDir.path,
            backend: backend,
            enableVision: false,
          );
          _hasLoadedModel = true;
          onProgress?.call(0.92);
          return LoadResult(
            success: true,
            message:
                'Model loaded in text-only mode. Its vision features are incompatible with the LiteRT engine (expected 1 signature, found multiple).',
            gpuName: backend == LiteLmBackend.gpu ? 'LiteRT GPU' : '',
            gpuLayers: backend == LiteLmBackend.gpu ? 1 : 0,
            runtime: 'litert',
            backend: backend.name,
          );
        } catch (fallbackError) {
          print('[Inference] LiteRT-LM fallback load failed: $fallbackError');
          return LoadResult(
            success: false,
            message: 'LiteRT load failed: $fallbackError',
          );
        }
      }
      if (errorStr.contains('exactly one signature but got')) {
        return LoadResult(
          success: false,
          message:
              'This vision model is incompatible with the LiteRT engine (expected 1 signature, found multiple). Please try a standard GGUF model or a text-only LiteRT model instead.',
        );
      }
      rethrow;
    }
  }

  Future<LiteLmEngine> _createLiteRtEngine({
    required String modelPath,
    required int contextSize,
    required String cacheDir,
    required LiteLmBackend backend,
    required bool enableVision,
  }) {
    return LiteLmEngine.create(
      LiteLmEngineConfig(
        modelPath: modelPath,
        backend: backend,
        cacheDir: cacheDir,
        visionBackend: enableVision ? LiteLmBackend.cpu : null,
        audioBackend: null,
        maxNumTokens: contextSize,
      ),
    );
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required String modelName,
    required int maxTokens,
    required double temperature,
    String? imagePath,
    String? audioPath,
    String source = 'chat',
    void Function(String token)? onToken,
  }) async {
    if (_isLiteRt) {
      return _generateLiteRt(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        imagePath: imagePath,
        audioPath: audioPath,
        source: source,
        onToken: onToken,
      );
    }

    if (_controller == null) throw Exception('No model loaded');
    if (imagePath != null && imagePath.isNotEmpty && !_ggufVisionLoaded) {
      return 'This model can\'t read images. Load a vision model (one marked '
          'Vision in Models) to ask about photos.';
    }
    if (audioPath != null && audioPath.isNotEmpty) {
      return 'GGUF audio input is not available in this build yet. Text files can be read when their content is attached, but audio needs a model/runtime path that supports audio input.';
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;
    final controller = _controller;

    // Timeouts and stop must halt the native engine too; cancelling the Dart
    // subscription alone leaves llama.cpp generating in the background.
    void finish(String result, {bool stopNative = true}) {
      if (!completed && !_disposed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
        if (stopNative) {
          unawaited(controller
                  ?.stop()
                  .timeout(const Duration(seconds: 1))
                  .catchError((_) {}) ??
              Future<void>.value());
        }
        if (!completer.isCompleted) completer.complete(result);
      }
    }

    _onStop = () {
      finish(buffer.toString());
    };

    // ── Use generateChat() for native template handling ──
    Stream<String>? stream;
    try {
      final messages = _buildChatMessages(
          prompt, conversationHistory, systemPrompt,
          imagePath: imagePath);
      stream = _controller!.generateChat(
        messages: messages,
        template: null,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 64,
      );
      print('[Inference] generateChat() started (${messages.length} messages)');
    } catch (e) {
      print('[Inference] generateChat() failed: $e — fallback to generate()');
      try {
        await _controller!.stop();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
      final fullPrompt =
          _buildPrompt(prompt, conversationHistory, systemPrompt, modelName);
      stream = _controller!.generate(
        prompt: fullPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 64,
      );
    }

    int tokenCount = 0;
    _subscription = stream.listen(
      (token) {
        if (tokenCount == 0) {
          print('[Inference] ✓ FIRST TOKEN received! Prefill done.');
        }
        // Any token (even one that cleans to nothing) means the engine is
        // alive. The limit only catches a stuck engine: big models on CPU
        // can pause several seconds between tokens.
        _idleTimer?.cancel();
        _idleTimer = Timer(_tokenStallTimeout, () {
          print('[Inference] Idle timeout — $tokenCount tokens');
          finish(buffer.toString());
        });
        final clean = _sanitizeGemmaGarbage(token);
        if (clean.isEmpty) return;
        buffer.write(clean);
        tokenCount++;
        onToken?.call(clean);
      },
      onDone: () {
        print('[Inference] Stream onDone — $tokenCount tokens total');
        finish(buffer.toString(), stopNative: false);
      },
      onError: (error) {
        print('[Inference] Stream error: $error');
        finish('ERROR: Generation failed — $error');
      },
    );

    // Prefill timeout
    _idleTimer = Timer(const Duration(seconds: 60), () {
      if (tokenCount == 0) {
        finish(
            'ERROR: Model did not respond. Try a smaller model or shorter conversation.');
      }
    });

    // Hard timeout
    Future.delayed(_hardTimeout(maxTokens, minSeconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finish(partial.isEmpty
            ? 'ERROR: Generation timed out.'
            : '$partial$_timeLimitNote');
      }
    });

    return await completer.future;
  }

  Future<String> _generateLiteRt({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required int maxTokens,
    required double temperature,
    String? imagePath,
    String? audioPath,
    required String source,
    void Function(String token)? onToken,
  }) async {
    if (_liteEngine == null) throw Exception('No LiteRT-LM model loaded');

    await _subscription?.cancel();
    await _ensureLiteRtConversation(
      prompt: prompt,
      conversationHistory: conversationHistory,
      systemPrompt: systemPrompt,
      temperature: temperature,
      source: source,
    );

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;
    bool hasVisibleOutput = false;
    var tokenCount = 0;
    final conversation = _liteConversation;

    // Unless the stream ended on its own, the native engine is still
    // generating: cancel it, otherwise it keeps running and blocks the next
    // conversation reset.
    void finish(String result, {bool cancelNative = true}) {
      if (!completed && !_disposed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
        if (cancelNative) {
          unawaited(conversation?.cancel().catchError((_) {}) ??
              Future<void>.value());
        }
        if (!completer.isCompleted) completer.complete(result);
      }
    }

    _onStop = () => finish(buffer.toString());

    if ((imagePath != null && imagePath.isNotEmpty) ||
        (audioPath != null && audioPath.isNotEmpty)) {
      final contents = <LiteLmContent>[
        LiteLmContent.text(prompt),
        if (imagePath != null && imagePath.isNotEmpty)
          LiteLmContent.imageFile(imagePath),
        if (audioPath != null && audioPath.isNotEmpty)
          LiteLmContent.audioFile(audioPath),
      ];

      _subscription =
          _liteConversation!.sendMultimodalMessageStream(contents).listen(
        (delta) {
          var text = _cleanLiteRtChunk(delta.text);
          if (text.isEmpty) return;

          if (!hasVisibleOutput) {
            if (!_hasPrintableText(text)) return;
            text = text.trimLeft();
            hasVisibleOutput = true;
          }

          if (tokenCount == 0) {
            print('[Inference] LiteRT-LM multimodal FIRST TOKEN received');
          }
          _liteConversationHasMessages = true;
          tokenCount++;
          buffer.write(text);
          onToken?.call(text);
          // LiteRT has no native token limit; enforce it here.
          if (tokenCount >= maxTokens) {
            finish(buffer.toString());
            return;
          }
          _idleTimer?.cancel();
          _idleTimer = Timer(_tokenStallTimeout, () {
            print(
                '[Inference] LiteRT-LM multimodal idle timeout - $tokenCount chunks');
            finish(buffer.toString());
          });
        },
        onDone: () {
          _liteConversationHasMessages = true;
          print(
              '[Inference] LiteRT-LM multimodal stream done - $tokenCount chunks');
          finish(buffer.toString(), cancelNative: false);
        },
        onError: (error) {
          print('[Inference] LiteRT-LM multimodal stream error: $error');
          finish('ERROR: LiteRT-LM multimodal generation failed - $error');
        },
      );

      _idleTimer = Timer(const Duration(seconds: 90), () {
        if (tokenCount == 0) {
          finish('ERROR: LiteRT-LM multimodal model did not respond.');
        }
      });

      Future.delayed(_hardTimeout(maxTokens, minSeconds: 240), () {
        if (!completed) {
          final partial = buffer.toString();
          finish(partial.isEmpty
              ? 'ERROR: LiteRT-LM multimodal generation timed out.'
              : '$partial$_timeLimitNote');
        }
      });

      return completer.future;
    }

    _subscription = _liteConversation!.sendMessageStream(prompt).listen(
      (delta) {
        var text = _cleanLiteRtChunk(delta.text);
        if (text.isEmpty) return;

        if (!hasVisibleOutput) {
          if (!_hasPrintableText(text)) return;
          text = text.trimLeft();
          hasVisibleOutput = true;
        }

        if (tokenCount == 0) {
          print('[Inference] LiteRT-LM FIRST TOKEN received');
        }
        _liteConversationHasMessages = true;
        tokenCount++;
        buffer.write(text);
        onToken?.call(text);
        // LiteRT has no native token limit; enforce it here.
        if (tokenCount >= maxTokens) {
          finish(buffer.toString());
          return;
        }
        _idleTimer?.cancel();
        _idleTimer = Timer(_tokenStallTimeout, () {
          print('[Inference] LiteRT-LM idle timeout - $tokenCount chunks');
          finish(buffer.toString());
        });
      },
      onDone: () {
        _liteConversationHasMessages = true;
        print('[Inference] LiteRT-LM stream done - $tokenCount chunks');
        finish(buffer.toString(), cancelNative: false);
      },
      onError: (error) {
        print('[Inference] LiteRT-LM stream error: $error');
        finish('ERROR: LiteRT-LM generation failed - $error');
      },
    );

    _idleTimer = Timer(const Duration(seconds: 60), () {
      if (tokenCount == 0) {
        finish('ERROR: LiteRT-LM model did not respond. Try a smaller model.');
      }
    });

    Future.delayed(_hardTimeout(maxTokens, minSeconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finish(partial.isEmpty
            ? 'ERROR: LiteRT-LM generation timed out.'
            : '$partial$_timeLimitNote');
      }
    });

    return completer.future;
  }

  Future<void> _ensureLiteRtConversation({
    required String prompt,
    required List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required double temperature,
    required String source,
  }) async {
    final hasIncomingHistory = conversationHistory != null &&
        conversationHistory.any((msg) => (msg['content'] ?? '').isNotEmpty);
    // Server requests are stateless: each one carries its own history, so it
    // always gets a fresh conversation and never sees chat context.
    final shouldReset = _liteConversation == null ||
        source == 'server' ||
        _liteConversationOwner != source ||
        _liteConversationSystemPrompt != systemPrompt ||
        _liteConversationTemperature != temperature ||
        (_liteConversationHasMessages && !hasIncomingHistory);

    if (!shouldReset) return;

    try {
      await _liteConversation?.dispose();
    } catch (_) {}

    _liteConversation = await _liteEngine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemPrompt,
        initialMessages:
            _buildLiteRtInitialMessages(prompt, conversationHistory),
        samplerConfig: LiteLmSamplerConfig(
          temperature: temperature,
          topK: 64,
          topP: 0.95,
        ),
      ),
    );
    _liteConversationSystemPrompt = systemPrompt;
    _liteConversationTemperature = temperature;
    _liteConversationHasMessages = hasIncomingHistory;
    _liteConversationOwner = source;
  }

  Future<void> stop() async {
    if (_disposed) return;
    _idleTimer?.cancel();
    final stopCallback = _onStop;
    _onStop = null;
    stopCallback?.call();
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    if (_isLiteRt) {
      _liteConversationHasMessages = true;
      try {
        await _liteConversation?.cancel();
      } catch (_) {}
      return;
    }
    try {
      await _controller?.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {}
  }

  /// Reset any persistent conversation state so the next generation
  /// starts with a clean context. Essential when switching chat sessions.
  Future<void> resetConversation() async {
    if (_isLiteRt) {
      try {
        await _liteConversation?.dispose();
      } catch (_) {}
      _liteConversation = null;
      _liteConversationSystemPrompt = null;
      _liteConversationTemperature = null;
      _liteConversationHasMessages = false;
      _liteConversationOwner = null;
    }
    // llama.cpp (GGUF) is stateless per-generation — no native
    // conversation object to reset.
  }

  Future<ContextInfo?> getContextInfo() async {
    if (_isLiteRt) return null;
    try {
      return await _controller?.getContextInfo();
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (_hasLoadedModel) {
      try {
        await _controller?.dispose();
      } catch (_) {}
    }
    try {
      await _liteConversation?.dispose();
    } catch (_) {}
    try {
      await _liteEngine?.dispose();
    } catch (_) {}
    unawaited(_loadProgressSub?.cancel() ?? Future<void>.value());
    _loadProgressSub = null;
    _controller = null;
    _liteConversation = null;
    _liteEngine = null;
    _isLiteRt = false;
    _hasLoadedModel = false;
    _liteConversationSystemPrompt = null;
    _liteConversationTemperature = null;
    _liteConversationHasMessages = false;
  }

  // ── Helpers ──

  /// Safety cap on a single generation. It scales with the token budget
  /// (allowing ~1 token/s) so slow phones aren't cut off mid-answer; the idle
  /// timeouts already catch a model that has stopped producing tokens.
  static Duration _hardTimeout(int maxTokens, {int minSeconds = 180}) =>
      Duration(seconds: maxTokens > minSeconds ? maxTokens : minSeconds);

  static const _timeLimitNote =
      '\n\n⚠️ Stopped: this reply hit the time limit for one response.';

  String _runtimeFor(String modelPath, String? modelRuntime) {
    final runtime = modelRuntime?.toLowerCase();
    if (runtime == 'litert' || runtime == 'llama') return runtime!;
    final lower = modelPath.toLowerCase();
    if (lower.endsWith('.litertlm')) return 'litert';
    return 'llama';
  }

  List<LiteLmMessage> _buildLiteRtInitialMessages(
    String prompt,
    List<Map<String, String>>? history,
  ) {
    if (history == null || history.isEmpty) return const [];

    var recent = history.length > 16
        ? history.sublist(history.length - 16)
        : List<Map<String, String>>.from(history);
    if (recent.isNotEmpty &&
        recent.last['role'] == 'user' &&
        recent.last['content'] == prompt) {
      recent = recent.sublist(0, recent.length - 1);
    }

    return recent
        .where((msg) => (msg['content'] ?? '').trim().isNotEmpty)
        .map((msg) {
      final content = msg['content'] ?? '';
      return msg['role'] == 'assistant'
          ? LiteLmMessage.model(content)
          : LiteLmMessage.user(content);
    }).toList();
  }

  String _cleanLiteRtChunk(String text) {
    return _sanitizeGemmaGarbage(
      text
          .replaceAll(
              RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'),
              '')
          .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
          .replaceAll('\uFFFD', '')
          .replaceAll('<|endoftext|>', '')
          .replaceAll('<|im_end|>', '')
          .replaceAll('<|end|>', ''),
    );
  }

  /// Strip Gemma garbage tokens that leak when Q4_K_M dequant is corrupt
  /// on Google Tensor SoC. Harmless on devices that don't produce them.
  /// NOTE: Do NOT trim() — SentencePiece tokens rely on leading spaces.
  Future<int> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  /// How long generation may go without a new token before it's treated as
  /// stuck and ended.
  static const _tokenStallTimeout = Duration(seconds: 30);

  String _sanitizeGemmaGarbage(String text) {
    return text
        .replaceAll(RegExp(r'<unused\d+>'), '')
        .replaceAll(RegExp(r'\[@BOS@\]'), '')
        .replaceAll('<bos>', '')
        .replaceAll('<mask>', '')
        .replaceAll('<pad>', '')
        .replaceAll('<unk>', '')
        .replaceAll('<s>', '')
        .replaceAll('</s>', '');
  }

  bool _hasPrintableText(String text) {
    for (final rune in text.runes) {
      if (rune > 32 &&
          rune != 0x7F &&
          rune != 0x200B &&
          rune != 0x200C &&
          rune != 0x200D &&
          rune != 0xFEFF &&
          rune != 0xFFFD) {
        return true;
      }
    }
    return false;
  }

  List<ChatMessage> _buildChatMessages(
    String prompt,
    List<Map<String, String>>? history,
    String systemPrompt, {
    String? imagePath,
  }) {
    final messages = <ChatMessage>[];
    messages.add(ChatMessage(role: 'system', content: systemPrompt));

    if (history != null && history.isNotEmpty) {
      var recent = history.length > 16
          ? history.sublist(history.length - 16)
          : List.of(history);
      if (recent.isNotEmpty &&
          recent.last['role'] == 'user' &&
          recent.last['content'] == prompt) {
        recent = recent.sublist(0, recent.length - 1);
      }
      for (final msg in recent) {
        final content = msg['content'] ?? '';
        messages
            .add(ChatMessage(role: msg['role'] ?? 'user', content: content));
      }
    }

    messages
        .add(ChatMessage(role: 'user', content: prompt, imagePath: imagePath));
    return messages;
  }

  String _buildPrompt(
    String userMessage,
    List<Map<String, String>>? history,
    String systemPrompt,
    String modelName,
  ) {
    // Auto-detect template from model name
    final name = modelName.toLowerCase();
    if (name.contains('gemma')) {
      return _buildGemma(userMessage, history, systemPrompt);
    }
    if (name.contains('llama-3') || name.contains('llama3')) {
      return _buildLlama3(userMessage, history, systemPrompt);
    }
    return _buildChatML(userMessage, history, systemPrompt);
  }

  String _buildChatML(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write('<|im_start|>system\n$sys<|im_end|>\n');
    if (history != null) {
      final recent =
          history.length > 8 ? history.sublist(history.length - 8) : history;
      for (final m in recent) {
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write('<|im_start|>${m['role'] ?? 'user'}\n$trunc<|im_end|>\n');
      }
    }
    buf.write('<|im_start|>user\n$msg<|im_end|>\n<|im_start|>assistant\n');
    return buf.toString();
  }

  String _buildGemma(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<start_of_turn>user\n$sys<end_of_turn>\n<start_of_turn>model\nUnderstood.<end_of_turn>\n');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final role = m['role'] == 'assistant' ? 'model' : 'user';
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write('<start_of_turn>$role\n$trunc<end_of_turn>\n');
      }
    }
    buf.write('<start_of_turn>user\n$msg<end_of_turn>\n<start_of_turn>model\n');
    return buf.toString();
  }

  String _buildLlama3(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$sys<|eot_id|>');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write(
            '<|start_header_id|>${m['role'] ?? 'user'}<|end_header_id|>\n\n$trunc<|eot_id|>');
      }
    }
    buf.write(
        '<|start_header_id|>user<|end_header_id|>\n\n$msg<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n');
    return buf.toString();
  }
}
