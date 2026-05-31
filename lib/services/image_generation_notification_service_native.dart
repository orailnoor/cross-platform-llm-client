import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class ImageGenerationNotificationService {
  static const int _progressNotificationId = 4201;
  static const int _foregroundNotificationId = 4202;
  static const String _channelId = 'image_generation_progress';
  static const String _channelName = 'Image generation';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _notifications.initialize(settings);
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: 'Progress updates for local image generation',
            importance: Importance.low,
          ),
        );
    _initialized = true;
  }

  Future<void> configureBackgroundService() async {
    if (!Platform.isAndroid) return;
    await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
        onStart: imageGenerationBackgroundStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'Image generation running',
        initialNotificationContent:
            'You can leave the app. We will notify you when it finishes.',
        foregroundServiceNotificationId: _foregroundNotificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
  }

  Future<void> ensurePermission() async {
    if (!Platform.isAndroid) return;
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await Permission.notification.request();
    await Permission.ignoreBatteryOptimizations.request();
  }

  Future<void> start({
    required String modelName,
    required String backend,
    required int steps,
    required String sizeLabel,
  }) async {
    if (!Platform.isAndroid) return;
    await init();
    await ensurePermission();
    final details =
        '$backend · $sizeLabel · $steps ${steps == 1 ? "step" : "steps"}';
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('progress', {'content': details});
    await _showProgress(
      title: 'Image generation running',
      body: '0% · Step 0 of $steps',
      progress: 0,
      maxProgress: steps <= 0 ? 100 : steps,
      indeterminate: steps <= 0,
    );
  }

  Future<void> update({
    required int step,
    required int total,
    required int etaSeconds,
    required int elapsedSeconds,
  }) async {
    if (!Platform.isAndroid) return;
    final percent = total > 0 ? ((step / total) * 100).clamp(0, 100).round() : 0;
    final eta = etaSeconds > 0 ? ' · ~${_formatEta(etaSeconds)} left' : '';
    final elapsed = ' · ${_formatEta(elapsedSeconds)} elapsed';
    final body = total > 0
        ? '$percent% · Step $step of $total$elapsed$eta'
        : 'Working$elapsed';
    FlutterBackgroundService().invoke('progress', {'content': body});
    await _showProgress(
      title: 'Image generation running',
      body: body,
      progress: total > 0 ? step.clamp(0, total).toInt() : 0,
      maxProgress: total <= 0 ? 100 : total,
      indeterminate: total <= 0,
    );
  }

  Future<void> decoding() async {
    if (!Platform.isAndroid) return;
    FlutterBackgroundService().invoke('progress', {'content': 'Decoding image...'});
    await _showProgress(
      title: 'Finishing image',
      body: 'Decoding image...',
      progress: 100,
      maxProgress: 100,
      indeterminate: true,
    );
  }

  Future<void> complete({required int durationMs}) async {
    if (!Platform.isAndroid) return;
    await _notifications.show(
      _progressNotificationId,
      'Image ready',
      'Generation finished in ${_formatDuration(durationMs)}.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Progress updates for local image generation',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
        ),
      ),
    );
    FlutterBackgroundService().invoke('stopService');
  }

  Future<void> failed() async {
    if (!Platform.isAndroid) return;
    await _notifications.show(
      _progressNotificationId,
      'Image generation failed',
      'Open PrivateLM to check the error and try again.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Progress updates for local image generation',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
        ),
      ),
    );
    FlutterBackgroundService().invoke('stopService');
  }

  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    await _notifications.cancel(_progressNotificationId);
    await _notifications.cancel(_foregroundNotificationId);
    FlutterBackgroundService().invoke('stopService');
  }

  Future<void> _showProgress({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
    required bool indeterminate,
  }) async {
    await _notifications.show(
      _foregroundNotificationId,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Progress updates for local image generation',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          indeterminate: indeterminate,
        ),
      ),
    );
  }

  String _formatEta(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }

  String _formatDuration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '${minutes}m' : '${minutes}m ${rest}s';
  }
}

@pragma('vm:entry-point')
void imageGenerationBackgroundStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    service.on('progress').listen((event) {
      final content = event?['content'] as String? ??
          'You can leave the app. We will notify you when it finishes.';
      service.setForegroundNotificationInfo(
        title: 'Image generation running',
        content: content,
      );
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}
