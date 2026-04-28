import 'package:flutter_test/flutter_test.dart';
import 'package:sd_flutter_android/sd_flutter_android.dart';
import 'package:sd_flutter_android/sd_flutter_android_platform_interface.dart';
import 'package:sd_flutter_android/sd_flutter_android_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockSdFlutterAndroidPlatform
    with MockPlatformInterfaceMixin
    implements SdFlutterAndroidPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final SdFlutterAndroidPlatform initialPlatform = SdFlutterAndroidPlatform.instance;

  test('$MethodChannelSdFlutterAndroid is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelSdFlutterAndroid>());
  });

  test('getPlatformVersion', () async {
    SdFlutterAndroid sdFlutterAndroidPlugin = SdFlutterAndroid();
    MockSdFlutterAndroidPlatform fakePlatform = MockSdFlutterAndroidPlatform();
    SdFlutterAndroidPlatform.instance = fakePlatform;

    expect(await sdFlutterAndroidPlugin.getPlatformVersion(), '42');
  });
}
