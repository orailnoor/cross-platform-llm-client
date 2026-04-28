import 'dart:async';
import 'package:flutter/services.dart';

class SdFlutterAndroid {
  static const MethodChannel _channel = MethodChannel('sd_flutter_android');

  static StreamController<Map<String, int>>? _progressController;

  Future<String?> getPlatformVersion() {
    return _channel.invokeMethod<String>('getPlatformVersion');
  }

  static Future<bool> initModel(String path) async {
    final success = await _channel.invokeMethod<bool>('initModel', {'path': path});
    return success ?? false;
  }

  static Function(int step, int total)? _onProgress;

  static void _ensureInitialized() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final step = call.arguments['step'] as int;
        final total = call.arguments['total'] as int;
        _onProgress?.call(step, total);
      }
    });
  }

  static Future<Uint8List?> generateImage(String prompt, {int steps = 20, Function(int step, int total)? onProgress}) async {
    _ensureInitialized();
    _onProgress = onProgress;

    final bytes = await _channel.invokeMethod<Uint8List>('generateImage', {
      'prompt': prompt,
      'steps': steps,
    });
    return bytes;
  }

  static Future<void> unloadModel() async {
    await _channel.invokeMethod('unloadModel');
  }
}
