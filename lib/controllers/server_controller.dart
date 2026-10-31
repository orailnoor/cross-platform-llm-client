import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import '../services/app_log_service.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cluster_service.dart';
import '../services/openai_server_service.dart';

class ServerController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final InferenceService inference = Get.find<InferenceService>();
  final OpenAiServerService _server = OpenAiServerService();

  final isRunning = false.obs;
  final isStarting = false.obs;
  final localUrl = RxnString();
  final serverStatus = 'Server stopped'.obs;
  final lastError = RxnString();

  final useApiKey = false.obs;
  final apiKey = ''.obs;

  /// Off by default: the server only listens on this device. When on, other
  /// devices on the network can reach it and an API key is always required.
  final allowNetwork = false.obs;

  late final TextEditingController apiKeyCtrl;

  static const int port = 8080;

  @override
  void onInit() {
    super.onInit();
    useApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseApiKey) ?? false;
    apiKey.value = _hive.getSetting<String>(AppConstants.keyServerApiKey) ?? '';
    allowNetwork.value =
        _hive.getSetting<bool>(AppConstants.keyServerAllowNetwork) ?? false;

    apiKeyCtrl = TextEditingController(text: apiKey.value);
  }

  bool get requiresApiKey => allowNetwork.value || useApiKey.value;

  String? get _effectiveApiKey {
    final key = apiKey.value.trim();
    return requiresApiKey && key.isNotEmpty ? key : null;
  }

  bool get hasLocalModel => inference.isModelLoaded.value;

  String get modelName => inference.loadedModelName.value.isEmpty
      ? 'No model loaded'
      : inference.loadedModelName.value;

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
    if (!hasLocalModel) {
      lastError.value = 'Load a local GGUF or LiteRT-LM model first.';
      showToast('Server not started', lastError.value!,
          tone: ToastTone.warning);
      return;
    }

    isStarting.value = true;
    serverStatus.value = 'Starting server...';
    await saveSettings();

    try {
      await _server.start(
        port: port,
        apiKey: _effectiveApiKey,
        allowNetwork: allowNetwork.value,
        onLog: (message) => serverStatus.value = message,
      );
      localUrl.value = _server.localUrl;
      isRunning.value = true;
      serverStatus.value = 'Server running';
      if (allowNetwork.value && Get.isRegistered<ClusterService>()) {
        Get.find<ClusterService>().serving.value = true;
      }
    } catch (e) {
      lastError.value = '$e';
      serverStatus.value = 'Server failed';
      Get.find<AppLogService>().error('API server failed', details: e);
      showToast('Server failed', '$e', tone: ToastTone.error);
    } finally {
      isStarting.value = false;
    }
  }

  Future<void> stopServer() async {
    isStarting.value = false;
    await _server.stop();
    isRunning.value = false;
    localUrl.value = null;
    serverStatus.value = 'Server stopped';
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().serving.value = false;
    }
  }

  /// Persists settings and applies the key to a running server. A required
  /// but empty key is replaced with a generated one so auth is never
  /// silently disabled.
  Future<void> saveSettings() async {
    if (requiresApiKey && apiKey.value.trim().isEmpty) {
      _setApiKey(_newApiKey());
    }
    await _hive.setSetting(AppConstants.keyServerUseApiKey, useApiKey.value);
    await _hive.setSetting(AppConstants.keyServerApiKey, apiKey.value.trim());
    await _hive.setSetting(
        AppConstants.keyServerAllowNetwork, allowNetwork.value);
    _server.updateApiKey(_effectiveApiKey);
  }

  Future<void> setUseApiKey(bool enabled) async {
    if (!enabled && allowNetwork.value) return;
    useApiKey.value = enabled;
    await saveSettings();
  }

  Future<void> setAllowNetwork(bool enabled) async {
    allowNetwork.value = enabled;
    await saveSettings();
    if (isRunning.value) {
      // Switching between loopback and all interfaces needs a rebind.
      await stopServer();
      await startServer();
    }
  }

  void onApiKeyEdited(String value) {
    apiKey.value = value;
    // Don't push an empty key while one is required; saveSettings will
    // generate a replacement when the field is submitted.
    if (!requiresApiKey || value.trim().isNotEmpty) {
      _server.updateApiKey(_effectiveApiKey);
    }
  }

  Future<void> generateApiKey() async {
    _setApiKey(_newApiKey());
    useApiKey.value = true;
    await saveSettings();
  }

  void _setApiKey(String key) {
    apiKey.value = key;
    apiKeyCtrl.text = key;
  }

  String _newApiKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return 'aichat_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    showToast('Copied', '$label copied.', tone: ToastTone.success);
  }

  String get baseUrl => localUrl.value ?? 'http://localhost:$port';

  String get openAiBaseUrl => '$baseUrl/v1';

  @override
  void onClose() {
    apiKeyCtrl.dispose();
    unawaited(stopServer());
    super.onClose();
  }
}
