/// Stub inference engine for platforms that don't support local GGUF models
/// (iOS, Web). All methods are no-ops that return appropriate errors.

bool get supportsLocalInference => false;

class LoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  LoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
  });
}

class InferenceEngine {
  Future<LoadResult> loadModel({
    required String modelPath,
    required int contextSize,
    required String deviceTier,
    void Function(double)? onProgress,
  }) async {
    return LoadResult(
      success: false,
      message: 'Local inference is not available on this platform.',
    );
  }

  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required String modelName,
    required int maxTokens,
    required double temperature,
    void Function(String token)? onToken,
  }) async {
    return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
  }

  Future<void> stop() async {}
  Future<void> dispose() async {}
}
