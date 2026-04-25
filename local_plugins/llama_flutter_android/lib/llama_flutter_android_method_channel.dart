import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'llama_flutter_android_platform_interface.dart';

/// An implementation of [LlamaFlutterAndroidPlatform] that uses method channels.
class MethodChannelLlamaFlutterAndroid extends LlamaFlutterAndroidPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('llama_flutter_android');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
