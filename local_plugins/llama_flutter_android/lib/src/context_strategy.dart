/// Context management strategy for handling token limits
class ContextStrategy {
  final int contextSize;
  final int reservedForGeneration;
  
  // Thresholds
  static const double warningThreshold = 0.70;  // 70% - show warning
  static const double criticalThreshold = 0.85; // 85% - must act
  
  int currentTokens = 0;
  
  ContextStrategy({
    required this.contextSize,
    this.reservedForGeneration = 512,
  });
  
  /// Get current usage ratio (0.0 to 1.0)
  double get usageRatio => currentTokens / contextSize;
  
  /// Check if warning should be shown
  bool get needsWarning => usageRatio >= warningThreshold;
  
  /// Check if action is required
  bool get needsAction => usageRatio >= criticalThreshold;
  
  /// Get available tokens for new content
  int get tokensAvailable => contextSize - currentTokens - reservedForGeneration;
  
  /// Rough token estimation (1 token ≈ 3.5 chars for English)
  int estimateTokens(String text) => (text.length / 3.5).ceil();
  
  /// Estimate tokens for a list of strings
  int estimateTokensForList(List<String> texts) {
    final totalChars = texts.fold<int>(0, (sum, text) => sum + text.length);
    return (totalChars / 3.5).ceil();
  }
  
  /// Get recommended action for next message
  ContextAction getRecommendedAction(String nextMessage) {
    final estimatedNewTokens = estimateTokens(nextMessage);
    final projectedUsage = (currentTokens + estimatedNewTokens) / contextSize;
    
    if (projectedUsage > 0.95) {
      return ContextAction.mustClear;
    } else if (projectedUsage > criticalThreshold) {
      return ContextAction.shouldTrimOrSummarize;
    } else if (projectedUsage > warningThreshold) {
      return ContextAction.showWarning;
    }
    return ContextAction.proceed;
  }
  
  /// Calculate dynamic max tokens based on available space
  int calculateDynamicMaxTokens({int defaultMaxTokens = 512}) {
    final available = tokensAvailable;
    
    if (available < 200) {
      return 100; // Very tight, short responses only
    } else if (available < 500) {
      return 256; // Moderate
    } else if (available < defaultMaxTokens) {
      return available; // Use what's available
    } else {
      return defaultMaxTokens; // Full generation
    }
  }
}

/// Actions to take based on context usage
enum ContextAction {
  /// Context is fine, proceed normally
  proceed,
  
  /// Show warning to user but continue
  showWarning,
  
  /// Should trim old messages or summarize
  shouldTrimOrSummarize,
  
  /// Must clear context or error will occur
  mustClear,
}
