import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../core/constants.dart';
import '../services/app_log_service.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/openai_server_service.dart';
import '../services/tunnel_service.dart';

class ServerController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final InferenceService inference = Get.find<InferenceService>();
  final OpenAiServerService _server = OpenAiServerService();
  final TunnelService _tunnel = TunnelService();

  final isRunning = false.obs;
  final isStarting = false.obs;
  final isTunnelStarting = false.obs;
  final localUrl = RxnString();
  final publicUrl = RxnString();
  final serverStatus = 'Server stopped'.obs;
  final tunnelStatus = 'Tunnel stopped'.obs;
  final lastError = RxnString();

  final useApiKey = false.obs;
  final apiKey = ''.obs;
  final useTunnel = false.obs;
  final tunnelProvider = 'cloudflare'.obs;
  final cloudflareToken = ''.obs;
  final cloudflarePublicUrl = ''.obs;
  final ngrokAuthToken = ''.obs;
  final ngrokDomain = ''.obs;

  static const int port = 8080;

  @override
  void onInit() {
    super.onInit();
    useApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseApiKey) ?? false;
    apiKey.value = _hive.getSetting<String>(AppConstants.keyServerApiKey) ?? '';
    useTunnel.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseTunnel) ?? false;
    tunnelProvider.value =
        _hive.getSetting<String>(AppConstants.keyServerTunnelProvider) ??
            'cloudflare';
    cloudflareToken.value =
        _hive.getSetting<String>(AppConstants.keyServerCloudflareToken) ?? '';
    cloudflarePublicUrl.value =
        _hive.getSetting<String>(AppConstants.keyServerCloudflareUrl) ?? '';
    ngrokAuthToken.value =
        _hive.getSetting<String>(AppConstants.keyServerNgrokToken) ?? '';
    ngrokDomain.value =
        _hive.getSetting<String>(AppConstants.keyServerNgrokDomain) ?? '';
  }

  bool get hasLiteRtModel =>
      inference.isModelLoaded.value &&
      inference.loadedModelRuntime.value == 'litert';

  String get modelName =>
      inference.loadedModelName.value.isEmpty ? 'No model loaded' : inference.loadedModelName.value;

  Future<void> toggleServer(bool enabled) async {
    if (enabled) {
      await startServer();
    } else {
      await stopServer();
    }
  }

  Future<void> startServer() async {
    if (isRunning.value || isStarting.value) return;
    lastError.value = null;
    if (!hasLiteRtModel) {
      lastError.value = 'Load a LiteRT-LM model before starting the server.';
      Get.snackbar('Server not started', lastError.value!);
      return;
    }

    isStarting.value = true;
    serverStatus.value = 'Starting server...';
    await saveSettings();

    try {
      await _server.start(
        port: port,
        apiKey: useApiKey.value ? apiKey.value : null,
        onLog: (message) => serverStatus.value = message,
      );
      localUrl.value = _server.localUrl;
      isRunning.value = true;
      serverStatus.value = 'Server running';

      if (useTunnel.value) {
        await startTunnel();
      }
    } catch (e) {
      lastError.value = '$e';
      serverStatus.value = 'Server failed';
      Get.find<AppLogService>().error('API server failed', details: e);
      Get.snackbar('Server failed', '$e');
    } finally {
      isStarting.value = false;
    }
  }

  Future<void> stopServer() async {
    isStarting.value = false;
    isTunnelStarting.value = false;
    await _tunnel.stop();
    await _server.stop();
    isRunning.value = false;
    localUrl.value = null;
    publicUrl.value = null;
    serverStatus.value = 'Server stopped';
    tunnelStatus.value = 'Tunnel stopped';
  }

  Future<void> startTunnel() async {
    if (!isRunning.value || isTunnelStarting.value) return;
    publicUrl.value = null;
    isTunnelStarting.value = true;
    tunnelStatus.value = 'Starting ${providerLabel.toLowerCase()} tunnel...';
    await saveSettings();
    try {
      final result = await _tunnel.start(
        provider: tunnelProvider.value,
        port: port,
        cloudflareToken: cloudflareToken.value,
        cloudflarePublicUrl: cloudflarePublicUrl.value,
        ngrokAuthToken: ngrokAuthToken.value,
        ngrokDomain: ngrokDomain.value,
      );
      if (result.success && result.publicUrl != null) {
        publicUrl.value = result.publicUrl;
        tunnelStatus.value = 'Tunnel ready';
      } else {
        tunnelStatus.value = 'Tunnel failed';
        lastError.value = result.error ?? 'Tunnel failed to start.';
      }
    } catch (e) {
      tunnelStatus.value = 'Tunnel failed';
      lastError.value = '$e';
    } finally {
      isTunnelStarting.value = false;
    }
  }

  Future<void> stopTunnel() async {
    await _tunnel.stop();
    publicUrl.value = null;
    tunnelStatus.value = 'Tunnel stopped';
  }

  Future<void> saveSettings() async {
    await _hive.setSetting(AppConstants.keyServerUseApiKey, useApiKey.value);
    await _hive.setSetting(AppConstants.keyServerApiKey, apiKey.value.trim());
    await _hive.setSetting(AppConstants.keyServerUseTunnel, useTunnel.value);
    await _hive.setSetting(
        AppConstants.keyServerTunnelProvider, tunnelProvider.value);
    await _hive.setSetting(
        AppConstants.keyServerCloudflareToken, cloudflareToken.value.trim());
    await _hive.setSetting(
        AppConstants.keyServerCloudflareUrl, cloudflarePublicUrl.value.trim());
    await _hive.setSetting(
        AppConstants.keyServerNgrokToken, ngrokAuthToken.value.trim());
    await _hive.setSetting(
        AppConstants.keyServerNgrokDomain, ngrokDomain.value.trim());
  }

  Future<void> generateApiKey() async {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    apiKey.value = 'aichat_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    useApiKey.value = true;
    await saveSettings();
  }

  Future<void> copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    Get.snackbar('Copied', '$label copied.');
  }

  String get providerLabel =>
      tunnelProvider.value == 'ngrok' ? 'ngrok' : 'Cloudflare';

  String get baseUrl => publicUrl.value ?? localUrl.value ?? 'http://localhost:$port';

  String get openAiBaseUrl => '$baseUrl/v1';

  @override
  void onClose() {
    unawaited(stopServer());
    super.onClose();
  }
}
