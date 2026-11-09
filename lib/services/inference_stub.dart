/// Stub inference engine for platforms that don't support local GGUF models
/// (Web). All methods are no-ops that return appropriate errors.
library;

import 'generation_options.dart';

bool get supportsLocalInference => false;

bool get isRunning32Bit => false;

Future<int> fileLength(String path) async => 0;

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
  bool get ggufVisionLoaded => false;
  GenerationStats? lastStats;
  String mtpStatus = '';

  Future<LoadResult> loadModel({
    required String modelPath,
    String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    String liteRtPerformanceMode = 'cpu_safe',
    bool forceLiteRtCpu = true,
    bool clearLiteRtCache = false,
    bool enableLiteRtVision = false,
    bool allowGgufGpu = false,
    String? mmprojPath,
    bool lazyVision = false,
    bool mtpEnabled = false,
    String? mtpDraftPath,
    int mtpDraftTokens = 3,
    Map<String, dynamic>? engineOptions,
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
    String source = 'chat',
    GenerationOptions options = GenerationOptions.none,
    void Function(String token)? onToken,
  }) async {
    return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
  }

  Future<void> stop() async {}
  Future<GenerationStats?> nativeStats() async => null;
  Future<List<int>> tokenize(String text,
          {bool addSpecial = true, bool parseSpecial = true}) async =>
      const [];
  Future<String> detokenize(List<int> tokens) async => '';
  Future<List<double>> embed(String text) async => const [];
  Future<Map<String, dynamic>> chatPrepare(Map<String, dynamic> request) async =>
      const {'error': 'unsupported'};
  Future<Map<String, dynamic>> chatParse(String text) async =>
      const {'error': 'unsupported'};
  Future<String> jsonSchemaToGrammar(Object schema) async => '';
  Future<Map<String, dynamic>> mtpInfo() async => const {};
  Future<void> resetConversation() async {}
  Future<dynamic> getContextInfo() async => null;
  Future<void> dispose() async {}
}
