/// Web stub for ImageGenerationNotificationService.
/// Notifications and background services are not available on web.
class ImageGenerationNotificationService {
  Future<void> init() async {}
  Future<void> configureBackgroundService() async {}
  Future<void> ensurePermission() async {}
  Future<void> start({
    required String modelName,
    required String backend,
    required int steps,
    required String sizeLabel,
  }) async {}
  Future<void> update({
    required int step,
    required int total,
    required int etaSeconds,
    required int elapsedSeconds,
  }) async {}
  Future<void> decoding() async {}
  Future<void> complete({required int durationMs}) async {}
  Future<void> failed() async {}
  Future<void> cancel() async {}
}
