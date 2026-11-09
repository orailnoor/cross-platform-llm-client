import 'dart:async';

class OpenAiServerService {
  bool get isRunning => false;
  String? get localUrl => null;

  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    bool allowNoKey = false,
    void Function(String)? onLog,
  }) async {
    throw UnsupportedError('Local API server is not available on this platform.');
  }

  void updateApiKey(String? apiKey) {}

  Future<void> stop() async {}
}
