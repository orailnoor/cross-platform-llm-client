import 'dart:async';
import 'dart:io' show Platform, Directory;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Whether the current platform supports local inference.
bool get supportsLocalInference => Platform.isAndroid || Platform.isIOS;

/// Result from model loading.
class LoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  final String runtime;
  LoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
    this.runtime = '',
  });
}

/// Android & iOS inference engine — wraps llama_flutter_android.
class InferenceEngine {
  LlamaController? _controller;
  LiteLmEngine? _liteEngine;
  LiteLmConversation? _liteConversation;
  StreamSubscription? _subscription;
  Timer? _idleTimer;
  void Function()? _onStop;
  bool _isLiteRt = false;
  bool _disposed = false;
  bool _hasLoadedModel = false;

  Future<LoadResult> loadModel({
    required String modelPath,
    String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    void Function(double)? onProgress,
  }) async {
    _disposed = false;
    final runtime = _runtimeFor(modelPath, modelRuntime);
    if (runtime == 'litert') {
      return _loadLiteRtModel(modelPath, onProgress: onProgress);
    }

    _isLiteRt = false;
    _controller = LlamaController();

    // ── GPU Detection ──
    int gpuLayers = 0;
    String gpuNameStr = '';

    try {
      final gpu = await _controller!.detectGpu();
      gpuNameStr = gpu.gpuName;

      print('[Inference] GPU: ${gpu.gpuName}');
      print('[Inference]   Vulkan: ${gpu.vulkanSupported}');
      print('[Inference]   Free RAM: ${gpu.freeRamBytes ~/ 1024 ~/ 1024}MB');
      print('[Inference]   Recommended layers: ${gpu.recommendedGpuLayers}');

      if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
        final gpuNum = _extractGpuModel(gpu.gpuName);
        if (gpuNum >= 700) {
          gpuLayers = 99;
          print('[Inference] ✓ High-end GPU ($gpuNum) → full offload');
        } else if (gpuNum >= 650) {
          gpuLayers = gpu.recommendedGpuLayers;
          print('[Inference] ✓ Upper-mid GPU ($gpuNum) → $gpuLayers layers');
        } else {
          gpuLayers = 0;
          print(
              '[Inference] Mid-range GPU ($gpuNum) — CPU is faster, skipping GPU');
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

    // ── Load Progress ──
    try {
      _controller!.loadProgress.listen((progress) {
        onProgress?.call(_normalizeProgress(progress));
      });
    } catch (_) {}

    // ── Load ──
    await _controller!.loadModel(
      modelPath: modelPath,
      threads: threads,
      contextSize: contextSize,
      gpuLayers: gpuLayers,
    );
    _hasLoadedModel = true;

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
    );
  }

  Future<LoadResult> _loadLiteRtModel(
    String modelPath, {
    void Function(double)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'LiteRT-LM is enabled for Android only in this app.');
    }

    _isLiteRt = true;
    _controller = null;

    try {
      onProgress?.call(0.05);
      // Clear the cache directory to prevent OpenCL delegate crashes 
      // from corrupted serialized context data.
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/litert_cache');
      if (await cacheDir.exists()) {
        try {
          await cacheDir.delete(recursive: true);
        } catch (_) {}
      }
      await cacheDir.create(recursive: true);
      onProgress?.call(0.18);

      _liteEngine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: modelPath,
          backend: LiteLmBackend.cpu,
          cacheDir: cacheDir.path,
        ),
      );
      _hasLoadedModel = true;
      onProgress?.call(0.92);
      print('[Inference] LiteRT-LM loaded with CPU backend');
      return LoadResult(
        success: true,
        message: 'LiteRT-LM model loaded (CPU backend).',
        gpuName: '',
        gpuLayers: 0,
        runtime: 'litert',
      );
    } catch (error) {
      print('[Inference] LiteRT-LM CPU load failed: $error');
      rethrow;
    }
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
    void Function(String token)? onToken,
  }) async {
    if (_isLiteRt) {
      return _generateLiteRt(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        onToken: onToken,
      );
    }

    if (_controller == null) throw Exception('No model loaded');

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;

    void finish(String result) {
      if (!completed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
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
        buffer.write(token);
        tokenCount++;
        onToken?.call(token);
        _idleTimer?.cancel();
        _idleTimer = Timer(const Duration(seconds: 5), () {
          print('[Inference] Idle timeout — $tokenCount tokens');
          finish(buffer.toString());
        });
      },
      onDone: () {
        print('[Inference] Stream onDone — $tokenCount tokens total');
        finish(buffer.toString());
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
    Future.delayed(const Duration(seconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finish(partial.isEmpty ? 'ERROR: Generation timed out.' : partial);
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
    void Function(String token)? onToken,
  }) async {
    if (_liteEngine == null) throw Exception('No LiteRT-LM model loaded');

    await _subscription?.cancel();
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
          topK: 40,
          topP: 0.95,
        ),
      ),
    );

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;
    bool hasVisibleOutput = false;
    var tokenCount = 0;

    void finish(String result) {
      if (!completed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
        if (!completer.isCompleted) completer.complete(result);
      }
    }

    _onStop = () => finish(buffer.toString());

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
        tokenCount++;
        buffer.write(text);
        onToken?.call(text);
        _idleTimer?.cancel();
        _idleTimer = Timer(const Duration(seconds: 5), () {
          print('[Inference] LiteRT-LM idle timeout - $tokenCount chunks');
          finish(buffer.toString());
        });
      },
      onDone: () {
        print('[Inference] LiteRT-LM stream done - $tokenCount chunks');
        finish(buffer.toString());
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

    Future.delayed(const Duration(seconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finish(partial.isEmpty
            ? 'ERROR: LiteRT-LM generation timed out.'
            : partial);
      }
    });

    return completer.future;
  }

  Future<void> stop() async {
    if (_disposed) return;
    _idleTimer?.cancel();
    _subscription?.cancel();
    if (_isLiteRt) {
      try {
        await _liteConversation?.dispose();
      } catch (_) {}
      _liteConversation = null;
      _onStop?.call();
      return;
    }
    try {
      await _controller?.stop();
    } catch (_) {}
    _onStop?.call();
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
    _controller = null;
    _liteConversation = null;
    _liteEngine = null;
    _isLiteRt = false;
    _hasLoadedModel = false;
  }

  // ── Helpers ──

  int _extractGpuModel(String gpuName) {
    final match = RegExp(r'(\d{3})').firstMatch(gpuName.toLowerCase());
    return match != null ? (int.tryParse(match.group(1)!) ?? 0) : 0;
  }

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
    return text
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '')
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .replaceAll('\uFFFD', '');
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
