import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'app_log_service.dart';

/// Stub crash-reporting service – Firebase is disabled.
/// All public methods are no-ops so callers don't need changes.
class CrashReportingService extends GetxService {
  bool _enabled = false;

  bool get isEnabled => _enabled;

  Future<CrashReportingService> init() async {
    _enabled = false;
    // ignore: avoid_print
    print('[CrashReporting] Disabled – Firebase packages removed');
    return this;
  }

  Future<void> recordFlutterFatal(FlutterErrorDetails details) async {}

  Future<void> recordFatal(Object error, StackTrace stack,
      {String reason = 'fatal'}) async {}

  Future<void> recordNonFatal(
    Object error, {
    StackTrace? stack,
    String reason = 'nonfatal',
    Map<String, Object?> extra = const {},
  }) async {}

  void log(String message) {}

  Future<void> updateContext({
    String reason = 'context',
    Map<String, Object?> extra = const {},
  }) async {}
}
