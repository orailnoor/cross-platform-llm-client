class ThoughtParts {
  final String thought;
  final String answer;
  final bool isThinking;

  const ThoughtParts({
    required this.thought,
    required this.answer,
    required this.isThinking,
  });

  bool get hasThought => thought.trim().isNotEmpty;
  bool get hasAnswer => answer.trim().isNotEmpty;
}

ThoughtParts splitThoughtTags(String text) {
  final startExp = RegExp(r'<think>', caseSensitive: false);
  final endExp = RegExp(r'</think>', caseSensitive: false);
  final start = startExp.firstMatch(text);

  if (start == null) {
    return ThoughtParts(thought: '', answer: text, isThinking: false);
  }

  final before = text.substring(0, start.start);
  final afterStart = text.substring(start.end);
  final end = endExp.firstMatch(afterStart);

  if (end == null) {
    return ThoughtParts(
      thought: afterStart,
      answer: before,
      isThinking: true,
    );
  }

  final thought = afterStart.substring(0, end.start);
  final after = afterStart.substring(end.end);
  final answer = '$before$after'.trimLeft();

  return ThoughtParts(
    thought: thought,
    answer: answer,
    isThinking: false,
  );
}
