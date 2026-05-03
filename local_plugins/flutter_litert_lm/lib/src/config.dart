import 'backend.dart';
import 'message.dart';
import 'sampler_config.dart';
import 'tool.dart';

/// Configuration for creating a LiteRT-LM engine.
class LiteLmEngineConfig {
  /// Path to the .litertlm model file on device.
  final String modelPath;

  /// Hardware backend for inference. Defaults to CPU.
  final LiteLmBackend backend;

  /// Optional cache directory for compiled model artifacts.
  /// Improves subsequent load times.
  final String? cacheDir;

  /// Backend for vision (image) processing. Required for multimodal image input.
  final LiteLmBackend? visionBackend;

  /// Backend for audio processing. Required for multimodal audio input.
  final LiteLmBackend? audioBackend;

  const LiteLmEngineConfig({
    required this.modelPath,
    this.backend = LiteLmBackend.cpu,
    this.cacheDir,
    this.visionBackend,
    this.audioBackend,
  });

  Map<String, dynamic> toMap() => {
        'modelPath': modelPath,
        'backend': backend.name,
        if (cacheDir != null) 'cacheDir': cacheDir,
        if (visionBackend != null) 'visionBackend': visionBackend!.name,
        if (audioBackend != null) 'audioBackend': audioBackend!.name,
      };
}

/// Configuration for creating a conversation.
class LiteLmConversationConfig {
  /// System instruction for the conversation.
  final String? systemInstruction;

  /// Initial messages to seed the conversation history.
  final List<LiteLmMessage>? initialMessages;

  /// Sampling configuration (topK, topP, temperature).
  final LiteLmSamplerConfig? samplerConfig;

  /// Tools available to the model during this conversation.
  final List<LiteLmTool>? tools;

  /// Whether to automatically execute tool calls. Defaults to true.
  final bool automaticToolCalling;

  const LiteLmConversationConfig({
    this.systemInstruction,
    this.initialMessages,
    this.samplerConfig,
    this.tools,
    this.automaticToolCalling = true,
  });

  Map<String, dynamic> toMap() => {
        if (systemInstruction != null) 'systemInstruction': systemInstruction,
        if (initialMessages != null)
          'initialMessages': initialMessages!.map((m) => m.toMap()).toList(),
        if (samplerConfig != null) 'samplerConfig': samplerConfig!.toMap(),
        if (tools != null) 'tools': tools!.map((t) => t.toMap()).toList(),
        'automaticToolCalling': automaticToolCalling,
      };
}
