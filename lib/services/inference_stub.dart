/// Stub inference engine for platforms that don't support local GGUF models
/// (Web). All methods are no-ops that return appropriate errors.

bool get supportsLocalInference => false;

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

class InferenceEngine {
  Future<LoadResult> loadModel({
    required String modelPath,
    String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    String liteRtPerformanceMode = 'cpu_safe',
    bool forceLiteRtCpu = true,
    bool clearLiteRtCache = false,
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
    String? imagePath,
    String? audioPath,
    void Function(String token)? onToken,
  }) async {
    return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
  }

  Future<void> stop() async {}
  Future<dynamic> getContextInfo() async => null;
  Future<void> dispose() async {}
}
