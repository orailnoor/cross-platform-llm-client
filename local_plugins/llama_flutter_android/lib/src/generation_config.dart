/// Configuration for text generation.
///
/// Allows users to customize generation parameters.
class GenerationConfig {
  /// Maximum tokens to generate (default: 256)
  /// 
  /// FLLAMA uses higher defaults for better responses.
  final int maxTokens;

  /// Temperature for sampling (range: 0.0–2.0, default: 0.7)
  ///
  /// - Lower = more focused, deterministic responses  
  /// - Higher = more creative, diverse responses  
  /// 
  /// FLLAMA recommends 0.7 as a balanced default.
  final double temperature;

  /// Top-p (nucleus) sampling threshold (range: 0.0–1.0, default: 0.9)
  ///
  /// FLLAMA uses 0.9 as the default for balanced diversity.
  final double topP;

  /// Top-k sampling limit (default: 40)
  ///
  /// A llama.cpp-specific parameter that restricts sampling
  /// to the top-k most likely tokens.
  final int topK;

  /// Repetition penalty (range: 1.0–1.5, default: 1.1)
  ///
  /// Discourages repeating the same phrases.
  /// FLLAMA uses 1.1 by default.
  final double repeatPenalty;

  /// Random seed for reproducibility (null = random)
  ///
  /// FLLAMA supports this for deterministic results.
  final int? seed;

  const GenerationConfig({
    this.maxTokens = 256,
    this.temperature = 0.7,
    this.topP = 0.9,
    this.topK = 40,
    this.repeatPenalty = 1.1,
    this.seed,
  });
}

/// Configuration for model loading.
///
/// Controls how models are loaded and executed.
class ModelLoadConfig {
  /// Context window size in tokens (default: 2048)
  ///
  /// FLLAMA uses 2048 as the default for better context management.
  final int contextSize;

  /// Number of CPU threads (default: 4)
  ///
  /// More threads = faster inference, but higher CPU usage.
  final int threads;

  /// Number of GPU layers to offload (null = CPU only)
  ///
  /// FLLAMA uses `99` as a special value for auto-detection.
  final int? gpuLayers;

  const ModelLoadConfig({
    this.contextSize = 2048,
    this.threads = 4,
    this.gpuLayers,
  });
}

/// Helper class for managing model context and token limits.
///
/// Uses the **80% rule**:  
/// Only 80% of the total context window is used to leave
/// a safety buffer and prevent truncation.
///
/// Example:
/// - Context: 2048 tokens  
/// - Safe limit: 1638 tokens (80%)  
/// - Safety buffer: 410 tokens (20%)
class ContextHelper {
  /// Total context window size.
  final int contextSize;

  /// Maximum percentage of context allowed before trimming.
  static const double safeUsageLimit = 0.80;

  /// Maximum number of messages to retain (including system prompt).
  ///
  /// FLLAMA-inspired: increased from 10 to 15 for better context preservation.
  final int maxMessagesToKeep;

  const ContextHelper({
    required this.contextSize,
    this.maxMessagesToKeep = 15,
  });

  /// Returns the safe token limit (80% of total context).
  int get safeTokenLimit => (contextSize * safeUsageLimit).floor();

  /// Returns the size of the safety buffer (20% of total context).
  int get safetyBuffer => contextSize - safeTokenLimit;

  /// Checks if context usage is approaching the safe limit (≥72% of total).
  ///
  /// 72% = 90% of the 80% safe threshold.
  bool isNearLimit(int tokensUsed) => tokensUsed >= (safeTokenLimit * 0.9);

  /// Checks if context must be cleared (≥80% of total).
  bool mustClear(int tokensUsed) => tokensUsed >= safeTokenLimit;

  /// Estimates the number of tokens in the given text.
  ///
  /// Inspired by FLLAMA’s caching-based token estimator.
  /// 
  /// - English text: ~1 token ≈ 3.5–4 characters  
  /// - Accounts for punctuation and numbers
  int estimateTokens(String text) {
    if (text.trim().isEmpty) return 0;

    // Base estimation
    final baseTokens = (text.length / 3.7).ceil();

    // Adjust for punctuation
final punctuationCount = _countMatches(text, r'''[.!?,;:\-_\(\)\[\]\{\}"'`]''');
    final specialTokenEstimate = (punctuationCount * 0.3).ceil();

    // Adjust for numbers
    final numberCount = _countMatches(text, r'\d+');
    final numberTokenEstimate = (numberCount * 0.2).ceil();

    // Final total
    final totalEstimate = baseTokens + specialTokenEstimate + numberTokenEstimate;
    return totalEstimate > 0 ? totalEstimate : 1;
  }

  /// Calculates a safe number of tokens to generate based on available context.
  ///
  /// Ensures generation does not exceed the safe token limit.
  int calculateSafeMaxTokens(int tokensUsed, int requestedMaxTokens) {
    final available = safeTokenLimit - tokensUsed;

    if (available < 50) {
      return 50; // Minimum fallback
    } else if (available < requestedMaxTokens) {
      return available; // Use what's safely available
    } else {
      return requestedMaxTokens.clamp(0, safeTokenLimit);
    }
  }

  /// Returns the percentage of context used (0–100%).
  double getUsagePercentage(int tokensUsed) =>
      (tokensUsed / contextSize) * 100;

  /// Utility method for regex counting.
  int _countMatches(String text, String pattern) =>
      RegExp(pattern).allMatches(text).length;
}
