import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'sd_flutter_android_method_channel.dart';

abstract class SdFlutterAndroidPlatform extends PlatformInterface {
  /// Constructs a SdFlutterAndroidPlatform.
  SdFlutterAndroidPlatform() : super(token: _token);

  static final Object _token = Object();

  static SdFlutterAndroidPlatform _instance = MethodChannelSdFlutterAndroid();

  /// The default instance of [SdFlutterAndroidPlatform] to use.
  ///
  /// Defaults to [MethodChannelSdFlutterAndroid].
  static SdFlutterAndroidPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [SdFlutterAndroidPlatform] when
  /// they register themselves.
  static set instance(SdFlutterAndroidPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
