import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'llama_api.dart';
import 'windows_mdns.dart';

LlamaHostApi createHostApi(LlamaFlutterApi callbacks) =>
    Platform.isWindows ? WindowsLlamaHostApi(callbacks) : LlamaHostApi();
MethodChannel createClusterChannel() => Platform.isWindows
    ? const _WindowsClusterChannel()
    : const MethodChannel('llama_flutter_android/cluster');
int? get loadedGpuLayers =>
    Platform.isWindows ? WindowsLlamaRuntime.shared.loadedGpuLayers : null;

class _Pending {
  final done = Completer<Object?>();
  final void Function(Map<String, dynamic>)? onEvent;
  _Pending(this.onEvent);
}

/// One app-owned subprocess. All native responses are correlated by request ID.
class WindowsNativeProcess {
  final Process process;
  final _pending = <int, _Pending>{};
  int _nextId = 0;
  bool running = true;
  String diagnostics = '';
  Future<void>? _closing;

  WindowsNativeProcess._(this.process) {
    process.stdin.done
        .then<void>((_) {}, onError: (Object error) => _fail(error));
    process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (text) {
        diagnostics += text;
        if (diagnostics.length > 12000) {
          diagnostics = diagnostics.substring(diagnostics.length - 12000);
        }
        debugPrint('[Windows llama] ${text.trimRight()}');
      },
      onError: (Object error) => _fail(error),
    );
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        try {
          final message = jsonDecode(line) as Map<String, dynamic>;
          final pending = _pending[message['id']];
          if (pending == null) return;
          switch (message['event']) {
            case 'result':
              pending.done.complete(message['value']);
              _pending.remove(message['id']);
            case 'error':
              pending.done.completeError(StateError(
                '${message['message']}\n$diagnostics',
              ));
              _pending.remove(message['id']);
            default:
              pending.onEvent?.call(message);
          }
        } catch (error, stack) {
          _fail(StateError('Invalid native response: $error\n$stack'));
          process.kill();
        }
      },
      onError: (Object error) {
        _fail(error);
        process.kill();
      },
    );
    process.exitCode.then((code) {
      running = false;
      _fail(StateError(
          'Windows inference process exited ($code).\n$diagnostics'));
    });
  }

  static Future<WindowsNativeProcess> start(
    String executable, {
    List<String> arguments = const [],
  }) async {
    if (!await File(executable).exists()) {
      throw StateError(
        'The bundled Windows inference engine is missing: $executable. '
        'Extract the entire PrivateLM ZIP, not just the app EXE.',
      );
    }
    return WindowsNativeProcess._(await Process.start(
      executable,
      ['--parent', '$pid', ...arguments],
      workingDirectory: File(executable).parent.path,
    ));
  }

  Future<Object?> request(
    String operation, {
    Map<String, Object?> arguments = const {},
    void Function(Map<String, dynamic>)? onEvent,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!running || _closing != null) {
      throw StateError('Windows inference process is not running');
    }
    final id = ++_nextId;
    final pending = _Pending(onEvent);
    _pending[id] = pending;
    try {
      process.stdin
          .writeln(jsonEncode({'id': id, 'op': operation, ...arguments}));
      return await pending.done.future.timeout(timeout, onTimeout: () {
        final error = TimeoutException('Windows $operation timed out', timeout);
        _fail(error);
        process.kill();
        throw error;
      });
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    for (final request in _pending.values) {
      if (!request.done.isCompleted) request.done.completeError(error);
    }
    _pending.clear();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (!running) return;
    process.stdin.writeln(jsonEncode({'id': 0, 'op': 'quit'}));
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 8),
        onTimeout: () async {
      process.kill();
      return await process.exitCode;
    });
  }
}

class WindowsLlamaRuntime {
  static final shared = WindowsLlamaRuntime();
  final String executablePath;
  WindowsNativeProcess? _engine, _worker;
  Future<WindowsNativeProcess>? _starting;
  WindowsMdns? _advertiser;
  String? _workerError, _id;
  bool _workerRequested = false;
  bool modelLoaded = false;
  int loadedGpuLayers = 0;
  List<String> _endpoints = [];
  List<double> _weights = [];
  double _localWeight = 1;
  double? _bandwidth;

  WindowsLlamaRuntime({String? executablePath})
      : executablePath = executablePath ??
            '${File(Platform.resolvedExecutable).parent.path}'
                '${Platform.pathSeparator}privatelm-native.exe';

  Future<WindowsNativeProcess> get engine async {
    final current = _engine;
    if (current != null && current.running) return current;
    return _starting ??= _startEngine().whenComplete(() => _starting = null);
  }

  Future<WindowsNativeProcess> _startEngine() async {
    final child = await WindowsNativeProcess.start(executablePath);
    _engine = child;
    child.process.exitCode.then((_) {
      if (identical(_engine, child)) {
        modelLoaded = false;
        _engine = null;
      }
    });
    return child;
  }

  Future<Map<String, dynamic>> info({bool measure = false}) async {
    final result = await (await engine).request(
      'info',
      arguments: {'benchmark': measure},
    ) as Map<String, dynamic>;
    if (measure) _bandwidth = (result['bandwidth'] as num).toDouble();
    return result;
  }

  Future<void> load(
      ModelConfig config, void Function(double) onProgress) async {
    for (final endpoint in _endpoints) {
      if (!await probe(endpoint)) {
        throw PlatformException(
            code: 'UNREACHABLE', message: 'Worker $endpoint is not reachable');
      }
    }
    final result = await (await engine).request('load', arguments: {
      'path': config.modelPath,
      'threads': config.nThreads,
      'contextSize': config.contextSize,
      'gpuLayers': config.nGpuLayers ?? 0,
      'endpoints': _endpoints,
      'weights': _weights,
      'localWeight': _localWeight,
    }, onEvent: (event) {
      if (event['event'] == 'progress') {
        onProgress((event['value'] as num).toDouble());
      }
    }, timeout: const Duration(minutes: 10)) as Map<String, dynamic>;
    loadedGpuLayers = result['gpuLayers'] as int;
    modelLoaded = true;
  }

  Future<void> unload() async {
    final child = _engine ?? await _starting;
    if (child != null) await child.close();
    if (identical(_engine, child)) _engine = null;
    modelLoaded = false;
    loadedGpuLayers = 0;
  }

  static Future<bool> probe(String endpoint) async {
    final address = Uri.parse('tcp://$endpoint');
    if (address.host.isEmpty ||
        !address.hasPort ||
        address.port < 1 ||
        address.port > 65535) {
      throw FormatException(
          'Expected a worker address in host:port form', endpoint);
    }
    try {
      final socket = await Socket.connect(address.host, address.port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> setCluster(
      List<String> endpoints, List<double> weights, double localWeight) async {
    if (endpoints.length != weights.length ||
        weights.any((weight) => !weight.isFinite || weight <= 0) ||
        !localWeight.isFinite ||
        localWeight < 0) {
      throw ArgumentError('Invalid cluster weights');
    }
    for (final endpoint in endpoints) {
      if (!await probe(endpoint)) {
        throw PlatformException(
            code: 'UNREACHABLE', message: 'Worker $endpoint is not reachable');
      }
    }
    _endpoints = List.of(endpoints);
    _weights = List.of(weights);
    _localWeight = localWeight;
  }

  Future<String> get workerId async {
    if (_id != null) return _id!;
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null) {
      throw StateError('Windows LOCALAPPDATA is not available');
    }
    final file = File('$local\\PrivateLM\\worker-id');
    if (await file.exists()) {
      final stored = (await file.readAsString()).trim();
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(stored)) {
        throw StateError('Invalid saved worker ID: ${file.path}');
      }
      return _id = stored;
    }
    final random = Random.secure();
    final id = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    await file.parent.create(recursive: true);
    await file.writeAsString(id, flush: true);
    return _id = id;
  }

  Future<void> startWorker(
      {int port = 50052, int? threads, bool useGpu = true}) async {
    if (_workerRequested) return;
    if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
    if (await probe('127.0.0.1:$port')) {
      throw StateError('Worker port $port is already in use');
    }
    _workerRequested = true;
    _workerError = null;
    try {
      final child =
          await WindowsNativeProcess.start(executablePath, arguments: [
        '--worker',
        '$port',
        '--threads',
        '${threads ?? max(1, min(8, Platform.numberOfProcessors ~/ 2))}',
        '--worker-memory',
        useGpu ? 'gpu' : 'ram',
      ]);
      _worker = child;
      child.process.exitCode.then((code) {
        if (identical(_worker, child) && _workerRequested) {
          _workerError = 'Worker exited ($code).\n${child.diagnostics}';
          _workerRequested = false;
          _advertiser?.close();
          _advertiser = null;
        }
      });
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      do {
        if (!child.running) throw StateError(_workerError ?? child.diagnostics);
        if (await probe('127.0.0.1:$port')) break;
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Worker did not start listening');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (true);
      final status = await workerStatus();
      _advertiser = await WindowsMdns.advertise(
        id: await workerId,
        name: Platform.localHostname,
        port: port,
        ramMb: (status['ramMb'] as num).toInt(),
        bandwidth: (status['bandwidth'] as num).toDouble(),
      );
    } catch (error) {
      _workerError = error.toString();
      _workerRequested = false;
      _advertiser?.close();
      _advertiser = null;
      await _worker?.close();
      _worker = null;
      rethrow;
    }
  }

  Future<void> stopWorker() async {
    _workerRequested = false;
    _advertiser?.close();
    _advertiser = null;
    final child = _worker;
    _worker = null;
    await child?.close();
    _workerError = null;
  }

  Future<Map<String, dynamic>> workerStatus() async {
    final child = _worker;
    if (child == null || !child.running) {
      return {
        'state': _workerError == null ? 'stopped' : 'error',
        'error': _workerError
      };
    }
    final result = await child.request('status') as Map<String, dynamic>;
    return {...result, 'id': await workerId};
  }
}

class WindowsLlamaHostApi extends LlamaHostApi {
  final LlamaFlutterApi callbacks;
  final WindowsLlamaRuntime runtime;
  WindowsLlamaHostApi(this.callbacks, {WindowsLlamaRuntime? runtime})
      : runtime = runtime ?? WindowsLlamaRuntime.shared;

  @override
  Future<void> loadModel(ModelConfig config) async {
    try {
      await runtime.load(config, callbacks.onLoadProgress);
    } catch (_) {
      await runtime.unload();
      rethrow;
    }
    if (config.mmprojPath?.isNotEmpty == true) {
      throw PlatformException(
          code: 'VISION_LOAD_FAILED',
          message:
              'VISION_LOAD_FAILED: Windows currently supports GGUF text inference only.');
    }
  }

  Future<void> _generate(Map<String, Object?> request) async {
    try {
      await (await runtime.engine).request('generate', arguments: request,
          onEvent: (event) {
        if (event['event'] == 'token') {
          callbacks.onToken(event['value'] as String);
        }
      }, timeout: const Duration(minutes: 10));
      callbacks.onDone();
    } catch (error) {
      callbacks.onError(error.toString());
    }
  }

  Map<String, Object?> _sampling(GenerateRequest r) => {
        'maxTokens': r.maxTokens,
        'temperature': r.temperature,
        'topP': r.topP,
        'topK': r.topK,
        'minP': r.minP,
        'typicalP': r.typicalP,
        'repeatPenalty': r.repeatPenalty,
        'frequencyPenalty': r.frequencyPenalty,
        'presencePenalty': r.presencePenalty,
        'repeatLastN': r.repeatLastN,
        'mirostat': r.mirostat,
        'mirostatTau': r.mirostatTau,
        'mirostatEta': r.mirostatEta,
        if (r.seed != null) 'seed': r.seed,
      };

  @override
  Future<void> generate(GenerateRequest request) =>
      _generate({'prompt': request.prompt, ..._sampling(request)});

  @override
  Future<void> generateChat(ChatRequest request) => _generate({
        'messages': [
          for (final message in request.messages)
            {'role': message.role, 'content': message.content},
        ],
        if (request.template != null) 'template': request.template,
        ..._sampling(GenerateRequest(
          prompt: '',
          maxTokens: request.maxTokens,
          temperature: request.temperature,
          topP: request.topP,
          topK: request.topK,
          minP: request.minP,
          typicalP: request.typicalP,
          repeatPenalty: request.repeatPenalty,
          frequencyPenalty: request.frequencyPenalty,
          presencePenalty: request.presencePenalty,
          repeatLastN: request.repeatLastN,
          mirostat: request.mirostat,
          mirostatTau: request.mirostatTau,
          mirostatEta: request.mirostatEta,
          seed: request.seed,
          penalizeNewline: request.penalizeNewline,
        )),
      });

  @override
  Future<void> stop() async {
    final child = runtime._engine;
    if (child != null && child.running) await child.request('stop');
  }

  @override
  Future<void> dispose() => runtime.unload();

  @override
  Future<bool> isModelLoaded() async => runtime.modelLoaded;

  @override
  Future<ContextInfo> getContextInfo() async {
    final result =
        await (await runtime.engine).request('context') as Map<String, dynamic>;
    final used = result['tokensUsed'] as int;
    final total = result['contextSize'] as int;
    return ContextInfo(
        tokensUsed: used,
        contextSize: total,
        usagePercentage: total == 0 ? 0 : used * 100 / total);
  }

  @override
  Future<void> clearContext() async {
    await (await runtime.engine).request('reset');
  }

  @override
  Future<GpuInfo> detectGpu() async {
    final info = await runtime.info();
    return GpuInfo(
        vulkanSupported: info['gpuSupported'] as bool,
        gpuName: info['gpuName'] as String,
        vulkanApiVersion: -1,
        deviceLocalMemoryBytes: (info['gpuTotalBytes'] as num).toInt(),
        freeRamBytes: (info['freeRamBytes'] as num).toInt(),
        recommendedGpuLayers: info['gpuSupported'] == true ? 999 : 0);
  }

  @override
  Future<List<String>> getSupportedTemplates() async =>
      ['chatml', 'llama2', 'llama3', 'gemma'];

  @override
  // Windows rebuilds the KV cache from the full supplied chat each generation.
  Future<void> setSystemPromptLength(int length) async {}

  @override
  Future<void> registerCustomTemplate(String name, String content) async =>
      throw UnsupportedError(
          'Custom template registration is not supported on Windows');

  @override
  Future<void> unregisterCustomTemplate(String name) async =>
      throw UnsupportedError(
          'Custom template registration is not supported on Windows');
}

class _WindowsClusterChannel extends MethodChannel {
  const _WindowsClusterChannel() : super('llama_flutter_android/cluster');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final runtime = WindowsLlamaRuntime.shared;
    final args = arguments == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(arguments as Map);
    final Object? result;
    switch (method) {
      case 'startWorker':
        await runtime.startWorker(
            port: args['port'] as int? ?? 50052,
            threads: args['threads'] as int?,
            useGpu: args['useGpu'] as bool? ?? true);
        result = null;
      case 'stopWorker':
        await runtime.stopWorker();
        result = null;
      case 'workerStatus':
        result = await runtime.workerStatus();
      case 'localFreeRamMb':
        result = ((await runtime.info())['freeRamBytes'] as num).toInt() ~/
            (1024 * 1024);
      case 'benchmark':
        result = runtime._bandwidth ??
            ((await runtime.info(measure: true))['bandwidth'] as num)
                .toDouble();
      case 'lastLoadBuffers':
        result = runtime.modelLoaded
            ? await (await runtime.engine).request('buffers')
            : [];
      case 'probe':
        result = await WindowsLlamaRuntime.probe(args['endpoint'] as String);
      case 'discover':
        result = await WindowsMdns.discover(
          timeout: Duration(milliseconds: args['timeoutMs'] as int? ?? 4000),
        );
      case 'setCluster':
        await runtime.setCluster(
          List<String>.from(args['endpoints'] as List),
          (args['weights'] as List).map((w) => (w as num).toDouble()).toList(),
          (args['localWeight'] as num).toDouble(),
        );
        result = null;
      case 'requestBatteryUnrestricted':
      case 'setKeepScreenOn':
        // The native worker prevents Windows sleep for its entire lifetime.
        result = null;
      default:
        throw MissingPluginException(
            'Windows cluster method is not implemented: $method');
    }
    return result as T?;
  }
}
