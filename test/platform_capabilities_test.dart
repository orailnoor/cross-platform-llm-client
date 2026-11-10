import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/platform_capabilities.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows supports local GGUF without mobile-only plugins', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(PlatformCapabilities.isWindows, isTrue);
    expect(PlatformCapabilities.supportsLocalInference, isTrue);
    expect(PlatformCapabilities.supportsLocalImageGeneration, isFalse);
    expect(PlatformCapabilities.supportsModelHosting, isFalse);
    expect(PlatformCapabilities.supportsCameraCapture, isFalse);
    expect(PlatformCapabilities.supportsSpeechRecognition, isFalse);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform retains on-device inference, camera, and speech', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(PlatformCapabilities.isWindows, isFalse);
      expect(PlatformCapabilities.supportsLocalInference, isTrue);
      expect(PlatformCapabilities.supportsModelHosting, isTrue);
      expect(PlatformCapabilities.supportsCameraCapture, isTrue);
      expect(PlatformCapabilities.supportsSpeechRecognition, isTrue);
    });
  }
}
