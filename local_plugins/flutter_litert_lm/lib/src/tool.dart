/// Defines a tool that the model can call during conversation.
class LiteLmTool {
  /// Name of the tool/function.
  final String name;

  /// Description of what the tool does.
  final String description;

  /// JSON Schema describing the tool's parameters.
  /// Example:
  /// ```dart
  /// {
  ///   "type": "object",
  ///   "properties": {
  ///     "location": {"type": "string", "description": "City name"},
  ///     "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}
  ///   },
  ///   "required": ["location"]
  /// }
  /// ```
  final Map<String, dynamic> parameters;

  const LiteLmTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'description': description,
        'parameters': parameters,
      };

  factory LiteLmTool.fromMap(Map<String, dynamic> map) => LiteLmTool(
        name: map['name'] as String,
        description: map['description'] as String,
        parameters: Map<String, dynamic>.from(map['parameters'] as Map),
      );
}

/// A tool call made by the model.
class LiteLmToolCall {
  final String name;
  final Map<String, dynamic> arguments;

  const LiteLmToolCall({required this.name, required this.arguments});

  factory LiteLmToolCall.fromMap(Map<String, dynamic> map) => LiteLmToolCall(
        name: map['name'] as String,
        arguments: Map<String, dynamic>.from(map['arguments'] as Map),
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'arguments': arguments,
      };
}
