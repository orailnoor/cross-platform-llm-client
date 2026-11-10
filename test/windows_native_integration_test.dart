import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:llama_flutter_android/src/llama_api.dart' show LlamaFlutterApi;
import 'package:llama_flutter_android/src/windows_runtime.dart';
import 'package:llama_flutter_android/src/windows_mdns.dart';

class _Callbacks implements LlamaFlutterApi {
  final text = StringBuffer();
  final errors = <String>[];
  final progress = <double>[];
  final firstToken = Completer<void>();
  @override
  void onToken(String token) {
    text.write(token);
    if (!firstToken.isCompleted) firstToken.complete();
  }

  @override
  void onDone() {}
  @override
  void onError(String error) => errors.add(error);
  @override
  void onLoadProgress(double value) => progress.add(value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['PRIVATELM_TEST_ENGINE'];
  final model = Platform.environment['PRIVATELM_TEST_MODEL'];
  final unavailable =
      !Platform.isWindows || executable == null || model == null;

  ModelConfig config(int gpuLayers) => ModelConfig(
        modelPath: model!,
        nThreads: 4,
        contextSize: 512,
        nGpuLayers: gpuLayers,
      );
  GenerateRequest prompt({int maxTokens = 32}) => GenerateRequest(
        prompt: 'Once upon a time',
        maxTokens: maxTokens,
        temperature: 0,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        typicalP: 1,
        repeatPenalty: 1.1,
        frequencyPenalty: 0,
        presencePenalty: 0,
        repeatLastN: 64,
        mirostat: 0,
        mirostatTau: 5,
        mirostatEta: 0.1,
        seed: 42,
        penalizeNewline: true,
      );
  ChatRequest chatPrompt() => ChatRequest(
        messages: [
          ChatMessage(role: 'system', content: 'You are a storyteller.'),
          ChatMessage(role: 'user', content: 'Tell a short story.'),
        ],
        maxTokens: 32,
        temperature: 0,
        topP: 0.9,
        topK: 40,
        minP: 0.05,
        typicalP: 1,
        repeatPenalty: 1.1,
        frequencyPenalty: 0,
        presencePenalty: 0,
        repeatLastN: 64,
        mirostat: 0,
        mirostatTau: 5,
        mirostatEta: 0.1,
        seed: 42,
        penalizeNewline: true,
      );

  test('bundled CPU engine loads, streams, resets and unloads a real GGUF',
      () async {
    final runtime = WindowsLlamaRuntime(executablePath: executable);
    final callbacks = _Callbacks();
    final host = WindowsLlamaHostApi(callbacks, runtime: runtime);
    try {
      await host.loadModel(config(0));
      expect(await host.isModelLoaded(), isTrue);
      expect(runtime.loadedGpuLayers, 0);
      expect(callbacks.progress, isNotEmpty);
      await host.generate(prompt());
      expect(callbacks.errors, isEmpty);
      expect(callbacks.text.toString().trim(), isNotEmpty);
      expect((await host.getContextInfo()).tokensUsed, greaterThan(0));
      await host.clearContext();
      expect((await host.getContextInfo()).tokensUsed, 0);
      callbacks.text.clear();
      await host.generateChat(chatPrompt());
      expect(callbacks.errors, isEmpty);
      expect(callbacks.text.toString().trim(), isNotEmpty);
      final child = await runtime.engine;
      await host.dispose();
      expect(await child.process.exitCode, 0);
      expect(await host.isModelLoaded(), isFalse);
    } finally {
      await runtime.unload();
    }
  }, skip: unavailable, timeout: const Timeout(Duration(minutes: 3)));

  test('bundled Vulkan engine really offloads GGUF weights to the GPU',
      () async {
    final runtime = WindowsLlamaRuntime(executablePath: executable);
    final callbacks = _Callbacks();
    final host = WindowsLlamaHostApi(callbacks, runtime: runtime);
    try {
      final gpu = await host.detectGpu();
      expect(gpu.vulkanSupported, isTrue);
      expect(gpu.deviceLocalMemoryBytes, greaterThan(0));
      await host.loadModel(config(999));
      expect(runtime.loadedGpuLayers, greaterThan(0));
      final buffers = await (await runtime.engine).request('buffers') as List;
      expect(
          buffers.any((b) =>
              (b as Map)['name'].toString().contains('Vulkan') &&
              (b['mb'] as num) > 0),
          isTrue);
      await host.generate(prompt());
      expect(callbacks.errors, isEmpty);
      expect(callbacks.text.toString().trim(), isNotEmpty);
    } finally {
      await runtime.unload();
    }
  }, skip: unavailable, timeout: const Timeout(Duration(minutes: 3)));

  test('generation can be cancelled and native load errors are surfaced',
      () async {
    final runtime = WindowsLlamaRuntime(executablePath: executable);
    final callbacks = _Callbacks();
    final host = WindowsLlamaHostApi(callbacks, runtime: runtime);
    try {
      final invalid = config(0)..modelPath = '${model!}.missing';
      await expectLater(host.loadModel(invalid), throwsStateError);
      expect(await host.isModelLoaded(), isFalse);
      await host.loadModel(config(0));
      final generation = host.generate(prompt(maxTokens: 10000));
      await callbacks.firstToken.future.timeout(const Duration(seconds: 30));
      await host.stop();
      await generation.timeout(const Duration(seconds: 5));
      expect(callbacks.errors, isEmpty);
      expect((await host.getContextInfo()).tokensUsed, lessThan(512));
      await host.clearContext();
      expect((await host.getContextInfo()).tokensUsed, 0);
    } finally {
      await runtime.unload();
    }
  }, skip: unavailable, timeout: const Timeout(Duration(minutes: 3)));

  for (final useGpu in [true, false]) {
    test(
        'Windows master generates with real layers on a ${useGpu ? 'GPU' : 'RAM'} Windows RPC worker',
        () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close();
      final worker = WindowsLlamaRuntime(executablePath: executable);
      final master = WindowsLlamaRuntime(executablePath: executable);
      final callbacks = _Callbacks();
      final host = WindowsLlamaHostApi(callbacks, runtime: master);
      try {
        await worker.startWorker(port: port, threads: 2, useGpu: useGpu);
        final status = await worker.workerStatus();
        expect(status['state'], 'running');
        expect(status['memoryBackend'], useGpu ? 'gpu' : 'ram');
        final info = await master.info();
        final expectedCapacity = useGpu
            ? ((info['gpuFreeBytes'] as num) * 0.85 - 512 * 1024 * 1024) /
                (1024 * 1024)
            : (info['freeRamBytes'] as num) / (1024 * 1024);
        expect(status['ramMb'], greaterThan(0));
        expect(status['ramMb'], closeTo(expectedCapacity, 512));
        final discovered = await WindowsMdns.discover(
          timeout: const Duration(seconds: 2),
        );
        final advertised =
            discovered.singleWhere((entry) => entry['port'] == port);
        expect(advertised['ramMb'], closeTo(expectedCapacity, 512));
        await master.setCluster(['127.0.0.1:$port'], [1], 1);
        for (final gpuLayers in [0, 999]) {
          await host.loadModel(config(gpuLayers));
          final buffers =
              await (await master.engine).request('buffers') as List;
          expect(
              buffers.any((b) =>
                  (b as Map)['name'].toString().contains('127.0.0.1:$port') &&
                  (b['mb'] as num) > 0),
              isTrue);
          if (gpuLayers > 0) {
            expect(master.loadedGpuLayers, greaterThan(0));
            expect(
                buffers.any((b) =>
                    (b as Map)['name'].toString().contains('Vulkan') &&
                    (b['mb'] as num) > 0),
                isTrue);
          }
          callbacks.text.clear();
          await host.generateChat(chatPrompt());
          expect(callbacks.errors, isEmpty);
          expect(callbacks.text.toString().trim(), isNotEmpty);
          expect((await worker.workerStatus())['peer'], '127.0.0.1');
          await master.unload();
        }
        await worker.stopWorker();
        expect((await worker.workerStatus())['state'], 'stopped');
        expect(await WindowsLlamaRuntime.probe('127.0.0.1:$port'), isFalse);
      } finally {
        await master.unload();
        await worker.stopWorker();
        await worker.unload();
      }
    }, skip: unavailable, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('native children exit automatically if their owning app dies', () async {
    final parent = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Sleep -Seconds 30',
    ]);
    Process? child;
    try {
      child = await Process.start(executable!, ['--parent', '${parent.pid}']);
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      parent.kill();
      await parent.exitCode;
      expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
    } finally {
      parent.kill();
      child?.kill();
    }
  }, skip: unavailable, timeout: const Timeout(Duration(seconds: 15)));
}
