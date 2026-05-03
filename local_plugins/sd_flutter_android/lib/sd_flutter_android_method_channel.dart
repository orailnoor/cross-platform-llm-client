import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sd_flutter_android_platform_interface.dart';

/// An implementation of [SdFlutterAndroidPlatform] that uses method channels.
class MethodChannelSdFlutterAndroid extends SdFlutterAndroidPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('sd_flutter_android');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
