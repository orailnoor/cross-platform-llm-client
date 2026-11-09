import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../controllers/server_controller.dart';
import 'cluster_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';

/// Bench build: an HTTP control surface so a PC can drive model loads,
/// cluster layouts and llama-bench style measurements without the UI.
///
/// Started on every launch on [port] (all interfaces) and protected by a
/// bearer token (see [token]). Endpoints (JSON in / JSON out):
///   GET  /admin/status            model, context, split, memory, worker
///   GET  /admin/devices?gpu=1     ggml devices (optionally loads the GPU backend)
///   POST /admin/options           engine options for the next load
///   POST /admin/load              {path, ctx, workers:[{host,port,weight}], localWeight}
///   POST /admin/unload
///   POST /admin/bench             {depth, pp, tg}
///   POST /admin/worker            {action: start|stop, gpu}
///   POST /admin/generate          {prompt, maxTokens, temperature, seed, topK}
///                                 -> text + timing + stats (tokens, MTP counts)
///   GET  /admin/mtp               MTP draft head status + acceptance totals
///   POST /admin/mtp               {enabled, nDraft} runtime switch
/// /admin/load also takes {mtp: bool, mtpPath, nDraft, mmproj, lazyVision}.
class BenchAdmin {
  static const int port = 18080;

  /// Bearer token for every request, set at build time:
  ///   flutter build apk --dart-define=PRIVATELM_BENCH_TOKEN=<token>
  /// It keeps other machines on the LAN from driving the app. Without it the
  /// admin API stays off.
  static const String token = String.fromEnvironment('PRIVATELM_BENCH_TOKEN');

  HttpServer? _server;
  bool _busy = false;
  Map<String, dynamic> _lastOptions = const {};
  Map<String, dynamic>? _lastLoad;

  Future<void> start() async {
    if (_server != null) return;
    if (token.isEmpty) {
      print('[BenchAdmin] off (built without PRIVATELM_BENCH_TOKEN)');
      return;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _server!.listen(_handle);
      print('[BenchAdmin] listening on :$port');
    } catch (e) {
      print('[BenchAdmin] failed to start: $e');
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (auth.trim() != 'Bearer $token') {
        return _json(req, {'error': 'Unauthorized'}, status: 401);
      }
      final path = req.uri.path;
      final body = req.method == 'POST' ? await _readJson(req) : <String, dynamic>{};
      switch ('${req.method} $path') {
        case 'GET /admin/status':
          return _json(req, await _status());
        case 'GET /admin/devices':
          final text = await LlamaCluster.devices(loadGpu: req.uri.queryParameters['gpu'] == '1');
          return _json(req, {'devices': _lines(text)});
        case 'POST /admin/options':
          _lastOptions = Map<String, dynamic>.from(body);
          await LlamaCluster.setEngineOptions(body);
          InferenceService.externalEngineOptions = true;
          return _json(req, {'ok': true, 'options': _lastOptions});
        case 'POST /admin/load':
          return _guarded(req, () => _load(body));
        case 'POST /admin/unload':
          return _guarded(req, () async {
            await Get.find<InferenceService>().unloadModel();
            _lastLoad = null;
            return {'ok': true, 'mem': await LlamaCluster.memInfo()};
          });
        case 'POST /admin/bench':
          return _guarded(req, () async {
            final inference = Get.find<InferenceService>();
            if (!inference.isModelLoaded.value) return {'error': 'no model loaded'};
            if (inference.isGenerating.value) return {'error': 'model is generating'};
            final sw = Stopwatch()..start();
            final text = await LlamaCluster.bench(
              depth: (body['depth'] as num?)?.toInt() ?? 0,
              pp: (body['pp'] as num?)?.toInt() ?? 512,
              tg: (body['tg'] as num?)?.toInt() ?? 64,
            );
            final result = Map<String, dynamic>.from(jsonDecode(text) as Map);
            result['wall_s'] = sw.elapsedMilliseconds / 1000.0;
            result['mem'] = await LlamaCluster.memInfo();
            return result;
          });
        case 'POST /admin/worker':
          final cluster = Get.find<ClusterService>();
          if (body['action'] == 'stop') {
            await cluster.stopWorker();
          } else {
            await cluster.startWorker(
                gpu: body['gpu'] == true, threads: (body['threads'] as num?)?.toInt());
          }
          await Future.delayed(const Duration(seconds: 2));
          await cluster.refreshWorkerStatus();
          return _json(req, _workerJson(cluster));
        case 'POST /admin/generate':
          return _guarded(req, () async {
            final inference = Get.find<InferenceService>();
            if (!inference.isModelLoaded.value) return {'error': 'no model loaded'};
            final sw = Stopwatch()..start();
            final text = await inference.generate(
              prompt: body['prompt'] as String? ?? 'Hello',
              systemPrompt: body['system'] as String? ?? 'You are a helpful assistant.',
              source: 'server',
              maxTokens: (body['maxTokens'] as num?)?.toInt() ?? 128,
              options: GenerationOptions(
                temperature: (body['temperature'] as num?)?.toDouble(),
                seed: (body['seed'] as num?)?.toInt(),
                topK: (body['topK'] as num?)?.toInt(),
                rawPrompt: body['raw'] == true,
              ),
            );
            return {
              'text': text,
              'wall_s': sw.elapsedMilliseconds / 1000.0,
              'stats': inference.lastStats?.toJson(),
              'mtp': await inference.mtpInfo(),
            };
          });
        case 'POST /admin/server':
          // {action: start|stop, apiKey?, allowNetwork?}: drives the OpenAI server
          // the same way the Server screen does.
          final sc = Get.find<ServerController>();
          if (body['action'] == 'stop') {
            await sc.stopServer();
          } else {
            final key = body['apiKey'];
            if (key is String && key.isNotEmpty) {
              sc.apiKey.value = key;
              sc.apiKeyCtrl.text = key;
              sc.useApiKey.value = true;
            }
            if (body['allowNetwork'] != null) {
              await sc.setAllowNetwork(body['allowNetwork'] == true);
            }
            await sc.saveSettings();
            if (!sc.isRunning.value) await sc.startServer(silent: true);
          }
          return _json(req, {
            'running': sc.isRunning.value,
            'url': sc.localUrl.value,
            'status': sc.serverStatus.value,
            'error': sc.lastError.value,
            'port': ServerController.port,
            'allowNetwork': sc.allowNetwork.value,
          });
        case 'POST /admin/settings':
          // {key: value, ...} written straight to the Hive settings box.
          final hive = Get.find<HiveService>();
          for (final e in body.entries) {
            await hive.setSetting(e.key, e.value);
          }
          return _json(req, {'ok': true, 'set': body.keys.toList()});
        case 'GET /admin/mtp':
          return _json(req, {
            'status': Get.find<InferenceService>().mtpStatus,
            ...await Get.find<InferenceService>().mtpInfo(),
          });
        case 'POST /admin/mtp':
          return _guarded(req, () async {
            await LlamaExt.setMtp(
                enabled: body['enabled'] != false,
                nDraft: (body['nDraft'] as num?)?.toInt() ?? 0);
            return await Get.find<InferenceService>().mtpInfo();
          });
      }
      return _json(req, {'error': 'Not found: ${req.method} $path'}, status: 404);
    } catch (e, st) {
      print('[BenchAdmin] error: $e\n$st');
      try {
        await _json(req, {'error': '$e'}, status: 500);
      } catch (_) {}
    }
  }

  Future<void> _guarded(HttpRequest req, Future<Map<String, dynamic>> Function() run) async {
    if (_busy) return _json(req, {'error': 'busy'}, status: 429);
    _busy = true;
    try {
      final result = await run();
      return _json(req, result, status: result.containsKey('error') ? 400 : 200);
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>> _load(Map<String, dynamic> body) async {
    final inference = Get.find<InferenceService>();
    final cluster = Get.find<ClusterService>();
    final hive = Get.find<HiveService>();
    final path = body['path'] as String?;
    if (path == null || !File(path).existsSync()) return {'error': 'model file not found: $path'};
    final ctx = (body['ctx'] as num?)?.toInt() ?? 4096;
    await hive.setSetting(AppConstants.keyContextSize, ctx);

    final workers = (body['workers'] as List?) ?? const [];
    cluster.adminWorkers = [
      for (final w in workers)
        ClusterWorker(
          name: (w as Map)['name'] as String? ?? '${w['host']}',
          host: w['host'] as String,
          port: (w['port'] as num?)?.toInt() ?? LlamaCluster.defaultPort,
          model: w['name'] as String?,
        ),
    ];
    cluster.adminWeights = [
      for (final w in workers) ((w as Map)['weight'] as num?)?.toDouble() ?? 1.0,
    ];
    cluster.adminLocalWeight = (body['localWeight'] as num?)?.toDouble() ?? 1.0;
    // Names the split shows come from the saved worker list.
    for (final w in cluster.adminWorkers!) {
      if (!cluster.workers.any((s) => s.endpoint == w.endpoint)) cluster.workers.add(w);
    }

    // Helper files for this load: MTP draft head and vision projector.
    final file = path.split('/').last;
    if (body.containsKey('mtp')) {
      await hive.setSetting(AppConstants.keyMtpEnabled, body['mtp'] == true);
    }
    if (body['nDraft'] is num) {
      await hive.setSetting(AppConstants.keyMtpDraftTokens, (body['nDraft'] as num).toInt());
    }
    if (body.containsKey('mtpPath')) {
      await inference.setHelperOverride(
          AppConstants.keyMtpOverrides, file, body['mtpPath'] as String?);
    }
    if (body.containsKey('mmproj')) {
      await inference.setHelperOverride(
          AppConstants.keyMmprojOverrides, file, body['mmproj'] as String?);
    }
    if (body.containsKey('lazyVision')) {
      await hive.setSetting(AppConstants.keyVisionLazyLoad, body['lazyVision'] == true);
    }

    final sw = Stopwatch()..start();
    final message = await inference.loadModel(path, modelName: path.split('/').last);
    final loadS = sw.elapsedMilliseconds / 1000.0;
    cluster.adminWorkers = null;
    final ok = inference.isModelLoaded.value;
    _lastLoad = {
      'path': path,
      'ctx': ctx,
      'workers': workers,
      'localWeight': cluster.adminLocalWeight,
      'options': _lastOptions,
      'load_s': loadS,
    };
    return {
      if (!ok) 'error': message,
      'message': message,
      'load_s': loadS,
      'mtp': inference.mtpStatus,
      'mmproj': inference.loadedMmprojPath,
      'vision': inference.ggufVisionLoaded,
      'n_ctx': inference.contextTokensTotal.value,
      'split': [for (final s in cluster.split) {'name': s.name, 'mb': s.mb}],
      'memLog': _lines(await LlamaCluster.memLog()),
      'mem': await LlamaCluster.memInfo(),
    };
  }

  Future<Map<String, dynamic>> _status() async {
    final inference = Get.find<InferenceService>();
    final cluster = Get.find<ClusterService>();
    await cluster.refreshWorkerStatus();
    return {
      'loaded': inference.isModelLoaded.value,
      'loading': inference.isLoadingModel.value,
      'generating': inference.isGenerating.value,
      'model': inference.loadedModelName.value,
      'backend': inference.loadedBackend.value,
      'n_ctx': inference.contextTokensTotal.value,
      'mtp': {'status': inference.mtpStatus, ...await inference.mtpInfo()},
      'mmproj': inference.loadedMmprojPath,
      'lastStats': inference.lastStats?.toJson(),
      'split': [for (final s in cluster.split) {'name': s.name, 'mb': s.mb}],
      'lastLoad': _lastLoad,
      'options': _lastOptions,
      'worker': _workerJson(cluster),
      'mem': await LlamaCluster.memInfo(),
      'memLog': _lines(await LlamaCluster.memLog()),
    };
  }

  Map<String, dynamic> _workerJson(ClusterService cluster) {
    final w = cluster.worker.value;
    return {
      'state': w.state,
      'error': w.error,
      'peer': w.peer,
      'heldMb': w.heldMb,
      'ramMb': w.ramMb,
      'bandwidth': w.bandwidth,
      'throttled': w.throttled,
    };
  }

  static List<String> _lines(String text) =>
      text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.trim().isEmpty) return {};
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  Future<void> _json(HttpRequest req, Object payload, {int status = 200}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    await req.response.close();
  }
}
