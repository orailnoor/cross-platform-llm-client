import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_litert_lm_method_channel.dart';

abstract class FlutterLitertLmPlatform extends PlatformInterface {
  FlutterLitertLmPlatform() : super(token: _token);

  static final Object _token = Object();
  static FlutterLitertLmPlatform _instance = MethodChannelFlutterLitertLm();

  static FlutterLitertLmPlatform get instance => _instance;

  static set instance(FlutterLitertLmPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Create and initialize an engine with the given config.
  /// Returns an engine ID.
  Future<String> createEngine(Map<String, dynamic> config);

  /// Dispose an engine and release its resources.
  Future<void> disposeEngine(String engineId);

  /// Create a conversation on the given engine.
  /// Returns a conversation ID.
  Future<String> createConversation(
    String engineId,
    Map<String, dynamic>? config,
  );

  /// Dispose a conversation and release its resources.
  Future<void> disposeConversation(String conversationId);

  /// Send a message synchronously and return the full response.
  Future<Map<String, dynamic>> sendMessage(
    String conversationId,
    List<Map<String, dynamic>> contents,
    Map<String, Object>? extraContext,
  );

  /// Send a message and stream back partial responses as they're generated.
  Stream<Map<String, dynamic>> sendMessageStream(
    String conversationId,
    List<Map<String, dynamic>> contents,
    Map<String, Object>? extraContext,
  );

  /// Get the number of tokens in the given text.
  Future<int> countTokens(String engineId, String text);
}
