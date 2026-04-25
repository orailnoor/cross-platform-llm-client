import 'dart:async';
import 'package:flutter/services.dart';
import 'llama_api.dart';

/// User-friendly controller for llama.cpp
class LlamaController implements LlamaFlutterApi {
  final _api = LlamaHostApi();
  StreamController<String>? _tokenController;
  final _progressController = StreamController<double>.broadcast();
  
  bool _isLoading = false;
  bool _isGenerating = false;

  LlamaController({BinaryMessenger? binaryMessenger}) {
    LlamaFlutterApi.setUp(
      this,
      binaryMessenger: binaryMessenger,
    );
  }

  /// Load a GGUF model
  Future<void> loadModel({
    required String modelPath,
    int threads = 4,
    int contextSize = 2048,
    int? gpuLayers,
  }) async {
    if (_isLoading) throw StateError('Already loading');
    final loaded = await isModelLoaded();
    if (loaded) throw StateError('Model already loaded');

    _isLoading = true;
    try {
      await _api.loadModel(ModelConfig(
        modelPath: modelPath,
        nThreads: threads,
        contextSize: contextSize,
        nGpuLayers: gpuLayers,
      ));
    } finally {
      _isLoading = false;
    }
  }

  /// Generate text with streaming tokens
  Stream<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double typicalP = 1.0,
    double repeatPenalty = 1.1,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int repeatLastN = 64,
    int mirostat = 0,
    double mirostatTau = 5.0,
    double mirostatEta = 0.1,
    int? seed,
    bool penalizeNewline = true,
  }) {
    if (_isGenerating) {
      throw StateError('Already generating');
    }

    _isGenerating = true;
    _tokenController = StreamController<String>.broadcast();
    
    // Start generation
    _api.generate(GenerateRequest(
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      typicalP: typicalP,
      repeatPenalty: repeatPenalty,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      repeatLastN: repeatLastN,
      mirostat: mirostat,
      mirostatTau: mirostatTau,
      mirostatEta: mirostatEta,
      seed: seed,
      penalizeNewline: penalizeNewline,
    ));

    return _tokenController!.stream;
  }

  /// Stop current generation
  Future<void> stop() async {
    if (!_isGenerating) return;
    await _api.stop();
    _isGenerating = false;
  }

  /// Unload model and free resources
  Future<void> dispose() async {
    await stop();
    await _api.dispose();
    await _tokenController?.close();
    await _progressController.close();
  }

  /// Check if model is loaded
  Future<bool> isModelLoaded() async => await _api.isModelLoaded();

  /// Get list of supported chat templates
  Future<List<String>> getSupportedTemplates() async => await _api.getSupportedTemplates();

  /// Generate chat response with automatic template formatting
  Stream<String> generateChat({
    required List<ChatMessage> messages,
    String? template,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    double minP = 0.05,
    double typicalP = 1.0,
    double repeatPenalty = 1.1,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int repeatLastN = 64,
    int mirostat = 0,
    double mirostatTau = 5.0,
    double mirostatEta = 0.1,
    int? seed,
    bool penalizeNewline = true,
  }) {
    if (_isGenerating) {
      throw StateError('Already generating');
    }

    _isGenerating = true;
    _tokenController = StreamController<String>.broadcast();
    
    // Start chat generation
    _api.generateChat(ChatRequest(
      messages: messages,
      template: template,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      typicalP: typicalP,
      repeatPenalty: repeatPenalty,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      repeatLastN: repeatLastN,
      mirostat: mirostat,
      mirostatTau: mirostatTau,
      mirostatEta: mirostatEta,
      seed: seed,
      penalizeNewline: penalizeNewline,
    ));

    return _tokenController!.stream;
  }

  /// Get loading progress stream (0.0 to 1.0)
  Stream<double> get loadProgress => _progressController.stream;

  /// Check if currently generating
  bool get isGenerating => _isGenerating;

  /// Get current context usage information
  Future<ContextInfo> getContextInfo() async {
    return await _api.getContextInfo();
  }

  /// Clear conversation context (keeps model loaded)
  Future<void> clearContext() async {
    await _api.clearContext();
  }

  /// Set system prompt token length for smart context management
  void setSystemPromptLength(int length) {
    _api.setSystemPromptLength(length);
  }

  /// Register a custom chat template
  /// 
  /// Template content should use placeholders:
  /// - {system} for system messages
  /// - {user} for user messages
  /// - {assistant} for assistant messages
  /// 
  /// Example: "<s>[INST]{user}[/INST]{assistant}</s>"
  Future<void> registerCustomTemplate(String name, String content) async {
    await _api.registerCustomTemplate(name, content);
  }

  /// Unregister a custom chat template
  ///
  /// Removes a previously registered custom template
  Future<void> unregisterCustomTemplate(String name) async {
    await _api.unregisterCustomTemplate(name);
  }

  /// Detect GPU capabilities on this device.
  ///
  /// Returns [GpuInfo] with Vulkan device details and a non-binding
  /// [GpuInfo.recommendedGpuLayers] value.
  ///
  /// Notes:
  /// - [GpuInfo.deviceLocalMemoryBytes] reflects the largest device-local
  ///   Vulkan heap. On Android (UMA), this equals total system RAM, not
  ///   dedicated VRAM.
  /// - [GpuInfo.vulkanSupported] is true only when both a Vulkan instance
  ///   and a compute queue were confirmed. Vulkan availability does not
  ///   guarantee GPU is faster than CPU for a given model.
  /// - The caller is responsible for the final [ModelConfig.nGpuLayers] decision.
  Future<GpuInfo> detectGpu() async {
    return await _api.detectGpu();
  }

  // Implementation of LlamaFlutterApi interface methods
  @override
  void onToken(String token) {
    _tokenController?.add(token);
  }

  @override
  void onDone() {
    _isGenerating = false;
    _tokenController?.close();
    _tokenController = null;
  }

  @override
  void onError(String error) {
    _tokenController?.addError(Exception(error));
  }

  @override
  void onLoadProgress(double progress) {
    _progressController.add(progress);
  }}