import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show LlamaExt;

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

  /// Off by default. When on, the server never asks for an API key — also
  /// when other devices on the network can reach it (like OlliteRT).
  final noApiKey = false.obs;

  late final TextEditingController apiKeyCtrl;

  /// Port of the API server (setting server_port, default 8080).
  static int get port =>
      (Get.isRegistered<HiveService>()
              ? Get.find<HiveService>().getSetting<int>(AppConstants.keyServerPort)
              : null) ??
      AppConstants.defaultServerPort;

  @override
  void onInit() {
    super.onInit();
    useApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerUseApiKey) ?? false;
    apiKey.value = _hive.getSetting<String>(AppConstants.keyServerApiKey) ?? '';
    allowNetwork.value =
        _hive.getSetting<bool>(AppConstants.keyServerAllowNetwork) ?? false;
    noApiKey.value =
        _hive.getSetting<bool>(AppConstants.keyServerNoApiKey) ?? false;

    apiKeyCtrl = TextEditingController(text: apiKey.value);
  }

  bool get requiresApiKey =>
      !noApiKey.value && (allowNetwork.value || useApiKey.value);

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

  /// [silent]: started by the app itself (start on launch/boot), so no
  /// toasts. A model unloaded by keep-alive counts as loaded (it reloads on
  /// the next request).
  Future<void> startServer({bool silent = false}) async {
    if (isRunning.value || isStarting.value) return;
    lastError.value = null;
    if (!hasLocalModel && !inference.isIdleUnloaded) {
      lastError.value = 'Load a local GGUF or LiteRT-LM model first.';
      if (!silent) {
        showToast('Server not started', lastError.value!,
            tone: ToastTone.warning);
      }
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
        allowNoKey: noApiKey.value,
        onLog: (message) => serverStatus.value = message,
      );
      localUrl.value = _server.localUrl;
      isRunning.value = true;
      serverStatus.value = 'Server running';
      await _setKeepAwake(true);
      if (allowNetwork.value && Get.isRegistered<ClusterService>()) {
        Get.find<ClusterService>().serving.value = true;
      }
    } catch (e) {
      lastError.value = '$e';
      serverStatus.value = 'Server failed';
      Get.find<AppLogService>().error('API server failed', details: e);
      if (!silent) showToast('Server failed', '$e', tone: ToastTone.error);
    } finally {
      isStarting.value = false;
    }
  }

  Future<void> stopServer() async {
    isStarting.value = false;
    await _server.stop();
    await _setKeepAwake(false);
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
    if (!enabled && allowNetwork.value && !noApiKey.value) return;
    useApiKey.value = enabled;
    await saveSettings();
  }

  /// "No API key": serve without authentication, even on the network.
  Future<void> setNoApiKey(bool enabled) async {
    noApiKey.value = enabled;
    await _hive.setSetting(AppConstants.keyServerNoApiKey, enabled);
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

  /// Foreground service + partial wake lock + high-performance Wi-Fi lock
  /// while the server runs (setting server_keep_awake, off by default).
  Future<void> _setKeepAwake(bool on) async {
    if (!GetPlatform.isAndroid) return;
    final enabled =
        _hive.getSetting<bool>(AppConstants.keyServerKeepAwake) ?? false;
    if (on && !enabled) return;
    try {
      await LlamaExt.keepAwake(on,
          title: 'PrivateLM API server running',
          text: localUrl.value ?? 'http://localhost:$port');
    } catch (e) {
      Get.find<AppLogService>().warning('Keep-awake failed', details: e);
    }
  }

  /// Re-applies the keep-awake setting to a running server.
  Future<void> refreshKeepAwake() async {
    if (!isRunning.value) return;
    final enabled =
        _hive.getSetting<bool>(AppConstants.keyServerKeepAwake) ?? false;
    await _setKeepAwake(enabled);
  }

  /// Restarts a running server (port or bind address changed).
  Future<void> restartIfRunning() async {
    if (!isRunning.value) return;
    await stopServer();
    await startServer();
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
