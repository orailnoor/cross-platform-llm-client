import 'dart:convert';

import 'package:flutter/services.dart';

/// Extensions on top of [LlamaController] (Android): structured output,
/// generation stats, MTP speculative decoding, Jinja chat templates with
/// tool calls, embeddings, tokenizer, and the API-server keep-awake switch.
class LlamaExt {
  static const _channel = MethodChannel('llama_flutter_android/ext');

  /// GBNF grammar (root rule "root") applied to the next generation only.
  /// An empty string clears a staged grammar.
  static Future<void> setGrammar(String grammar) =>
      _channel.invokeMethod('setGrammar', {'grammar': grammar});

  /// Converts a JSON schema to a GBNF grammar (throws on a bad schema).
  static Future<String> jsonSchemaToGrammar(Object schema) async =>
      await _channel.invokeMethod<String>('jsonSchemaToGrammar',
          {'schema': schema is String ? schema : jsonEncode(schema)}) ??
      '';

  /// What the last generation did: prompt_tokens, cached_tokens,
  /// completion_tokens, finish (stop|length|abort|error), prompt_ms, gen_ms,
  /// mtp, mtp_drafted, mtp_accepted, mtp_draft_steps.
  static Future<Map<String, dynamic>> lastStats() async =>
      _decode(await _channel.invokeMethod<String>('lastStats'));

  static Future<List<int>> tokenize(String text,
      {bool addSpecial = true, bool parseSpecial = true}) async {
    final list = await _channel.invokeListMethod<dynamic>('tokenize',
        {'text': text, 'addSpecial': addSpecial, 'parseSpecial': parseSpecial});
    return [for (final v in list ?? const []) (v as num).toInt()];
  }

  static Future<String> detokenize(List<int> tokens,
          {bool special = false}) async =>
      await _channel.invokeMethod<String>(
          'detokenize', {'tokens': tokens, 'special': special}) ??
      '';

  /// Pooled, normalised embedding of [text] from the loaded GGUF model.
  /// Clears the chat KV cache (the next reply re-reads its prompt).
  static Future<List<double>> embed(String text, {bool normalize = true}) async {
    final list = await _channel.invokeListMethod<dynamic>(
        'embed', {'text': text, 'normalize': normalize});
    return [for (final v in list ?? const []) (v as num).toDouble()];
  }

  static Future<bool> hasVision() async =>
      await _channel.invokeMethod<bool>('hasVision') ?? false;

  /// Loads the vision projector for the loaded model. Null on success,
  /// otherwise why it didn't load (the text model keeps working).
  static Future<String?> loadMmproj(String path, {int threads = 4}) =>
      _channel.invokeMethod<String>(
          'loadMmproj', {'path': path, 'threads': threads});

  /// Next model load: also load the model's own NextN (MTP) layers.
  static Future<void> setLoadMtp(bool loadLayers, {int nDraft = 3}) =>
      _channel.invokeMethod(
          'setLoadMtp', {'loadLayers': loadLayers, 'nDraft': nDraft});

  /// Creates the MTP draft head for the loaded model from [draftPath] (a
  /// separate draft GGUF) or, when empty, the model's own NextN layers.
  /// Null on success, otherwise why not.
  static Future<String?> loadMtp(String draftPath,
          {int nDraft = 3, double pMin = 0.0}) =>
      _channel.invokeMethod<String>(
          'loadMtp', {'path': draftPath, 'nDraft': nDraft, 'pMin': pMin});

  static Future<void> freeMtp() => _channel.invokeMethod('freeMtp');

  static Future<void> setMtp({required bool enabled, int nDraft = 0}) =>
      _channel.invokeMethod('setMtp', {'enabled': enabled, 'nDraft': nDraft});

  /// loaded, enabled, source, shared_kv, n_draft, total_drafted,
  /// total_accepted, acceptance, model_nextn_layers.
  static Future<Map<String, dynamic>> mtpInfo() async =>
      _decode(await _channel.invokeMethod<String>('mtpInfo'));

  static Future<Map<String, dynamic>> modelInfo() async =>
      _decode(await _channel.invokeMethod<String>('modelInfo'));

  /// Renders an OpenAI chat request with the model's own chat template
  /// (tools/tool calls included). Returns {prompt, format, has_grammar,
  /// grammar_lazy, additional_stops} or {error}. A tool-call / json_schema
  /// grammar is staged for the next generation.
  static Future<Map<String, dynamic>> chatPrepare(
          Map<String, dynamic> request) async =>
      _decode(await _channel.invokeMethod<String>(
          'chatPrepare', {'request': jsonEncode(request)}));

  /// Parses output of the last [chatPrepare] into an OpenAI message
  /// ({role, content, tool_calls?, reasoning_content?}) or {error}.
  static Future<Map<String, dynamic>> chatParse(String text,
          {bool partial = false}) async =>
      _decode(await _channel
          .invokeMethod<String>('chatParse', {'text': text, 'partial': partial}));

  /// Foreground service with a partial wake lock and a high-performance
  /// Wi-Fi lock, so the API server keeps answering with the screen off.
  static Future<void> keepAwake(bool on, {String? title, String? text}) =>
      _channel.invokeMethod('keepAwake', {'on': on, 'title': title, 'text': text});

  /// Start-on-boot flag for the app's BootReceiver (Android prefs).
  static Future<void> setStartOnBoot(bool enabled) =>
      _channel.invokeMethod('setStartOnBoot', {'enabled': enabled});

  static Map<String, dynamic> _decode(String? text) {
    if (text == null || text.isEmpty) return {};
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : {};
  }
}
