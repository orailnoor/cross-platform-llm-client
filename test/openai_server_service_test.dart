import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/openai_server_service_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These integration tests exercise a real loopback HTTP server.
  HttpOverrides.global = null;

  late OpenAiServerService server;
  late HttpClient client;
  const port = 18765;

  setUp(() {
    server = OpenAiServerService();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final req =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.persistentConnection = false;
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    final res = await req.close();
    await res.drain<void>();
    return res;
  }

  test('binds to loopback only by default', () async {
    await server.start(port: port);
    expect(server.localUrl, 'http://127.0.0.1:$port');
  });

  test('network mode refuses to start without an API key', () async {
    expect(
      () => server.start(port: port, allowNetwork: true),
      throwsArgumentError,
    );
    expect(server.isRunning, isFalse);
  });

  test('enforces the API key and applies key changes live', () async {
    await server.start(port: port, apiKey: 'first');

    expect((await send('GET', '/v1/models')).statusCode, 401);
    expect(
      (await send('GET', '/health')).statusCode,
      200,
      reason: 'health check stays public',
    );

    server.updateApiKey('second');
    expect(
      (await send('GET', '/v1/server/capabilities',
              headers: {'Authorization': 'Bearer first'}))
          .statusCode,
      401,
    );
  });

  test('rejects POST bodies that are not JSON', () async {
    await server.start(port: port);
    final res = await send('POST', '/v1/chat/completions',
        headers: {'Content-Type': 'text/plain'},
        body: jsonEncode({'messages': []}));
    expect(res.statusCode, HttpStatus.unsupportedMediaType);
  });

  test('only sends CORS headers when a key is required', () async {
    await server.start(port: port);
    var res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), isNull);
    await server.stop();

    await server.start(port: port, apiKey: 'k');
    res = await send('GET', '/health');
    expect(res.headers.value('access-control-allow-origin'), '*');
  });

  group('generation', () {
    late FakeInference fake;
    const json = {'Content-Type': 'application/json'};
    String chatBody({bool stream = false, int? maxTokens}) => jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          if (stream) 'stream': true,
          if (maxTokens != null) 'max_tokens': maxTokens,
        });

    setUp(() async {
      fake = FakeInference();
      Get.put<InferenceService>(fake);
      await server.start(port: port);
    });

    tearDown(Get.reset);

    group('conversation attachments', () {
      late Directory temp;
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

      setUp(() async {
        temp = await Directory.systemTemp.createTemp('server_attachment_test');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getTemporaryDirectory') return temp.path;
          return null;
        });
      });

      tearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        // Response delivery can finish before the handler's finally cleanup.
        await Future.doWhile(() async {
          if (await temp.list().isEmpty) return false;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        }).timeout(const Duration(seconds: 2));
        await temp.delete();
      });

      Map<String, dynamic> attachmentMessage(
          String kind, String text, List<int> bytes) {
        final dataUrl = 'data:${kind == 'image' ? 'image/png' : 'audio/wav'};'
            'base64,${base64Encode(bytes)}';
        return {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
            if (kind == 'image')
              {
                'type': 'image_url',
                'image_url': {'url': dataUrl},
              }
            else
              {
                'type': 'input_audio',
                'input_audio': {'data': dataUrl},
              },
          ],
        };
      }

      for (final kind in ['image', 'audio']) {
        for (final streaming in [false, true]) {
          test('uses the latest user $kind (stream=$streaming)', () async {
            final res = await send('POST', '/v1/chat/completions',
                headers: json,
                body: jsonEncode({
                  'stream': streaming,
                  'messages': [
                    attachmentMessage(kind, 'Old attachment', [1, 2]),
                    {'role': 'assistant', 'content': 'Previous reply'},
                    attachmentMessage(kind, 'New attachment', [3, 4]),
                  ],
                }));

            expect(res.statusCode, 200);
            expect(kind == 'image' ? fake.lastImageBytes : fake.lastAudioBytes,
                [3, 4]);
            expect(fake.lastPrompt, 'New attachment');
            expect(fake.lastHistory, [
              {'role': 'user', 'content': 'Old attachment'},
              {'role': 'assistant', 'content': 'Previous reply'},
            ]);
          });
        }

        test('does not reuse historical $kind for a text-only user turn',
            () async {
          final res = await send('POST', '/v1/chat/completions',
              headers: json,
              body: jsonEncode({
                'messages': [
                  attachmentMessage(kind, 'Old attachment', [1, 2]),
                  {'role': 'assistant', 'content': 'Previous reply'},
                  {'role': 'user', 'content': 'A new text question'},
                ],
              }));

          expect(res.statusCode, 200);
          expect(fake.lastImageBytes, isNull);
          expect(fake.lastAudioBytes, isNull);
          expect(fake.lastPrompt, 'A new text question');
        });

        test('accepts an attachment-only final user $kind', () async {
          final res = await send('POST', '/v1/chat/completions',
              headers: json,
              body: jsonEncode({
                'messages': [
                  attachmentMessage(kind, '', [3, 4])
                ],
              }));

          expect(res.statusCode, 200);
          expect(kind == 'image' ? fake.lastImageBytes : fake.lastAudioBytes,
              [3, 4]);
          expect(fake.lastPrompt, 'Describe this attachment.');
        });
      }

      test('changing attachment types does not combine separate user turns',
          () async {
        final res = await send('POST', '/v1/chat/completions',
            headers: json,
            body: jsonEncode({
              'messages': [
                attachmentMessage('image', 'Old image', [1, 2]),
                {'role': 'assistant', 'content': 'Previous reply'},
                attachmentMessage('audio', 'New audio', [3, 4]),
              ],
            }));

        expect(res.statusCode, 200);
        expect(fake.lastImageBytes, isNull);
        expect(fake.lastAudioBytes, [3, 4]);
      });

      test('an old attachment cannot substitute for a missing final user turn',
          () async {
        final res = await send('POST', '/v1/chat/completions',
            headers: json,
            body: jsonEncode({
              'messages': [
                attachmentMessage('image', 'Old image', [1, 2]),
                {'role': 'assistant', 'content': 'Previous reply'},
              ],
            }));

        expect(res.statusCode, HttpStatus.badRequest);
        expect(fake.lastPrompt, isNull);
      });
    });

    test('passes max_tokens through to the model', () async {
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody(maxTokens: 7));
      expect(res.statusCode, 200);
      expect(fake.lastMaxTokens, 7);
    });

    test('passes OpenAI stop (string or list) through to the model', () async {
      var res = await send('POST', '/v1/chat/completions',
          headers: json,
          body: jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'hi'}
            ],
            'stop': '###',
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['###']);
      res = await send('POST', '/v1/completions',
          headers: json,
          body: jsonEncode({
            'prompt': 'hi',
            'stop': ['a', 'b', 7, 'c', 'd', 'e'],
          }));
      expect(res.statusCode, 200);
      expect(fake.lastStop, ['a', 'b', 'c', 'd'],
          reason: 'non-strings dropped, at most 4 like OpenAI');
    });

    test('rejects with 429 while the app is generating', () async {
      fake.isGenerating.value = true;
      final res = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(res.statusCode, 429);
    });

    test('reports 503 when the generation is interrupted', () async {
      fake.tokensToEmit = 50;
      final pending =
          send('POST', '/v1/chat/completions', headers: json, body: chatBody());
      await Future.delayed(const Duration(milliseconds: 100));
      await fake.stopGeneration(); // e.g. the user started a chat reply
      expect((await pending).statusCode, HttpStatus.serviceUnavailable);
    });

    test('streams live and stops the model when the client disconnects',
        () async {
      fake.tokensToEmit = 1000;
      final req = await client.openUrl(
          'POST', Uri.parse('http://127.0.0.1:$port/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(chatBody(stream: true));
      final res = await req.close();
      final firstChunk = Completer<void>();
      final sub = res.listen((_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      });
      await firstChunk.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
      client.close(force: true);
      client = HttpClient();

      // The server must notice, stop the model, and free itself up.
      for (var i = 0; i < 40 && fake.stops == 0; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(fake.stops, 1);
      await Future.delayed(const Duration(milliseconds: 100));
      fake.tokensToEmit = 1;
      final next = await send('POST', '/v1/chat/completions',
          headers: json, body: chatBody());
      expect(next.statusCode, 200, reason: 'server must not stay busy');
    });
  });
}

/// Minimal stand-in for InferenceService: tokens are emitted on a timer until
/// stopped, so tests can observe busy/stop/interrupt behaviour.
class FakeInference extends GetxService implements InferenceService {
  @override
  final isModelLoaded = true.obs;
  @override
  final isGenerating = false.obs;
  @override
  final loadedModelName = 'fake-model'.obs;
  @override
  final generationSource = ''.obs;
  @override
  final isVisionLoaded = false.obs;
  @override
  final loadedModelRuntime = 'litert'.obs;

  int? lastMaxTokens;
  String? lastPrompt;
  List<Map<String, String>>? lastHistory;
  List<int>? lastImageBytes;
  List<int>? lastAudioBytes;
  List<String> lastStop = const [];
  int stops = 0;
  Duration tokenInterval = const Duration(milliseconds: 20);
  int tokensToEmit = 3;
  Completer<void>? _stopped;

  @override
  int get stopCount => stops;

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
    lastPrompt = prompt;
    lastHistory = conversationHistory;
    lastImageBytes =
        imagePath == null ? null : await File(imagePath).readAsBytes();
    lastAudioBytes =
        audioPath == null ? null : await File(audioPath).readAsBytes();
    lastMaxTokens = maxTokens;
    lastStop = stopSequences;
    isGenerating.value = true;
    generationSource.value = source;
    final stopped = _stopped = Completer<void>();
    final out = StringBuffer();
    for (var i = 0; i < tokensToEmit && !stopped.isCompleted; i++) {
      await Future.any([Future.delayed(tokenInterval), stopped.future]);
      if (stopped.isCompleted) break;
      out.write('t$i ');
      onToken?.call('t$i ');
    }
    isGenerating.value = false;
    generationSource.value = '';
    return out.toString();
  }

  @override
  Future<void> stopGeneration() async {
    stops++;
    isGenerating.value = false;
    generationSource.value = '';
    if (_stopped != null && !_stopped!.isCompleted) _stopped!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
