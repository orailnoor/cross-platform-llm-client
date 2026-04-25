import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'llama_flutter_android_method_channel.dart';

abstract class LlamaFlutterAndroidPlatform extends PlatformInterface {
  /// Constructs a LlamaFlutterAndroidPlatform.
  LlamaFlutterAndroidPlatform() : super(token: _token);

  static final Object _token = Object();

  static LlamaFlutterAndroidPlatform _instance = MethodChannelLlamaFlutterAndroid();

  /// The default instance of [LlamaFlutterAndroidPlatform] to use.
  ///
  /// Defaults to [MethodChannelLlamaFlutterAndroid].
  static LlamaFlutterAndroidPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [LlamaFlutterAndroidPlatform] when
  /// they register themselves.
  static set instance(LlamaFlutterAndroidPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
