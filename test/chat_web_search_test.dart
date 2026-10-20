import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:privatelm/controllers/chat_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/image_generation_notification_service.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/local_image_service.dart';
import 'package:privatelm/services/parallel_search_service.dart';

class _Settings extends SettingsController {
  // Skip settings plugin/UI startup in the scripted inference fixture.
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// Scripted inference, not a live model test. Captures actual chat dispatch.
class _Model extends InferenceService {
  final prompts = <String>[];
  final histories = <List<Map<String, String>>>[];
  final systems = <String?>[];

  @override
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    prompts.add(prompt);
    histories.add(conversationHistory ?? []);
    systems.add(systemPrompt);
    onToken?.call('Grounded answer');
    return 'Grounded answer';
  }
}

class _Notifications extends ImageGenerationNotificationService {
  @override
  Future<void> cancel() async {}
}

/// Records the real anonymous HTTP exchange only for explicitly enabled tests.
class _LiveClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final List<Map<String, Object?>> transcript;
  _LiveClient(this.transcript);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final entry = <String, Object?>{
      'url': request.url.toString(),
      'headers': Map<String, String>.from(request.headers),
      'request': jsonDecode((request as http.Request).body),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    transcript.add(entry);
    final response = await http.Response.fromStream(await _inner.send(request));
    entry.addAll({
      'status': response.statusCode,
      'responseHeaders': response.headers,
      'response': response.body
    });
    return http.StreamedResponse(
        Stream.value(response.bodyBytes), response.statusCode,
        headers: response.headers);
  }

  @override
  void close() => _inner.close();
}

void main() {
  late Directory dir;
  late HiveService hive;
  late _Model model;
  late _Settings settings;
  late List<ChatController> chats;
  late List<http.Request> requests;
  late List<Map<String, dynamic>> calls;
  late Future<http.Response> Function(http.Request, Map<String, dynamic>) reply;
  late ParallelSearchService search;
  var sse = false;

  http.Response success(Map<String, dynamic> request, Object result) =>
      http.Response(
        sse
            ? ': keepalive\n\nevent: message\ndata: ${jsonEncode({
                    'jsonrpc': '2.0',
                    'id': request['id'],
                    'result': result
                  })}\n\n'
            : jsonEncode(
                {'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
        200,
        headers: {
          'content-type': sse ? 'text/event-stream' : 'application/json'
        },
      );

  Future<http.Response> normal(
      http.Request request, Map<String, dynamic> body) async {
    switch (body['method']) {
      case 'initialize':
        return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {'protocolVersion': '2025-03-26'}
            }),
            200,
            headers: {'mcp-session-id': 'transport-only'});
      case 'notifications/initialized':
        return http.Response('', 202);
      case 'tools/list':
        return success(body, {
          'tools': [
            {'name': 'web_search'},
            {'name': 'web_fetch'}
          ]
        });
      default:
        return success(body, {
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({
                'results': [
                  {
                    'url': 'https://flutter.dev/docs',
                    'title': 'Flutter docs',
                    'excerpts': ['Current Flutter release information.']
                  },
                  {
                    'url': 'javascript:alert(1)',
                    'excerpts': ['Invalid URL must be discarded.']
                  },
                ]
              })
            }
          ]
        });
    }
  }

  ChatController chat({Future<bool> Function(WebSearchCommand)? consent}) {
    final controller =
        ChatController(confirmWebRequest: consent ?? (_) async => true);
    chats.add(controller);
    return controller;
  }

  Future<void> send(ChatController controller, String text) async {
    controller.textController.text = text;
    await controller.sendMessage();
  }

  setUp(() async {
    Get.testMode = true;
    dir = await Directory.systemTemp.createTemp('chat_web_search');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());
    model = _Model();
    Get.put<InferenceService>(model);
    settings = _Settings();
    Get.put<SettingsController>(settings);
    Get.put(LocalImageService());
    Get.put(CloudService());
    Get.put<ImageGenerationNotificationService>(_Notifications());
    chats = [];
    requests = [];
    calls = [];
    sse = false;
    reply = normal;
    search = ParallelSearchService(
      timeout: const Duration(seconds: 2),
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'tools/call') calls.add(body);
        return reply(request, body);
      }),
    );
    Get.put(search);
  });

  tearDown(() async {
    for (final controller in chats) {
      controller.onClose();
    }
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test(
      'fresh no-key chat dispatches search and consumes evidence in selected model',
      () async {
    final controller = chat();
    await send(controller, 'Private earlier conversation');
    await send(controller, '/search current Flutter stable version');
    expect(
        model.prompts.last, contains('Current Flutter release information.'));
    expect(model.histories.last.last['content'], model.prompts.last);
    expect(model.systems.last, AppConstants.systemPrompt);
    expect(controller.messages.last.content, contains('Grounded answer'));
    expect(controller.messages.last.content,
        contains('<https://flutter.dev/docs>'));
    expect(
        hive.getMessagesForChat(controller.currentSessionId.value).singleWhere(
            (m) => m['id'] == controller.messages.last.id)['content'],
        controller.messages.last.content);
    expect(calls.single['params']['name'], 'web_search');
    expect(calls.single['params']['arguments']['objective'],
        'current Flutter stable version');
    expect(requests.map((r) => jsonDecode(r.body)['method']), [
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/call'
    ]);
    for (final request in requests) {
      expect(request.url, ParallelSearchService.endpoint);
      expect(request.headers['User-Agent'], ParallelSearchService.userAgent);
      expect(request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')));
      expect(request.body, isNot(contains('Private earlier conversation')));
    }
    expect(requests.last.headers['Mcp-Session-Id'], 'transport-only');
    expect(calls.single['params']['arguments']['session_id'],
        controller.currentSessionId.value);
    expect(calls.single['params']['arguments']['session_id'],
        isNot('transport-only'));
  });

  test('ordinary messages never search; declined consent leaves input unsent',
      () async {
    final controller = chat(consent: (_) async => false);
    await send(controller, 'hello');
    expect(requests, isEmpty);
    final count = controller.messages.length;
    await send(controller, '/search current Flutter stable version');
    expect(requests, isEmpty);
    expect(controller.messages.length, count);
    expect(controller.textController.text,
        '/search current Flutter stable version');
    expect(controller.isLoading.value, isFalse);
  });

  test(
      'search, fetch, follow-up, quota retry and new chat have conversation-owned IDs',
      () async {
    final controller = chat();
    await send(controller, '/search current Flutter stable version');
    final first = controller.currentSessionId.value;
    sse = true;
    await send(controller, '/fetch https://flutter.dev/docs');
    expect(calls.last['params']['name'], 'web_fetch');
    expect(calls.last['params']['arguments']['urls'],
        ['https://flutter.dev/docs']);
    expect(model.prompts.last, contains('Summarize this webpage'));
    await send(controller, '/search Flutter stable release notes');
    reply = (r, b) async => b['method'] == 'tools/call'
        ? http.Response('quota exceeded', 429)
        : await normal(r, b);
    await send(controller, '/search Flutter stable release notes');
    expect(controller.messages.last.content, contains('rate limited'));
    reply = normal;
    await send(controller, '/search Flutter stable release notes');
    expect(calls.take(5).map((c) => c['params']['arguments']['session_id']),
        everyElement(first));
    controller.createNewChat();
    await send(controller, '/search current Flutter stable version');
    expect(calls.last['params']['arguments']['session_id'], isNot(first));
    expect(
        model.prompts.last, isNot(contains('Invalid URL must be discarded')));
  });

  test('interleaved chats sharing the search service keep distinct identities',
      () async {
    final a = chat();
    final b = chat();
    final gate = Completer<void>();
    reply = (r, body) async {
      if (body['method'] == 'tools/call') {
        if (calls.length == 2) gate.complete();
        await gate.future;
      }
      return normal(r, body);
    };
    await Future.wait([
      send(a, '/search current Flutter stable version'),
      send(b, '/search Dart current release notes'),
    ]);
    expect(calls.map((c) => c['params']['arguments']['session_id']).toSet(),
        {a.currentSessionId.value, b.currentSessionId.value});
    await send(a, '/fetch https://flutter.dev/docs');
    expect(calls.last['params']['arguments']['session_id'],
        a.currentSessionId.value);
  });

  test('search failures and malformed results never fall back to inference',
      () async {
    final controller = chat();
    for (final kind in ['http', 'rpc', 'tool', 'malformed', 'empty']) {
      reply = (r, b) async {
        if (b['method'] != 'tools/call') return normal(r, b);
        switch (kind) {
          case 'http':
            return http.Response('down', 503);
          case 'rpc':
            return http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': b['id'],
                  'error': {'code': -32603}
                }),
                200);
          case 'tool':
            return success(b, {'isError': true});
          case 'empty':
            return success(b, {
              'structuredContent': {'results': []}
            });
          default:
            return http.Response('{bad json', 200);
        }
      };
      await send(controller, '/search current Flutter stable version');
      expect(controller.messages.last.content, contains('Error:'));
      expect(controller.isLoading.value, isFalse);
    }
    expect(model.prompts, isEmpty);
  });

  test('Stop during discovery prevents tools and model dispatch', () async {
    final controller = chat();
    final started = Completer<void>();
    final release = Completer<void>();
    reply = (r, b) async {
      if (b['method'] == 'tools/list') {
        started.complete();
        await release.future;
      }
      return normal(r, b);
    };
    final pending = send(controller, '/search current Flutter stable version');
    await started.future;
    controller.stopGenerating();
    await pending;
    release.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    expect(model.prompts, isEmpty);
    expect(controller.messages.where((m) => m.role == 'assistant'), isEmpty);
  });

  test('timeout reports an error and does not dispatch a late response',
      () async {
    await Get.delete<ParallelSearchService>(force: true);
    Get.put<ParallelSearchService>(ParallelSearchService(
      timeout: const Duration(milliseconds: 10),
      clientFactory: () => MockClient((r) => Completer<http.Response>().future),
    ));
    final controller = chat();
    await send(controller, '/search current Flutter stable version');
    expect(controller.messages.last.content, contains('timed out'));
    expect(model.prompts, isEmpty);
  });

  test('invalid URLs and empty commands are rejected before requests', () {
    for (final input in [
      '/search',
      '/fetch',
      '/fetch file:///etc/passwd',
      '/fetch https://user:pass@example.com',
      '/fetch javascript:alert(1)'
    ]) {
      expect(() => WebSearchCommand.parse(input), throwsFormatException);
    }
    expect(WebSearchCommand.parse('/searching something'), isNull);
    expect(requests, isEmpty);
  });

  // Opt in with --dart-define=PARALLEL_LIVE=true. Uses scripted model inference,
  // real ChatController dispatch and real anonymous MCP discovery/search/fetch.
  test('live anonymous MCP through chat dispatch', () async {
    final transcript = <Map<String, Object?>>[];
    addTearDown(() {
      final path = Platform.environment['PARALLEL_LIVE_EVIDENCE'];
      if (path != null) {
        File(path).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(transcript));
      }
    });
    await Get.delete<ParallelSearchService>(force: true);
    Get.put(
        ParallelSearchService(clientFactory: () => _LiveClient(transcript)));
    final controller = chat();
    for (final text in [
      '/search current Flutter stable version',
      '/fetch https://flutter.dev'
    ]) {
      await send(controller, text);
      final quota = transcript
          .where((entry) => (entry['request'] as Map)['method'] == 'tools/call')
          .any((entry) =>
              entry['status'] == 429 ||
              RegExp(r'quota|rate.limit', caseSensitive: false)
                  .hasMatch(entry['response'].toString()));
      if (quota) {
        expect(controller.messages.last.content, contains('Error:'));
        // Explicit free anonymous quota is retained, never called a live success.
        return;
      }
      expect(controller.messages.last.content, startsWith('Grounded answer'));
      expect(controller.messages.last.content, contains('Sources (Parallel)'));
      expect(model.prompts.last, contains('<web_excerpts>'));
    }
    for (final entry in transcript) {
      expect(entry['url'], ParallelSearchService.endpoint.toString());
      expect((entry['headers'] as Map)['User-Agent'],
          ParallelSearchService.userAgent);
      final request = entry['request'] as Map;
      if (request['method'] == 'tools/call') {
        expect(request['params']['arguments']['session_id'],
            controller.currentSessionId.value);
      }
    }
  }, skip: !const bool.fromEnvironment('PARALLEL_LIVE'));

  test(
      'saved cloud text provider remains active with a local image model loaded',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final observed = Completer<Map<String, dynamic>>();
    server.listen((req) async {
      expect(req.headers.value('authorization'), 'Bearer saved-cloud-key');
      observed.complete(jsonDecode(await utf8.decoder.bind(req).join()));
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Cloud grounded answer'},
                'finish_reason': 'stop'
              }
            ]
          })}\n\ndata: [DONE]\n\n');
      await req.response.close();
    });
    await hive.setSetting(AppConstants.keyInferenceMode, 'cloud');
    await hive.setSetting(AppConstants.keyCloudProvider, 'custom');
    await hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, 'http://127.0.0.1:${server.port}');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'saved-cloud-key');
    await hive.setSetting(AppConstants.keyCustomCloudModel, 'saved-model');
    settings.globalSystemPrompt.value = 'Keep my custom system instructions.';
    Get.find<LocalImageService>().isModelLoaded.value = true;
    final controller = chat();
    await send(controller, '/search current Flutter stable version');
    final body = await observed.future;
    expect(body['model'], 'saved-model');
    expect(body['messages'].first['content'],
        'Keep my custom system instructions.');
    expect(body['messages'].last['content'],
        contains('Current Flutter release information.'));
    expect(controller.messages.last.content, contains('Cloud grounded answer'));
    expect(
        requests.any((r) =>
            r.body.contains('saved-cloud-key') ||
            r.headers.values.contains('Bearer saved-cloud-key')),
        isFalse);
    expect(model.prompts, isEmpty);
    expect(hive.getSetting(AppConstants.keyCloudProvider), 'custom');
  });
}
