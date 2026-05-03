import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'flutter_litert_lm_platform_interface.dart';

class MethodChannelFlutterLitertLm extends FlutterLitertLmPlatform {
  static const _methodChannel = MethodChannel('flutter_litert_lm');
  static const _eventChannel = EventChannel('flutter_litert_lm/stream');

  @override
  Future<String> createEngine(Map<String, dynamic> config) async {
    final result = await _methodChannel.invokeMethod<String>(
      'createEngine',
      config,
    );
    return result!;
  }

  @override
  Future<void> disposeEngine(String engineId) async {
    await _methodChannel.invokeMethod('disposeEngine', {'engineId': engineId});
  }

  @override
  Future<String> createConversation(
    String engineId,
    Map<String, dynamic>? config,
  ) async {
    final result = await _methodChannel.invokeMethod<String>(
      'createConversation',
      {'engineId': engineId, if (config != null) 'config': config},
    );
    return result!;
  }

  @override
  Future<void> disposeConversation(String conversationId) async {
    await _methodChannel.invokeMethod(
      'disposeConversation',
      {'conversationId': conversationId},
    );
  }

  @override
  Future<Map<String, dynamic>> sendMessage(
    String conversationId,
    List<Map<String, dynamic>> contents,
    Map<String, Object>? extraContext,
  ) async {
    final result = await _methodChannel.invokeMethod<Map>(
      'sendMessage',
      {
        'conversationId': conversationId,
        'contents': contents,
        if (extraContext != null) 'extraContext': extraContext,
      },
    );
    return Map<String, dynamic>.from(result!);
  }

  @override
  Stream<Map<String, dynamic>> sendMessageStream(
    String conversationId,
    List<Map<String, dynamic>> contents,
    Map<String, Object>? extraContext,
  ) {
    // First, tell native side to start streaming
    _methodChannel.invokeMethod('startMessageStream', {
      'conversationId': conversationId,
      'contents': contents,
      if (extraContext != null) 'extraContext': extraContext,
    });

    return _eventChannel.receiveBroadcastStream({
      'conversationId': conversationId,
    }).map((event) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      if (event is String) {
        return Map<String, dynamic>.from(jsonDecode(event) as Map);
      }
      return <String, dynamic>{'text': event.toString()};
    });
  }

  @override
  Future<int> countTokens(String engineId, String text) async {
    final result = await _methodChannel.invokeMethod<int>(
      'countTokens',
      {'engineId': engineId, 'text': text},
    );
    return result!;
  }
}
