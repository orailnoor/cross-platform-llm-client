import '../flutter_litert_lm_platform_interface.dart';
import 'config.dart';
import 'conversation.dart';

/// The main entry point for LiteRT-LM inference.
///
/// An engine loads a model file and provides methods to create conversations.
///
/// Usage:
/// ```dart
/// final engine = await LiteLmEngine.create(
///   LiteLmEngineConfig(modelPath: '/path/to/model.litertlm'),
/// );
/// final conversation = await engine.createConversation();
/// final response = await conversation.sendMessage('Hello!');
/// print(response.text);
/// await conversation.dispose();
/// await engine.dispose();
/// ```
class LiteLmEngine {
  final String _id;
  bool _disposed = false;

  LiteLmEngine._(this._id);

  /// Create and initialize an engine with the given configuration.
  ///
  /// This loads the model into memory and prepares it for inference.
  /// May take several seconds depending on model size and backend.
  static Future<LiteLmEngine> create(LiteLmEngineConfig config) async {
    final id =
        await FlutterLitertLmPlatform.instance.createEngine(config.toMap());
    return LiteLmEngine._(id);
  }

  /// The native engine ID.
  String get id => _id;

  /// Create a new conversation session.
  ///
  /// Each conversation maintains its own message history.
  Future<LiteLmConversation> createConversation([
    LiteLmConversationConfig? config,
  ]) async {
    _ensureNotDisposed();
    final id = await FlutterLitertLmPlatform.instance.createConversation(
      _id,
      config?.toMap(),
    );
    return LiteLmConversation.fromId(id);
  }

  /// Count the number of tokens in the given text.
  Future<int> countTokens(String text) async {
    _ensureNotDisposed();
    return FlutterLitertLmPlatform.instance.countTokens(_id, text);
  }

  /// Release native resources for this engine.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await FlutterLitertLmPlatform.instance.disposeEngine(_id);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('Engine has been disposed');
    }
  }
}
