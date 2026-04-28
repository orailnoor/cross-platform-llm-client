import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sd_flutter_android/sd_flutter_android_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelSdFlutterAndroid platform = MethodChannelSdFlutterAndroid();
  const MethodChannel channel = MethodChannel('sd_flutter_android');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}
