import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import 'hive_service.dart';
import 'inference_service.dart';

/// OpenAI-compatible HTTP API over the loaded local model.
///
/// Endpoints: GET /health, /metrics, /v1/models, /v1/models/{id},
/// /v1/server/capabilities; POST /v1/chat/completions, /v1/completions,
/// /v1/embeddings, /tokenize, /detokenize (also under /v1/).
///
/// Requests are queued: one runs while one more may wait; anything beyond
/// that gets 503 with Retry-After (like OlliteRT).
class OpenAiServerService {
  HttpServer? _server;
  String? _apiKey;
  void Function(String)? _onLog;

  bool get isRunning => _server != null;
  String? get localUrl {
    final port = _server?.port;
    if (port == null) return null;
    final host = _lastReachableAddress;
    return 'http://${host ?? '127.0.0.1'}:$port';
  }

  String? _lastReachableAddress;

  static const int maxBodyBytes = 18 * 1024 * 1024;
  static const int maxDecodedAttachmentBytes = 12 * 1024 * 1024;

  /// Running + waiting model requests allowed before 503.
  static const int maxInFlight = 2;

  /// How long a queued request waits for the model before giving up.
  static const Duration queueTimeout = Duration(minutes: 5);

  int _inFlight = 0;
  bool _running = false;
  final Queue<Completer<void>> _waiters = Queue();

  // /metrics counters.
  int _requests = 0;
  int _errors = 0;
  int _rejected = 0;
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _mtpDrafted = 0;
  int _mtpAccepted = 0;
  double _lastTps = 0;
  final DateTime _startedAt = DateTime.now();

  /// When [allowNetwork] is false the server only listens on loopback, so it
  /// is reachable from this device only. Network mode must be paired with an
  /// API key; the caller is responsible for supplying one.
  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    bool allowNoKey = false, // setting "No API key": network mode without auth
    void Function(String)? onLog,
  }) async {
    if (_server != null) return;
    if (allowNetwork && !allowNoKey && (apiKey == null || apiKey.trim().isEmpty)) {
      throw ArgumentError('An API key is required for network access.');
    }
    updateApiKey(apiKey);
    _onLog = onLog;
    _lastReachableAddress = allowNetwork ? await _reachableIpv4Address() : null;
    _server = await HttpServer.bind(
      allowNetwork ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
    );
    _onLog?.call('Server listening on ${localUrl ?? 'http://localhost:$port'}');
    unawaited(_serve(_server!));
  }

  /// Applies a new API key to the running server without a restart.
  void updateApiKey(String? apiKey) {
    final key = apiKey?.trim();
    _apiKey = (key == null || key.isEmpty) ? null : key;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _inFlight = 0;
    _running = false;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
    _onLog?.call('Server stopped');
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  // ── Settings (read per request, so changes apply without a restart) ──

  HiveService? get _hive =>
      Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;

  T? _setting<T>(String key) => _hive?.getSetting<T>(key);

  bool get _ignoreClientSampler =>
      _setting<bool>(AppConstants.keyIgnoreClientSampler) ?? false;
  bool get _forceStreamUsage =>
      _setting<bool>(AppConstants.keyForceStreamUsage) ?? false;
  int get _defaultSeed => _setting<int>(AppConstants.keyDefaultSeed) ?? -1;
  bool get _embeddingsEnabled =>
      _setting<bool>(AppConstants.keyServerEmbeddings) ?? false;
  List<String> get _corsOrigins =>
      (_setting<String>(AppConstants.keyCorsOrigins) ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

  // ── Routing ──

  Future<void> _handle(HttpRequest request) async {
    _requests++;
    try {
      _addCorsHeaders(request);
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _json(request, {'status': 'ok'});
        return;
      }

      final protected = path.startsWith('/v1/') ||
          path == '/metrics' ||
          path == '/tokenize' ||
          path == '/detokenize';
      if (protected && !_isAuthorized(request)) {
        await _error(request, HttpStatus.unauthorized, 'Invalid or missing API key',
            type: 'authentication_error', code: 'invalid_api_key');
        return;
      }

      // Requiring a JSON content type forces browsers to send a CORS
      // preflight, so web pages can't fire "simple" cross-origin requests.
      if (request.method == 'POST' &&
          request.headers.contentType?.mimeType != ContentType.json.mimeType) {
        await _error(request, HttpStatus.unsupportedMediaType,
            'Content-Type must be application/json');
        return;
      }

      final route = '${request.method} $path';
      switch (route) {
        case 'GET /metrics':
          await _handleMetrics(request);
          return;
        case 'GET /v1/models':
          await _handleModels(request);
          return;
        case 'GET /v1/server/capabilities':
          await _handleCapabilities(request);
          return;
        case 'POST /v1/chat/completions':
          await _handleChatCompletions(request);
          return;
        case 'POST /v1/completions':
          await _handleCompletions(request);
          return;
        case 'POST /v1/embeddings':
          await _handleEmbeddings(request);
          return;
        case 'POST /tokenize':
        case 'POST /v1/tokenize':
          await _handleTokenize(request);
          return;
        case 'POST /detokenize':
        case 'POST /v1/detokenize':
          await _handleDetokenize(request);
          return;
      }
      if (request.method == 'GET' && path.startsWith('/v1/models/')) {
        await _handleModel(request, Uri.decodeComponent(path.substring(11)));
        return;
      }

      await _error(request, HttpStatus.notFound, 'Unknown endpoint: $route',
          type: 'not_found_error', code: 'not_found');
    } on FormatException catch (error) {
      await _safeError(request, HttpStatus.badRequest, 'Invalid JSON: ${error.message}');
    } on HttpException catch (error) {
      await _safeError(request, HttpStatus.requestEntityTooLarge, error.message);
    } catch (error) {
      _onLog?.call('Request failed: $error');
      await _safeError(request, HttpStatus.internalServerError,
          'Internal server error: $error', type: 'server_error');
    }
  }

  Future<void> _safeError(HttpRequest request, int status, String message,
      {String type = 'invalid_request_error'}) async {
    try {
      await _error(request, status, message, type: type);
    } catch (_) {
      // The response may already be closed or detached (streaming).
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final key = _apiKey;
    if (key == null || key.isEmpty) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (_constantTimeEquals(header.trim(), 'Bearer $key')) return true;
    final xKey = request.headers.value('x-api-key') ?? '';
    return xKey.isNotEmpty && _constantTimeEquals(xKey.trim(), key);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  // ── Queue ──

  /// Claims the model for one request, waiting in line behind at most
  /// [maxInFlight] - 1 others (and behind an in-app reply). Returns false
  /// after sending the error response.
  Future<bool> _acquire(HttpRequest request, InferenceService inference) async {
    if (_inFlight >= maxInFlight) {
      _rejected++;
      request.response.headers.set(HttpHeaders.retryAfterHeader, '5');
      await _error(request, HttpStatus.serviceUnavailable,
          'Server is busy; retry shortly',
          type: 'server_error', code: 'server_busy');
      return false;
    }
    _inFlight++;
    Completer<void>? waiter;
    try {
      if (_running) {
        waiter = Completer<void>();
        _waiters.add(waiter);
        await waiter.future.timeout(queueTimeout);
      }
      _running = true;
      // An in-app reply is running: wait for it instead of cutting it off.
      final deadline = DateTime.now().add(queueTimeout);
      while (inference.isGenerating.value && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
      if (inference.isGenerating.value) {
        _release();
        request.response.headers.set(HttpHeaders.retryAfterHeader, '10');
        await _error(request, HttpStatus.serviceUnavailable,
            'Model is busy with an in-app reply',
            type: 'server_error', code: 'model_busy');
        return false;
      }
      // Keep-alive: reload a model that was unloaded for being idle.
      if (!inference.isModelLoaded.value && inference.isIdleUnloaded) {
        _onLog?.call('Reloading idle-unloaded model');
        await inference.reloadIfIdle();
      }
      final modelError = _localModelError(inference);
      if (modelError != null) {
        _release();
        await _error(request, HttpStatus.serviceUnavailable, modelError,
            type: 'server_error', code: 'model_not_loaded');
        return false;
      }
      return true;
    } on TimeoutException {
      _waiters.remove(waiter);
      _inFlight--;
      request.response.headers.set(HttpHeaders.retryAfterHeader, '10');
      await _error(request, HttpStatus.serviceUnavailable,
          'Timed out waiting for the model',
          type: 'server_error', code: 'queue_timeout');
      return false;
    }
  }

  void _release() {
    if (_inFlight > 0) _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(); // hand the model to the next one
    } else {
      _running = false;
    }
  }

  String? _localModelError(InferenceService inference) {
    if (!inference.isModelLoaded.value) {
      return 'No local model loaded. Load a GGUF or LiteRT-LM model first.';
    }
    return null;
  }

  // ── Info endpoints ──

  Map<String, dynamic> _modelObject(InferenceService inference) => {
        'id': inference.loadedModelName.value,
        'object': 'model',
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'owned_by': 'local',
      };

  Future<void> _handleModels(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = inference.isModelLoaded.value;
    await _json(request, {
      'object': 'list',
      'data': [if (hasModel) _modelObject(inference)],
    });
  }

  Future<void> _handleModel(HttpRequest request, String id) async {
    final inference = Get.find<InferenceService>();
    final name = inference.loadedModelName.value;
    final file = inference.loadedModelPath.value.split('/').last;
    if (inference.isModelLoaded.value && (id == name || id == file)) {
      await _json(request, _modelObject(inference));
      return;
    }
    await _error(request, HttpStatus.notFound, "The model '$id' does not exist",
        type: 'invalid_request_error', code: 'model_not_found', param: 'model');
  }

  Future<void> _handleCapabilities(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final hasModel = inference.isModelLoaded.value;
    final isLiteRt = hasModel && inference.loadedModelRuntime.value == 'litert';
    await _json(request, {
      'server': 'AI Chat Local OpenAI API',
      'running': true,
      'model': hasModel ? inference.loadedModelName.value : null,
      'runtime': inference.loadedModelRuntime.value,
      'requires_litert': false,
      'capabilities': {
        'text': hasModel,
        'image': hasModel &&
            (isLiteRt ? inference.isVisionLoaded.value : inference.ggufVisionLoaded),
        'audio': isLiteRt,
        'streaming': hasModel,
        'gguf': hasModel && !isLiteRt,
        'tools': hasModel && !isLiteRt,
        'json_schema': hasModel && !isLiteRt,
        'embeddings': hasModel && !isLiteRt && _embeddingsEnabled,
        'mtp': inference.mtpStatus,
      },
    });
  }

  Future<void> _handleMetrics(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final mtp = await inference.mtpInfo();
    final lines = <String>[
      '# TYPE privatelm_requests_total counter',
      'privatelm_requests_total $_requests',
      '# TYPE privatelm_request_errors_total counter',
      'privatelm_request_errors_total $_errors',
      '# TYPE privatelm_requests_rejected_total counter',
      'privatelm_requests_rejected_total $_rejected',
      '# TYPE privatelm_requests_in_flight gauge',
      'privatelm_requests_in_flight $_inFlight',
      '# TYPE privatelm_prompt_tokens_total counter',
      'privatelm_prompt_tokens_total $_promptTokens',
      '# TYPE privatelm_completion_tokens_total counter',
      'privatelm_completion_tokens_total $_completionTokens',
      '# TYPE privatelm_last_tokens_per_second gauge',
      'privatelm_last_tokens_per_second ${_lastTps.toStringAsFixed(3)}',
      '# TYPE privatelm_model_loaded gauge',
      'privatelm_model_loaded ${inference.isModelLoaded.value ? 1 : 0}',
      '# TYPE privatelm_context_tokens gauge',
      'privatelm_context_tokens{kind="used"} ${inference.contextTokensUsed.value}',
      'privatelm_context_tokens{kind="total"} ${inference.contextTokensTotal.value}',
      '# TYPE privatelm_mtp_draft_tokens_total counter',
      'privatelm_mtp_draft_tokens_total{kind="drafted"} $_mtpDrafted',
      'privatelm_mtp_draft_tokens_total{kind="accepted"} $_mtpAccepted',
      if (mtp.isNotEmpty) ...[
        '# TYPE privatelm_mtp_loaded gauge',
        'privatelm_mtp_loaded ${mtp['loaded'] == true ? 1 : 0}',
      ],
      '# TYPE privatelm_uptime_seconds gauge',
      'privatelm_uptime_seconds ${DateTime.now().difference(_startedAt).inSeconds}',
    ];
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('text', 'plain', charset: 'utf-8');
    request.response.write('${lines.join('\n')}\n');
    await request.response.close();
  }

  // ── Request parameters ──

  /// OpenAI `stop`: a string or a list of up to 4 strings.
  List<String> _stop(Map<String, dynamic> body) {
    final raw = body['stop'];
    if (raw is String) return raw.isEmpty ? const [] : [raw];
    if (raw is List) {
      return raw.whereType<String>().where((s) => s.isNotEmpty).take(4).toList();
    }
    return const [];
  }

  int? _maxTokens(Map<String, dynamic> body) {
    final raw = body['max_completion_tokens'] ?? body['max_tokens'] ?? body['n_predict'];
    return raw is num && raw > 0 ? raw.toInt() : null;
  }

  double? _num(Map<String, dynamic> body, String key, double lo, double hi) {
    final v = body[key];
    if (v is! num || v.isNaN) return null;
    return v.toDouble().clamp(lo, hi).toDouble();
  }

  /// Sampler parameters from the request, clamped to sane ranges. The app's
  /// settings stay the defaults. Ignored entirely when the
  /// ignore_client_sampler_params setting is on (default_seed still applies).
  GenerationOptions _options(Map<String, dynamic> body,
      {bool rawPrompt = false, String? grammar, bool grammarStaged = false}) {
    final ignore = _ignoreClientSampler;
    int? seed;
    if (!ignore && body['seed'] is num) seed = (body['seed'] as num).toInt();
    if (seed == null && _defaultSeed >= 0) seed = _defaultSeed;
    if (seed != null && seed < 0) seed = null;
    final topK = !ignore && body['top_k'] is num
        ? (body['top_k'] as num).toInt().clamp(0, 1000)
        : null;
    return GenerationOptions(
      temperature: ignore ? null : _num(body, 'temperature', 0, 2),
      topP: ignore ? null : _num(body, 'top_p', 0, 1),
      topK: topK,
      minP: ignore ? null : _num(body, 'min_p', 0, 1),
      seed: seed,
      repeatPenalty: ignore
          ? null
          : (_num(body, 'repeat_penalty', 0.5, 2) ??
              _num(body, 'repetition_penalty', 0.5, 2)),
      frequencyPenalty: ignore ? null : _num(body, 'frequency_penalty', -2, 2),
      presencePenalty: ignore ? null : _num(body, 'presence_penalty', -2, 2),
      rawPrompt: rawPrompt,
      grammar: grammar,
      grammarStaged: grammarStaged,
    );
  }

  bool _includeUsage(Map<String, dynamic> body) {
    final so = body['stream_options'];
    return _forceStreamUsage || (so is Map && so['include_usage'] == true);
  }

  /// response_format -> JSON schema (text), or null for plain text.
  /// Throws [_ApiError] for an unsupported type.
  String? _responseSchema(Map<String, dynamic> body) {
    final rf = body['response_format'];
    if (rf is! Map) return null;
    final type = '${rf['type'] ?? 'text'}';
    if (type == 'text') return null;
    if (type == 'json_object') return jsonEncode({'type': 'object'});
    if (type == 'json_schema') {
      final js = rf['json_schema'];
      final schema = js is Map ? (js['schema'] ?? js) : null;
      if (schema is! Map) {
        throw _ApiError(400, 'response_format.json_schema.schema must be an object',
            param: 'response_format');
      }
      return jsonEncode(schema);
    }
    throw _ApiError(400, 'Unsupported response_format type: $type',
        param: 'response_format');
  }

  Future<Map<String, dynamic>> _usage(
      InferenceService inference, String prompt, String text) async {
    final s = inference.lastStats;
    var promptTokens = s?.promptTokens ?? 0;
    var completion = s?.completionTokens ?? 0;
    if (s == null || s.estimated) {
      // GGUF stopped by a stop sequence: ask the engine for the exact
      // prompt count and count the reply with the tokenizer.
      promptTokens = await inference.nativePromptTokens() ?? (prompt.length / 4).ceil();
      final toks = await inference.tokenize(text, addSpecial: false);
      completion = toks?.length ?? completion;
    }
    _promptTokens += promptTokens;
    _completionTokens += completion;
    _mtpDrafted += s?.mtpDrafted ?? 0;
    _mtpAccepted += s?.mtpAccepted ?? 0;
    if (s != null && s.genMs > 0) _lastTps = completion * 1000 / s.genMs;
    return {
      'prompt_tokens': promptTokens,
      'completion_tokens': completion,
      'total_tokens': promptTokens + completion,
      if (s != null && s.cachedTokens > 0)
        'prompt_tokens_details': {'cached_tokens': s.cachedTokens},
    };
  }

  String _finishReason(InferenceService inference) =>
      inference.lastStats?.finish == 'length' ? 'length' : 'stop';

  // ── Chat completions ──

  Future<void> _handleChatCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final body = await _readJson(request);
    final tempFiles = <File>[];
    if (!await _acquire(request, inference)) return;
    try {
      // One model is loaded at a time, and clients (PC chat apps, editors)
      // often send their own model name: serve the loaded model regardless,
      // as llama-server and LM Studio do.
      final model = (body['model'] as String?)?.trim();
      if (model != null &&
          model.isNotEmpty &&
          model != inference.loadedModelName.value) {
        _onLog?.call('Request for "$model"; serving ${inference.loadedModelName.value}');
      }

      final parsed = await _parseChatRequest(body, tempFiles);
      if (parsed.error != null) {
        await _error(request, HttpStatus.badRequest, parsed.error!, param: 'messages');
        return;
      }
      final isGguf = inference.loadedModelRuntime.value != 'litert';
      if (parsed.imagePath != null) {
        final canSee = isGguf ? inference.ggufVisionLoaded : inference.isVisionLoaded.value;
        if (!canSee) {
          await _error(request, HttpStatus.badRequest,
              'The loaded model has no vision projector, so it cannot read images',
              code: 'vision_unsupported');
          return;
        }
      }

      final schema = _responseSchema(body);
      final tools = body['tools'] is List && (body['tools'] as List).isNotEmpty
          ? body['tools'] as List
          : null;
      final toolChoice = body['tool_choice'];
      final useTools = tools != null && toolChoice != 'none';
      final maxTokens = _maxTokens(body);
      final stop = _stop(body);
      final stream = body['stream'] == true;
      final systemPrompt = parsed.systemPrompt ??
          _defaultSystemPrompt(inference.loadedModelName.value);

      // GGUF + tools (or a history with tool calls): render with the
      // model's own Jinja template and parse tool calls from the output.
      if (isGguf && parsed.imagePath == null && (useTools || parsed.hasToolTurns)) {
        final prep = await inference.chatPrepare({
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            ...parsed.oaiMessages,
          ],
          if (useTools) 'tools': tools,
          if (useTools)
            'tool_choice': toolChoice is String ? toolChoice : (toolChoice is Map ? 'required' : 'auto'),
          'parallel_tool_calls': body['parallel_tool_calls'] == true,
          if (schema != null) 'json_schema': schema,
          'enable_thinking': false,
        });
        if (prep != null && prep['error'] == null && prep['prompt'] is String) {
          await _jinjaChat(request, inference, body, prep, maxTokens, stop, stream,
              useTools: useTools);
          return;
        }
        _onLog?.call('Chat template with tools failed (${prep?['error']}); '
            'falling back to plain chat');
      }

      String? grammar;
      if (schema != null && isGguf) {
        try {
          grammar = await inference.jsonSchemaToGrammar(schema);
        } catch (e) {
          await _error(request, HttpStatus.badRequest, '$e', param: 'response_format');
          return;
        }
      }
      final options = _options(body, grammar: grammar);

      if (stream) {
        await _streamChat(request, inference, parsed, systemPrompt, maxTokens,
            stop, options, _includeUsage(body));
        return;
      }
      final stopsBefore = inference.stopCount;
      final text = await inference.generate(
        prompt: parsed.prompt,
        systemPrompt: systemPrompt,
        conversationHistory: parsed.history,
        source: 'server',
        imagePath: parsed.imagePath,
        audioPath: parsed.audioPath,
        maxTokens: maxTokens,
        stopSequences: stop,
        options: options,
      );
      if (inference.stopCount != stopsBefore) {
        await _interrupted(request);
        return;
      }
      if (text.startsWith('ERROR:')) {
        await _engineError(request, text);
        return;
      }
      await _json(request, {
        ..._chatEnvelope(inference, 'chat.completion'),
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': text},
            'logprobs': null,
            'finish_reason': _finishReason(inference),
          }
        ],
        'usage': await _usage(inference, parsed.prompt, text),
      });
    } on _ApiError catch (e) {
      await _error(request, e.status, e.message, param: e.param);
    } finally {
      _release();
      await _deleteFiles(tempFiles);
    }
  }

  /// Tool-capable chat via the model's Jinja template. Streaming sends the
  /// whole reply at the end (tool calls can only be parsed once complete).
  Future<void> _jinjaChat(
    HttpRequest request,
    InferenceService inference,
    Map<String, dynamic> body,
    Map<String, dynamic> prep,
    int? maxTokens,
    List<String> stop,
    bool stream, {
    required bool useTools,
  }) async {
    final prompt = prep['prompt'] as String;
    final extraStops = (prep['additional_stops'] as List?)?.whereType<String>() ?? const [];
    final stops = {...stop, ...extraStops}.where((s) => s.isNotEmpty).toList();
    final options = _options(body,
        rawPrompt: true, grammarStaged: prep['has_grammar'] == true);
    final stopsBefore = inference.stopCount;
    final text = await inference.generate(
      prompt: prompt,
      source: 'server',
      maxTokens: maxTokens,
      stopSequences: stops,
      options: options,
    );
    if (inference.stopCount != stopsBefore) {
      await _interrupted(request);
      return;
    }
    if (text.startsWith('ERROR:')) {
      await _engineError(request, text);
      return;
    }
    final parsedMsg = await inference.chatParse(text) ?? const {};
    final toolCalls = <Map<String, dynamic>>[];
    if (parsedMsg['error'] == null && parsedMsg['tool_calls'] is List) {
      var i = 0;
      for (final tc in parsedMsg['tool_calls'] as List) {
        if (tc is! Map) continue;
        final fn = tc['function'] is Map ? tc['function'] as Map : tc;
        final id = '${tc['id'] ?? ''}';
        toolCalls.add({
          'id': id.isEmpty ? 'call_${_id()}' : id,
          'type': 'function',
          'function': {
            'name': '${fn['name'] ?? ''}',
            'arguments': fn['arguments'] is String
                ? fn['arguments']
                : jsonEncode(fn['arguments'] ?? {}),
          },
          'index': i++,
        });
      }
    }
    final content = parsedMsg['error'] == null
        ? (parsedMsg['content'] is String ? parsedMsg['content'] as String : '')
        : text;
    final finish = toolCalls.isNotEmpty ? 'tool_calls' : _finishReason(inference);
    final usage = await _usage(inference, prompt, text);
    final reasoning = parsedMsg['reasoning_content'];

    if (!stream) {
      await _json(request, {
        ..._chatEnvelope(inference, 'chat.completion'),
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': toolCalls.isNotEmpty && content.trim().isEmpty ? null : content,
              if (reasoning is String && reasoning.isNotEmpty) 'reasoning_content': reasoning,
              if (toolCalls.isNotEmpty)
                'tool_calls': [
                  for (final tc in toolCalls) Map.of(tc)..remove('index')
                ],
            },
            'logprobs': null,
            'finish_reason': finish,
          }
        ],
        'usage': usage,
      });
      return;
    }
    final env = _chatEnvelope(inference, 'chat.completion.chunk');
    final sse = await _SseStream.open(request.response, onDisconnect: () {});
    Map<String, dynamic> chunk(Map<String, dynamic> delta, String? fin) => {
          ...env,
          'choices': [
            {'index': 0, 'delta': delta, 'logprobs': null, 'finish_reason': fin}
          ],
        };
    sse.event(chunk({'role': 'assistant', 'content': ''}, null));
    if (content.isNotEmpty) sse.event(chunk({'content': content}, null));
    if (toolCalls.isNotEmpty) sse.event(chunk({'tool_calls': toolCalls}, null));
    sse.event(chunk({}, finish));
    if (_includeUsage(body)) sse.event({...env, 'choices': [], 'usage': usage});
    sse.raw('data: [DONE]\n\n');
    await sse.close();
  }

  Map<String, dynamic> _chatEnvelope(InferenceService inference, String object) => {
        'id': 'chatcmpl-${_id()}',
        'object': object,
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'model': inference.loadedModelName.value,
        'system_fingerprint': 'privatelm',
      };

  Future<void> _streamChat(
    HttpRequest request,
    InferenceService inference,
    _ParsedChatRequest parsed,
    String systemPrompt,
    int? maxTokens,
    List<String> stop,
    GenerationOptions options,
    bool includeUsage,
  ) async {
    final env = _chatEnvelope(inference, 'chat.completion.chunk');
    var emitted = false;
    final sse = await _SseStream.open(request.response, onDisconnect: () {
      if (inference.generationSource.value == 'server') {
        unawaited(inference.stopGeneration());
      }
    });
    Map<String, dynamic> chunk(Map<String, dynamic> delta, String? fin) => {
          ...env,
          'choices': [
            {'index': 0, 'delta': delta, 'logprobs': null, 'finish_reason': fin}
          ],
        };
    sse.event(chunk({'role': 'assistant', 'content': ''}, null));

    void emit(String token) {
      emitted = true;
      sse.event(chunk({'content': token}, null));
    }

    final stopsBefore = inference.stopCount;
    final result = await inference.generate(
      prompt: parsed.prompt,
      systemPrompt: systemPrompt,
      conversationHistory: parsed.history,
      source: 'server',
      imagePath: parsed.imagePath,
      audioPath: parsed.audioPath,
      maxTokens: maxTokens,
      stopSequences: stop,
      options: options,
      onToken: emit,
    );
    await _finishStream(sse, inference, stopsBefore, emitted ? null : result,
        emit: emit,
        finalChunk: () => chunk({}, _finishReason(inference)),
        usageChunk: includeUsage
            ? () async => {...env, 'choices': [], 'usage': await _usage(inference, parsed.prompt, result)}
            : null);
  }

  /// Ends an SSE stream: reports an interruption or engine error as an
  /// error event rather than a normal [DONE], so clients don't mistake a
  /// partial answer for a complete one.
  Future<void> _finishStream(
    _SseStream sse,
    InferenceService inference,
    int stopsBefore,
    String? unemittedResult, {
    required void Function(String) emit,
    required Map<String, dynamic> Function() finalChunk,
    Future<Map<String, dynamic>> Function()? usageChunk,
  }) async {
    if (inference.stopCount != stopsBefore) {
      _errors++;
      sse.event({
        'error': {
          'message': 'Generation was interrupted',
          'type': 'server_error',
          'code': 'interrupted',
        }
      });
    } else if (unemittedResult != null && unemittedResult.startsWith('ERROR:')) {
      _errors++;
      sse.event({
        'error': {
          'message': unemittedResult.substring(6).trim(),
          'type': 'server_error',
          'code': 'engine_error',
        }
      });
    } else {
      if (unemittedResult != null && unemittedResult.isNotEmpty) {
        emit(unemittedResult);
      }
      sse.event(finalChunk());
      if (usageChunk != null) sse.event(await usageChunk());
      sse.raw('data: [DONE]\n\n');
    }
    await sse.close();
  }

  // ── Text completions ──

  Future<void> _handleCompletions(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final body = await _readJson(request);
    var prompt = body['prompt'];
    if (prompt is List && prompt.isNotEmpty && prompt.first is String) {
      prompt = prompt.first;
    }
    if (prompt is! String || prompt.isEmpty) {
      await _error(request, HttpStatus.badRequest, 'prompt is required', param: 'prompt');
      return;
    }
    if (!await _acquire(request, inference)) return;
    try {
      final isGguf = inference.loadedModelRuntime.value != 'litert';
      final schema = _responseSchema(body);
      String? grammar;
      if (schema != null && isGguf) grammar = await inference.jsonSchemaToGrammar(schema);
      if (body['grammar'] is String && isGguf) grammar = body['grammar'] as String;
      // GGUF: the prompt goes to the model as-is (no chat template).
      final options = _options(body, rawPrompt: isGguf, grammar: grammar);
      final maxTokens = _maxTokens(body);
      final stop = _stop(body);
      final env = {
        'id': 'cmpl-${_id()}',
        'object': 'text_completion',
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'model': inference.loadedModelName.value,
      };
      if (body['stream'] == true) {
        var emitted = false;
        final sse = await _SseStream.open(request.response, onDisconnect: () {
          if (inference.generationSource.value == 'server') {
            unawaited(inference.stopGeneration());
          }
        });
        void emit(String token) {
          emitted = true;
          sse.event({
            ...env,
            'choices': [
              {'index': 0, 'text': token, 'logprobs': null, 'finish_reason': null}
            ],
          });
        }

        final stopsBefore = inference.stopCount;
        final result = await inference.generate(
          prompt: prompt,
          systemPrompt: _defaultSystemPrompt(inference.loadedModelName.value),
          source: 'server',
          maxTokens: maxTokens,
          stopSequences: stop,
          options: options,
          onToken: emit,
        );
        await _finishStream(sse, inference, stopsBefore, emitted ? null : result,
            emit: emit,
            finalChunk: () => {
                  ...env,
                  'choices': [
                    {
                      'index': 0,
                      'text': '',
                      'logprobs': null,
                      'finish_reason': _finishReason(inference)
                    }
                  ],
                },
            usageChunk: _includeUsage(body)
                ? () async => {...env, 'choices': [], 'usage': await _usage(inference, prompt as String, result)}
                : null);
        return;
      }
      final stopsBefore = inference.stopCount;
      final text = await inference.generate(
        prompt: prompt,
        systemPrompt: _defaultSystemPrompt(inference.loadedModelName.value),
        source: 'server',
        maxTokens: maxTokens,
        stopSequences: stop,
        options: options,
      );
      if (inference.stopCount != stopsBefore) {
        await _interrupted(request);
        return;
      }
      if (text.startsWith('ERROR:')) {
        await _engineError(request, text);
        return;
      }
      await _json(request, {
        ...env,
        'choices': [
          {
            'index': 0,
            'text': body['echo'] == true ? '$prompt$text' : text,
            'logprobs': null,
            'finish_reason': _finishReason(inference),
          }
        ],
        'usage': await _usage(inference, prompt, text),
      });
    } on _ApiError catch (e) {
      await _error(request, e.status, e.message, param: e.param);
    } finally {
      _release();
    }
  }

  // ── Embeddings / tokenizer ──

  Future<void> _handleEmbeddings(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final body = await _readJson(request);
    if (!_embeddingsEnabled) {
      await _error(request, HttpStatus.notFound,
          'Embeddings are turned off. Enable "Embeddings endpoint" in the app settings.',
          code: 'embeddings_disabled');
      return;
    }
    final raw = body['input'];
    final inputs = <Object>[];
    if (raw is String) {
      inputs.add(raw);
    } else if (raw is List && raw.isNotEmpty) {
      if (raw.every((e) => e is num)) {
        inputs.add(raw.cast<num>().map((e) => e.toInt()).toList());
      } else {
        for (final e in raw) {
          if (e is String) {
            inputs.add(e);
          } else if (e is List && e.every((t) => t is num)) {
            inputs.add(e.cast<num>().map((t) => t.toInt()).toList());
          } else {
            await _error(request, HttpStatus.badRequest,
                'input must be a string, an array of strings, or token arrays',
                param: 'input');
            return;
          }
        }
      }
    }
    if (inputs.isEmpty) {
      await _error(request, HttpStatus.badRequest, 'input is required', param: 'input');
      return;
    }
    if (!await _acquire(request, inference)) return;
    try {
      if (inference.loadedModelRuntime.value == 'litert') {
        await _error(request, HttpStatus.badRequest,
            'Embeddings need a GGUF model (LiteRT has no embeddings API)');
        return;
      }
      final base64Out = body['encoding_format'] == 'base64';
      final data = <Map<String, dynamic>>[];
      var tokens = 0;
      for (var i = 0; i < inputs.length; i++) {
        final input = inputs[i];
        final text = input is String
            ? input
            : await inference.detokenize(input as List<int>) ?? '';
        final vec = await inference.embed(text) ?? const <double>[];
        tokens += (await inference.tokenize(text))?.length ?? 0;
        Object embedding = vec;
        if (base64Out) {
          final bytes = Float32List.fromList(vec).buffer.asUint8List();
          embedding = base64Encode(bytes);
        }
        data.add({'object': 'embedding', 'index': i, 'embedding': embedding});
      }
      await _json(request, {
        'object': 'list',
        'data': data,
        'model': inference.loadedModelName.value,
        'usage': {'prompt_tokens': tokens, 'total_tokens': tokens},
      });
    } catch (e) {
      await _error(request, HttpStatus.internalServerError, 'Embedding failed: $e',
          type: 'server_error');
    } finally {
      _release();
    }
  }

  Future<void> _handleTokenize(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final body = await _readJson(request);
    final content = body['content'] ?? body['prompt'] ?? body['text'];
    if (content is! String) {
      await _error(request, HttpStatus.badRequest, 'content is required', param: 'content');
      return;
    }
    final tokens = await inference.tokenize(content,
        addSpecial: body['add_special'] == true, parseSpecial: body['parse_special'] != false);
    if (tokens == null) {
      await _error(request, HttpStatus.serviceUnavailable, 'No GGUF model loaded',
          type: 'server_error', code: 'model_not_loaded');
      return;
    }
    if (body['with_pieces'] == true) {
      final pieces = <Map<String, dynamic>>[];
      for (final t in tokens) {
        pieces.add({'id': t, 'piece': await inference.detokenize([t]) ?? ''});
      }
      await _json(request, {'tokens': pieces});
      return;
    }
    await _json(request, {'tokens': tokens});
  }

  Future<void> _handleDetokenize(HttpRequest request) async {
    final inference = Get.find<InferenceService>();
    final body = await _readJson(request);
    final raw = body['tokens'];
    if (raw is! List || !raw.every((t) => t is num)) {
      await _error(request, HttpStatus.badRequest, 'tokens must be an array of integers',
          param: 'tokens');
      return;
    }
    try {
      final text = await inference.detokenize(raw.cast<num>().map((t) => t.toInt()).toList());
      if (text == null) {
        await _error(request, HttpStatus.serviceUnavailable, 'No GGUF model loaded',
            type: 'server_error', code: 'model_not_loaded');
        return;
      }
      await _json(request, {'content': text});
    } catch (e) {
      await _error(request, HttpStatus.badRequest, '$e', param: 'tokens');
    }
  }

  // ── Errors ──

  Future<void> _interrupted(HttpRequest request) => _error(
        request,
        HttpStatus.serviceUnavailable,
        'Generation was interrupted (the app started its own response)',
        type: 'server_error',
        code: 'interrupted',
      );

  Future<void> _engineError(HttpRequest request, String text) {
    final message = text.substring(6).trim();
    final lower = message.toLowerCase();
    final status = lower.contains('no model loaded')
        ? HttpStatus.serviceUnavailable
        : HttpStatus.internalServerError;
    return _error(request, status, message, type: 'server_error', code: 'engine_error');
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String message, {
    String? type,
    String? code,
    String? param,
  }) {
    if (status >= 500) _errors++;
    return _json(
      request,
      {
        'error': {
          'message': message,
          'type': type ??
              (status == 401
                  ? 'authentication_error'
                  : status == 404
                      ? 'not_found_error'
                      : status >= 500
                          ? 'server_error'
                          : 'invalid_request_error'),
          'param': param,
          'code': code,
        }
      },
      status: status,
    );
  }

  Future<void> _deleteFiles(List<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  // ── Message parsing ──

  /// Temp files are appended to [tempFiles] as they're written so the caller
  /// can always delete them, including when parsing fails part-way.
  Future<_ParsedChatRequest> _parseChatRequest(
      Map<String, dynamic> body, List<File> tempFiles) async {
    final rawMessages = body['messages'];
    if (rawMessages is! List || rawMessages.isEmpty) {
      return _ParsedChatRequest.error('messages must be a non-empty array');
    }

    final systemParts = <String>[];
    final history = <Map<String, String>>[];
    final oai = <Map<String, dynamic>>[];
    var lastUserText = '';
    var hasToolTurns = false;
    String? imagePath;
    String? audioPath;

    for (var i = 0; i < rawMessages.length; i++) {
      final raw = rawMessages[i];
      if (raw is! Map) {
        return _ParsedChatRequest.error('message[$i] must be an object');
      }
      var role = '${raw['role'] ?? ''}';
      if (role == 'developer') role = 'system';
      if (role == 'function') role = 'tool';
      if (!const {'system', 'user', 'assistant', 'tool'}.contains(role)) {
        return _ParsedChatRequest.error('message[$i].role "$role" is unsupported');
      }
      final contentResult = raw['content'] == null
          ? _ContentResult(text: '')
          : await _parseContent(raw['content'], tempFiles);
      if (contentResult.error != null) {
        return _ParsedChatRequest.error(contentResult.error!);
      }
      imagePath ??= contentResult.imagePath;
      audioPath ??= contentResult.audioPath;
      final text = contentResult.text;

      // Native (Jinja) form, text only.
      final msg = <String, dynamic>{'role': role, 'content': text};
      if (role == 'assistant' && raw['tool_calls'] is List) {
        msg['tool_calls'] = raw['tool_calls'];
        hasToolTurns = true;
      }
      if (role == 'tool') {
        hasToolTurns = true;
        if (raw['tool_call_id'] != null) msg['tool_call_id'] = '${raw['tool_call_id']}';
        if (raw['name'] != null) msg['name'] = '${raw['name']}';
      }
      if (role != 'system') oai.add(msg);

      if (role == 'system') {
        if (text.trim().isNotEmpty) systemParts.add(text.trim());
        continue;
      }
      // Plain form for the app's own templates: tool turns become text.
      if (role == 'tool') {
        final who = raw['name'] ?? raw['tool_call_id'] ?? 'tool';
        history.add({'role': 'user', 'content': 'Tool result ($who):\n$text'});
        continue;
      }
      var plain = text;
      if (role == 'assistant' && raw['tool_calls'] is List) {
        final calls = (raw['tool_calls'] as List).whereType<Map>().map((c) {
          final fn = c['function'] is Map ? c['function'] as Map : c;
          return '${fn['name']}(${fn['arguments'] ?? ''})';
        }).join(', ');
        plain = '${plain.isEmpty ? '' : '$plain\n'}[Called tools: $calls]';
      }
      if (i == rawMessages.length - 1 && role == 'user') {
        lastUserText = plain.trim();
      } else {
        history.add({'role': role, 'content': plain});
      }
    }

    if (lastUserText.isEmpty && imagePath == null && audioPath == null) {
      if (hasToolTurns && history.isNotEmpty) {
        // Last turn is a tool result: continue from it.
        final last = history.removeLast();
        lastUserText = last['content'] ?? '';
      } else {
        return _ParsedChatRequest.error(
            'last user message must contain text, image, or audio');
      }
    }

    return _ParsedChatRequest(
      prompt: lastUserText.isEmpty ? 'Describe this attachment.' : lastUserText,
      systemPrompt: systemParts.isEmpty ? null : systemParts.join('\n'),
      history: history,
      imagePath: imagePath,
      audioPath: audioPath,
      oaiMessages: oai,
      hasToolTurns: hasToolTurns,
    );
  }

  Future<_ContentResult> _parseContent(
      dynamic content, List<File> tempFiles) async {
    if (content is String) return _ContentResult(text: content);
    if (content is! List) {
      return _ContentResult.error(
          'message.content must be a string or content array');
    }

    final text = StringBuffer();
    String? imagePath;
    String? audioPath;

    for (final part in content) {
      if (part is! Map) {
        return _ContentResult.error('content part must be an object');
      }
      final type = '${part['type'] ?? ''}';
      if (type == 'text' || type == 'input_text') {
        text.write('${part['text'] ?? ''}');
      } else if (type == 'image_url') {
        if (imagePath != null) {
          return _ContentResult.error(
              'only one image is supported per request');
        }
        final imageUrl = part['image_url'];
        final url = imageUrl is Map ? '${imageUrl['url'] ?? ''}' : '$imageUrl';
        final file = await _dataUrlToTempFile(url, 'image');
        if (file.error != null) return _ContentResult.error(file.error!);
        imagePath = file.path;
        tempFiles.add(file.file!);
      } else if (type == 'input_audio' || type == 'audio_url') {
        if (audioPath != null) {
          return _ContentResult.error(
              'only one audio file is supported per request');
        }
        final raw = part[type == 'input_audio' ? 'input_audio' : 'audio_url'];
        final data = raw is Map ? '${raw['data'] ?? raw['url'] ?? ''}' : '';
        final file = await _dataUrlToTempFile(data, 'audio');
        if (file.error != null) return _ContentResult.error(file.error!);
        audioPath = file.path;
        tempFiles.add(file.file!);
      } else {
        return _ContentResult.error('unsupported content part type: $type');
      }
    }

    return _ContentResult(
      text: text.toString(),
      imagePath: imagePath,
      audioPath: audioPath,
    );
  }

  Future<_TempFileResult> _dataUrlToTempFile(String value, String kind) async {
    if (!value.startsWith('data:')) {
      return _TempFileResult.error(
          'Only base64 data URLs are accepted for $kind input');
    }
    final comma = value.indexOf(',');
    if (comma <= 0 || !value.substring(0, comma).contains(';base64')) {
      return _TempFileResult.error('$kind input must be a base64 data URL');
    }
    final meta = value.substring(5, comma).toLowerCase();
    final encoded = value.substring(comma + 1);
    if (encoded.length > maxDecodedAttachmentBytes * 2) {
      return _TempFileResult.error('$kind input is too large');
    }
    late List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return _TempFileResult.error('$kind input has invalid base64');
    }
    if (bytes.length > maxDecodedAttachmentBytes) {
      return _TempFileResult.error('$kind input is too large');
    }
    final ext = _extensionForMime(meta, kind);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/server_${kind}_${_id()}.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return _TempFileResult(file);
  }

  String _extensionForMime(String mime, String kind) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    if (mime.contains('jpg') || mime.contains('jpeg')) return 'jpg';
    if (mime.contains('wav')) return 'wav';
    if (mime.contains('mp3') || mime.contains('mpeg')) return 'mp3';
    if (mime.contains('m4a') || mime.contains('mp4')) return 'm4a';
    return kind == 'image' ? 'png' : 'wav';
  }

  // ── HTTP helpers ──

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBodyBytes) {
        throw const HttpException('Request body is too large');
      }
    }
    final body = utf8.decode(builder.takeBytes());
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object');
    }
    return decoded;
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, dynamic> data, {
    int status = HttpStatus.ok,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  void _addCorsHeaders(HttpRequest request) {
    final response = request.response;
    final origins = _corsOrigins;
    String? allow;
    if (origins.isNotEmpty) {
      // Explicit allow-list (setting): echo a listed origin, or "*".
      final origin = request.headers.value('origin');
      if (origins.contains('*')) {
        allow = '*';
      } else if (origin != null && origins.contains(origin)) {
        allow = origin;
        response.headers.set(HttpHeaders.varyHeader, 'Origin');
      }
    } else if (_apiKey != null) {
      // Default: only allow browser access when a key is required, so an
      // arbitrary web page can't read model output from an open server.
      allow = '*';
    }
    if (allow == null) return;
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, allow);
    response.headers
        .set(HttpHeaders.accessControlAllowMethodsHeader, 'GET,POST,OPTIONS');
    response.headers.set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Content-Type, Authorization, x-api-key',
    );
  }

  Future<String?> _reachableIpv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {}
    return null;
  }

  String _id() {
    final rng = Random.secure();
    return List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
  }

  String _defaultSystemPrompt(String modelName) {
    if (Get.isRegistered<SettingsController>()) {
      return Get.find<SettingsController>().effectiveSystemPromptForModel(
        modelName,
      );
    }
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
  }
}

class _ApiError implements Exception {
  final int status;
  final String message;
  final String? param;
  _ApiError(this.status, this.message, {this.param});
}

/// Streams server-sent events over the raw socket.
///
/// dart:io's HttpServer never reports a client that hangs up mid-response
/// (flush() keeps succeeding and `done` never errors), so the response is
/// detached and the socket itself is watched: it closes the moment the client
/// goes away. Writes are fire-and-forget, so nothing here can block the
/// request handler (and leave the server stuck busy).
class _SseStream {
  _SseStream._(this._socket, this._onDisconnect) {
    _socket.listen(
      (_) {},
      onDone: _disconnect,
      onError: (_) => _disconnect(),
      cancelOnError: true,
    );
  }

  static Future<_SseStream> open(
    HttpResponse response, {
    required void Function() onDisconnect,
  }) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // The body ends when the connection closes; no chunked framing needed.
    response.headers.chunkedTransferEncoding = false;
    response.headers.set(HttpHeaders.connectionHeader, 'close');
    final socket = await response.detachSocket(writeHeaders: true);
    return _SseStream._(socket, onDisconnect);
  }

  final Socket _socket;
  final void Function() _onDisconnect;
  bool _disconnected = false;
  bool _closed = false;

  void event(Object payload) => raw('data: ${jsonEncode(payload)}\n\n');

  void raw(String chunk) {
    if (_disconnected || _closed) return;
    try {
      _socket.write(chunk);
    } catch (_) {
      _disconnect();
    }
  }

  void _disconnect() {
    if (_disconnected) return;
    _disconnected = true;
    if (!_closed) _onDisconnect();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      _socket.destroy();
    }
  }
}

class _ParsedChatRequest {
  final String prompt;
  final String? systemPrompt;
  final List<Map<String, String>> history;
  final String? imagePath;
  final String? audioPath;

  /// Messages in OpenAI form (no system), for the model's Jinja template.
  final List<Map<String, dynamic>> oaiMessages;

  /// The history has assistant tool calls or tool results.
  final bool hasToolTurns;
  final String? error;

  _ParsedChatRequest({
    required this.prompt,
    required this.systemPrompt,
    required this.history,
    required this.imagePath,
    required this.audioPath,
    this.oaiMessages = const [],
    this.hasToolTurns = false,
  }) : error = null;

  _ParsedChatRequest.error(this.error)
      : prompt = '',
        systemPrompt = null,
        history = const [],
        imagePath = null,
        audioPath = null,
        oaiMessages = const [],
        hasToolTurns = false;
}

class _ContentResult {
  final String text;
  final String? imagePath;
  final String? audioPath;
  final String? error;

  _ContentResult({
    required this.text,
    this.imagePath,
    this.audioPath,
  }) : error = null;

  _ContentResult.error(this.error)
      : text = '',
        imagePath = null,
        audioPath = null;
}

class _TempFileResult {
  final File? file;
  final String? error;

  _TempFileResult(this.file) : error = null;
  _TempFileResult.error(this.error) : file = null;

  String get path => file!.path;
}
