import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';

String _chunk(String token, {String? finish}) => 'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': token},
          'finish_reason': finish,
        }
      ]
    })}\n\n';

void main() {
  late Directory dir;
  late HttpServer server;
  late CloudService cloud;
  late String? authorization;
  late String requestPath;
  // What the fake provider streams back for the next request.
  late Future<void> Function(HttpResponse res) respond;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      authorization = req.headers.value(HttpHeaders.authorizationHeader);
      requestPath = req.uri.path;
      await req.drain<void>();
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      await respond(req.response);
    });

    await hive.setSetting(AppConstants.keyCloudProvider, 'custom');
    await hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, 'http://127.0.0.1:${server.port}');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'test-key');
    await hive.setSetting(AppConstants.keyCustomCloudModel, 'test-model');
    cloud = CloudService();
  });

  tearDown(() async {
    CloudService.streamIdleTimeout = const Duration(seconds: 60);
    await server.close(force: true);
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<String> send(List<String> tokens) => cloud.sendMessage(
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
        onToken: tokens.add,
      );

  test('a complete stream returns the text', () async {
    respond = (res) async {
      res.write(_chunk('Hello '));
      res.write(_chunk('world', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    expect(await send(tokens), 'Hello world');
    expect(tokens.join(), 'Hello world');
  });

  test('a local OpenAI-compatible server works without authentication', () async {
    final hive = Get.find<HiveService>();
    await hive.setSetting(AppConstants.keyCustomCloudKey, '');
    await hive.setSetting(AppConstants.keyCustomCloudBaseUrl,
        'http://127.0.0.1:${server.port}/v1');
    expect(cloud.isConfigured, isTrue);
    respond = (res) async {
      res.write(_chunk('Local reply', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), 'Local reply');
    expect(authorization, isNull);
    expect(requestPath, '/v1/chat/completions');
  });

  test('non-streaming local requests also allow an empty API key', () async {
    await Get.find<HiveService>().setSetting(AppConstants.keyCustomCloudKey, '');
    respond = (res) async {
      res.write(jsonEncode({
        'choices': [
          {'message': {'content': 'Local reply'}}
        ]
      }));
      await res.close();
    };
    expect(await cloud.sendMessage(messages: [
      {'role': 'user', 'content': 'hi'}
    ]), 'Local reply');
    expect(authorization, isNull);
  });

  test('configured local server authentication is retained', () async {
    respond = (res) async {
      res.write(_chunk('Authenticated', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), 'Authenticated');
    expect(authorization, 'Bearer test-key');
  });

  test('hosted providers still require an API key', () async {
    await Get.find<HiveService>()
        .setSetting(AppConstants.keyCloudProvider, 'openai');
    expect(cloud.isConfigured, isFalse);
    expect(await send([]), startsWith('ERROR: No API key'));
  });

  test('an error event mid-stream is reported, not shown as a reply',
      () async {
    respond = (res) async {
      res.write(_chunk('Partial '));
      res.write('data: ${jsonEncode({
            'error': {'message': 'Rate limit exceeded'}
          })}\n\n');
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Partial'));
    expect(result, contains('Rate limit exceeded'));
  });

  test('an error event before any text is an ERROR', () async {
    respond = (res) async {
      res.write('data: ${jsonEncode({'error': 'upstream failed'})}\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stream that ends without [DONE] is marked as cut off', () async {
    respond = (res) async {
      res.write(_chunk('Half an answer'));
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Half an answer'));
    expect(result, contains('cut off'));
  });

  test('an empty stream is an ERROR, not a blank reply', () async {
    respond = (res) async {
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stalled stream times out instead of hanging', () async {
    CloudService.streamIdleTimeout = const Duration(milliseconds: 300);
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush(); // ...then nothing more
      await Future.delayed(const Duration(seconds: 5));
    };
    final result = await send([]).timeout(const Duration(seconds: 3));
    expect(result, startsWith('ERROR:'));
    expect(result, contains("didn't respond in time"));
  });

  test('cancel() aborts the stream in progress', () async {
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush();
      await Future.delayed(const Duration(seconds: 5));
    };
    final pending = send([]);
    await Future.delayed(const Duration(milliseconds: 200));
    cloud.cancel();
    expect(await pending.timeout(const Duration(seconds: 2)),
        startsWith('ERROR:'));
  });
}
