import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/sd_ffi_bindings.dart';

class ProgressUpdate {
  final int step;
  final int totalSteps;
  final double time;
  ProgressUpdate(this.step, this.totalSteps, this.time);
}

class LogMessage {
  final int level;
  final String message;
  LogMessage(this.level, this.message);
}

class GenerationResult {
  final Uint8List? rgbBytes;
  final int width;
  final int height;
  final String? error;
  GenerationResult(
      {this.rgbBytes, this.width = 0, this.height = 0, this.error});
}

/// Isolate-based Stable Diffusion processor.
/// Pattern adapted from Local-Diffusion (https://github.com/rmatif/Local-Diffusion)
class SdIsolateProcessor {
  final String modelPath;
  final int nThreads;
  final bool flashAttn;
  final bool vaeTiling;
  final String? taesdPath;
  final String? vaePath;
  final String? clipLPath;
  final Backend backend;
  final QuantizationType quantizationType;
  final bool offloadParamsToCpu;
  final bool enableMmap;
  final bool keepVaeOnCpu;
  final double maxVram;

  Isolate? _isolate;
  SendPort? _sendPort;
  final _receivePort = ReceivePort();
  final _initCompleter = Completer<void>();
  final _modelLoadedCompleter = Completer<bool>();
  bool _disposed = false;

  Future<bool> get modelLoaded => _modelLoadedCompleter.future;

  final _progressController = StreamController<ProgressUpdate>.broadcast();
  final _logController = StreamController<LogMessage>.broadcast();

  Stream<ProgressUpdate> get progressStream => _progressController.stream;
  Stream<LogMessage> get logStream => _logController.stream;

  SdIsolateProcessor({
    required this.modelPath,
    this.nThreads = 0,
    this.flashAttn = false,
    this.vaeTiling = false,
    this.taesdPath,
    this.vaePath,
    this.clipLPath,
    this.backend = Backend.cpu,
    this.quantizationType = QuantizationType.f16,
    this.offloadParamsToCpu = false,
    this.enableMmap = false,
    this.keepVaeOnCpu = false,
    this.maxVram = 0.0,
  }) {
    _spawnIsolate();
  }

  Future<void> _spawnIsolate() async {
    try {
      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        {
          'port': _receivePort.sendPort,
          'modelPath': modelPath,
          'nThreads': nThreads,
          'flashAttn': flashAttn,
          'vaeTiling': vaeTiling,
          'taesdPath': taesdPath,
          'vaePath': vaePath,
          'clipLPath': clipLPath,
          'backend': backend.index,
          'quantizationType': quantizationType.nativeValue,
          'offloadParamsToCpu': offloadParamsToCpu,
          'enableMmap': enableMmap,
          'keepVaeOnCpu': keepVaeOnCpu,
          'maxVram': maxVram,
        },
      );

      _receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _initCompleter.complete();
          return;
        }
        if (message is Map) {
          switch (message['type']) {
            case 'progress':
              _progressController.add(ProgressUpdate(
                message['step'],
                message['steps'],
                (message['time'] as num).toDouble(),
              ));
              break;
            case 'log':
              _logController.add(LogMessage(
                message['level'],
                message['message'],
              ));
              break;
            case 'result':
              _handleResult(message);
              break;
            case 'modelLoaded':
              if (!_modelLoadedCompleter.isCompleted) {
                _modelLoadedCompleter.complete(true);
              }
              break;
            case 'error':
              _handleError(message['message']);
              break;
          }
        }
      });
    } catch (e) {
      print('[SdIsolateProcessor] Isolate.spawn failed: $e');
      if (!_modelLoadedCompleter.isCompleted) {
        _modelLoadedCompleter.complete(false);
      }
      final completer = _activeCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(GenerationResult(error: 'Isolate.spawn failed: $e'));
      }
    }
  }

  void _handleResult(Map message) {
    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) {
      print('[MainIsolate] _handleResult: completer already completed or null');
      return;
    }

    final error = message['error'] as String?;
    if (error != null) {
      print('[MainIsolate] _handleResult: completing with error: $error');
      completer.complete(GenerationResult(error: error));
      return;
    }

    final bytes = message['bytes'] as Uint8List?;
    final width = (message['width'] as num?)?.toInt() ?? 0;
    final height = (message['height'] as num?)?.toInt() ?? 0;
    print(
        '[MainIsolate] _handleResult: completing with image ${width}x$height, ${bytes?.length} bytes');
    completer.complete(GenerationResult(
      rgbBytes: bytes,
      width: width,
      height: height,
    ));
  }

  void _handleError(String error) {
    if (!_modelLoadedCompleter.isCompleted) {
      _modelLoadedCompleter.complete(false);
    }
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(GenerationResult(error: error));
    }
  }

  Completer<GenerationResult>? _activeCompleter;

  Future<GenerationResult> generate({
    required String prompt,
    String negativePrompt = '',
    int width = 384,
    int height = 384,
    int steps = 4,
    int seed = -1,
    double cfgScale = 7.0,
    SampleMethod sampleMethod = SampleMethod.eulerA,
    Schedule schedule = Schedule.discrete,
    bool vaeTiling = false,
  }) async {
    if (_disposed) {
      return GenerationResult(error: 'Processor is disposed');
    }
    await _initCompleter.future;

    final modelLoaded = await _modelLoadedCompleter.future;
    if (!modelLoaded) {
      return GenerationResult(error: 'Model failed to load');
    }

    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      return GenerationResult(error: 'Generation already in progress');
    }

    _activeCompleter = Completer<GenerationResult>();

    _sendPort!.send({
      'command': 'generate',
      'prompt': prompt,
      'negativePrompt': negativePrompt,
      'width': width,
      'height': height,
      'steps': steps,
      'seed': seed,
      'cfgScale': cfgScale,
      'sampleMethod': sampleMethod.index,
      'schedule': schedule.index,
      'vaeTiling': vaeTiling,
    });

    return _activeCompleter!.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _initCompleter.future;
    _sendPort?.send({'command': 'dispose'});

    // Give isolate time to clean up
    await Future.delayed(const Duration(milliseconds: 200));

    _receivePort.close();
    _progressController.close();
    _logController.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  // =========================================================================
  // Isolate entry point
  // =========================================================================

  static void _isolateEntryPoint(Map<String, dynamic> args) {
    final mainSendPort = args['port'] as SendPort;
    final backendIndex = args['backend'] as int? ?? 0;
    final backend = Backend.values[backendIndex];

    // Initialize FFI inside the isolate with selected backend
    try {
      SdFfiBindings.initialize(backend);
    } catch (e) {
      mainSendPort.send({
        'type': 'error',
        'message': 'Failed to load ${backend.displayName}: $e',
      });
      return;
    }

    // Setup callbacks that post back to main isolate
    final isolateReceivePort = ReceivePort();
    mainSendPort.send(isolateReceivePort.sendPort);

    SdFfiBindings.setupCallbacks(mainSendPort);

    Pointer<Void>? ctx;

    isolateReceivePort.listen((message) {
      if (message is! Map) return;

      switch (message['command']) {
        case 'generate':
          _runGeneration(mainSendPort, ctx, message);
          break;
        case 'dispose':
          final currentCtx = ctx;
          if (currentCtx != null && currentCtx.address != 0) {
            SdFfiBindings.freeCtx(currentCtx);
            ctx = null;
          }
          SdFfiBindings.clearCallbacks();
          isolateReceivePort.close();
          mainSendPort.send({'type': 'disposed'});
          break;
      }
    });

    // Initialize model
    final modelPath = args['modelPath'] as String;
    final nThreads = args['nThreads'] as int;
    final flashAttn = args['flashAttn'] as bool;
    final vaeTiling = args['vaeTiling'] as bool;
    final taesdPath = args['taesdPath'] as String?;
    final vaePath = args['vaePath'] as String?;
    final clipLPath = args['clipLPath'] as String?;
    final wtype = args['quantizationType'] as int? ?? 1; // default FP16
    final offloadParamsToCpu = args['offloadParamsToCpu'] as bool? ?? false;
    final enableMmap = args['enableMmap'] as bool? ?? false;
    final keepVaeOnCpu = args['keepVaeOnCpu'] as bool? ?? false;
    final maxVram = (args['maxVram'] as num?)?.toDouble() ?? 0.0;

    final pathPtr = modelPath.toNativeUtf8();
    final taesdPtr = (taesdPath != null && taesdPath.isNotEmpty)
        ? taesdPath.toNativeUtf8()
        : nullptr;
    final vaePtr = (vaePath != null && vaePath.isNotEmpty)
        ? vaePath.toNativeUtf8()
        : nullptr;
    final clipLPtr = (clipLPath != null && clipLPath.isNotEmpty)
        ? clipLPath.toNativeUtf8()
        : nullptr;
    try {
      final newCtx = SdFfiBindings.initEx(
        pathPtr,
        nThreads,
        flashAttn,
        vaeTiling,
        taesdPtr,
        vaePtr,
        clipLPtr,
        wtype,
        backendIndex,
        offloadParamsToCpu,
        enableMmap,
        keepVaeOnCpu,
        maxVram,
      );
      if (newCtx.address == 0) {
        ctx = null;
        mainSendPort.send({
          'type': 'error',
          'message': 'Failed to initialize model context',
        });
      } else {
        ctx = newCtx;
        mainSendPort.send({'type': 'modelLoaded'});
      }
    } catch (e) {
      ctx = null;
      mainSendPort.send({
        'type': 'error',
        'message': 'Failed to initialize ${backend.displayName}: $e',
      });
    } finally {
      calloc.free(pathPtr);
      if (taesdPtr != nullptr) calloc.free(taesdPtr);
      if (vaePtr != nullptr) calloc.free(vaePtr);
      if (clipLPtr != nullptr) calloc.free(clipLPtr);
    }
  }

  static void _runGeneration(
    SendPort mainSendPort,
    Pointer<Void>? ctx,
    Map message,
  ) {
    if (ctx == null || ctx.address == 0) {
      print('[Isolate] ERROR: Model not initialized');
      mainSendPort.send({
        'type': 'error',
        'message': 'Model not initialized',
      });
      return;
    }

    final prompt = message['prompt'] as String;
    final negativePrompt = message['negativePrompt'] as String;
    final width = message['width'] as int;
    final height = message['height'] as int;
    final steps = message['steps'] as int;
    final seed = message['seed'] as int;
    final cfgScale = (message['cfgScale'] as num).toDouble();
    final sampleMethod = message['sampleMethod'] as int;
    final schedule = message['schedule'] as int;
    final vaeTiling = message['vaeTiling'] as bool;

    print(
        '[Isolate] _runGeneration started: prompt="$prompt", ${width}x$height, steps=$steps, seed=$seed');

    final promptPtr = prompt.toNativeUtf8();
    final negPtr = negativePrompt.toNativeUtf8();
    final outSizePtr = calloc<IntPtr>(1);

    try {
      print('[Isolate] Calling FFI generate()...');
      final resultPtr = SdFfiBindings.generate(
        ctx,
        promptPtr,
        negPtr,
        width,
        height,
        steps,
        seed,
        cfgScale,
        sampleMethod,
        schedule,
        vaeTiling,
        outSizePtr,
      );
      print(
          '[Isolate] FFI generate() returned, resultPtr=${resultPtr.address}');

      final outSize = outSizePtr.value;
      print('[Isolate] outSize=$outSize');

      if (resultPtr.address == 0 || outSize == 0) {
        print('[Isolate] ERROR: null result or zero size');
        mainSendPort.send({
          'type': 'result',
          'error': 'Image generation failed (null result)',
        });
        return;
      }

      print('[Isolate] Copying $outSize bytes from native buffer...');
      // Copy native bytes into Dart-managed Uint8List
      final rgbBytes = Uint8List.fromList(
        resultPtr.asTypedList(outSize),
      );
      print('[Isolate] Copied ${rgbBytes.length} bytes');

      // Free native buffer
      calloc.free(resultPtr);

      print('[Isolate] Sending result to main isolate');
      mainSendPort.send({
        'type': 'result',
        'bytes': rgbBytes,
        'width': width,
        'height': height,
      });
      print('[Isolate] Result sent');
    } catch (e, stack) {
      print('[Isolate] EXCEPTION: $e');
      print('[Isolate] STACK: $stack');
      mainSendPort.send({
        'type': 'result',
        'error': 'Generation exception: $e',
      });
    } finally {
      calloc.free(promptPtr);
      calloc.free(negPtr);
      calloc.free(outSizePtr);
      print('[Isolate] _runGeneration finished');
    }
  }
}
