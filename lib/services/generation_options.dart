/// Per-request generation options (OpenAI API). Null fields fall back to the
/// app's settings / the engine defaults.
class GenerationOptions {
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? minP;
  final int? seed;
  final double? repeatPenalty;
  final double? frequencyPenalty;
  final double? presencePenalty;

  /// GGUF: send [prompt] to the model as-is (no chat template).
  final bool rawPrompt;

  /// GGUF: GBNF grammar (root rule "root") constraining the reply.
  final String? grammar;

  /// GGUF: a grammar was already staged natively (LlamaExt.chatPrepare);
  /// don't clear it before generating.
  final bool grammarStaged;

  const GenerationOptions({
    this.temperature,
    this.topP,
    this.topK,
    this.minP,
    this.seed,
    this.repeatPenalty,
    this.frequencyPenalty,
    this.presencePenalty,
    this.rawPrompt = false,
    this.grammar,
    this.grammarStaged = false,
  });

  static const none = GenerationOptions();
}

/// What the last generation did. Token counts are exact for GGUF and
/// estimated (≈4 characters per token) for LiteRT.
class GenerationStats {
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;

  /// stop | length | abort | error
  final String finish;
  final bool estimated;
  final int mtpDrafted;
  final int mtpAccepted;
  final double promptMs;
  final double genMs;

  const GenerationStats({
    required this.promptTokens,
    required this.completionTokens,
    this.cachedTokens = 0,
    required this.finish,
    this.estimated = false,
    this.mtpDrafted = 0,
    this.mtpAccepted = 0,
    this.promptMs = 0,
    this.genMs = 0,
  });

  factory GenerationStats.fromNative(Map<String, dynamic> m) => GenerationStats(
        promptTokens: (m['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (m['completion_tokens'] as num?)?.toInt() ?? 0,
        cachedTokens: (m['cached_tokens'] as num?)?.toInt() ?? 0,
        finish: m['finish'] as String? ?? 'stop',
        mtpDrafted: (m['mtp_drafted'] as num?)?.toInt() ?? 0,
        mtpAccepted: (m['mtp_accepted'] as num?)?.toInt() ?? 0,
        promptMs: (m['prompt_ms'] as num?)?.toDouble() ?? 0,
        genMs: (m['gen_ms'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'cached_tokens': cachedTokens,
        'finish': finish,
        'estimated': estimated,
        'mtp_drafted': mtpDrafted,
        'mtp_accepted': mtpAccepted,
        'prompt_ms': promptMs,
        'gen_ms': genMs,
      };
}
