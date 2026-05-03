import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';

class SettingsController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();

  // Observable settings
  final themeMode = ThemeMode.system.obs;
  final inferenceMode = 'cloud'.obs; // 'local' or 'cloud'
  final cloudProvider = 'kimi'.obs;
  final openaiKey = ''.obs;
  final anthropicKey = ''.obs;
  final googleKey = ''.obs;
  final kimiKey = ''.obs;
  final stabilityKey = ''.obs;
  final nvidiaKey = ''.obs;
  final openaiModel = 'gpt-5.2'.obs;
  final anthropicModel = 'claude-sonnet-4-6'.obs;
  final googleModel = 'gemini-2.5-flash'.obs;
  final kimiModel = 'kimi-k2.6'.obs;
  final stabilityModel = 'sd3.5-flash'.obs;
  final nvidiaModel = 'meta/llama-3.1-8b-instruct'.obs;
  final globalSystemPrompt = AppConstants.systemPrompt.obs;
  final nvidiaModels = <String>[].obs;
  final isLoadingNvidiaModels = false.obs;
  final temperature = 0.1.obs;
  final maxTokens = 512.obs;
  final contextSize = 2048.obs;

  // Persistent text controllers for settings fields
  final openaiKeyController = TextEditingController();
  final anthropicKeyController = TextEditingController();
  final googleKeyController = TextEditingController();
  final kimiKeyController = TextEditingController();
  final stabilityKeyController = TextEditingController();
  final nvidiaKeyController = TextEditingController();
  final globalSystemPromptController = TextEditingController();

  final openaiModelController = TextEditingController();
  final anthropicModelController = TextEditingController();
  final googleModelController = TextEditingController();
  final kimiModelController = TextEditingController();
  final stabilityModelController = TextEditingController();
  final nvidiaModelController = TextEditingController();

  Timer? _apiKeyDebounceTimer;
  Timer? _modelDebounceTimer;

  @override
  void onInit() {
    super.onInit();
    _loadSettings();
  }

  @override
  void onClose() {
    openaiKeyController.dispose();
    anthropicKeyController.dispose();
    googleKeyController.dispose();
    kimiKeyController.dispose();
    stabilityKeyController.dispose();
    nvidiaKeyController.dispose();
    globalSystemPromptController.dispose();
    openaiModelController.dispose();
    anthropicModelController.dispose();
    googleModelController.dispose();
    kimiModelController.dispose();
    stabilityModelController.dispose();
    nvidiaModelController.dispose();
    _apiKeyDebounceTimer?.cancel();
    _modelDebounceTimer?.cancel();
    super.onClose();
  }

  void _loadSettings() {
    final savedTheme = _hive.getSetting<String>('theme_mode');
    themeMode.value = _themeModeFromString(savedTheme);
    inferenceMode.value = _hive.getSetting(AppConstants.keyInferenceMode,
            defaultValue: 'cloud') ??
        'cloud';
    cloudProvider.value =
        _hive.getSetting(AppConstants.keyCloudProvider, defaultValue: 'kimi') ??
            'kimi';
    openaiKey.value = _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    anthropicKey.value = _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
    googleKey.value = _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
    kimiKey.value = _hive.getSetting(AppConstants.keyKimiKey) ?? '';
    stabilityKey.value = _hive.getSetting(AppConstants.keyStabilityKey) ?? '';
    nvidiaKey.value = _hive.getSetting(AppConstants.keyNvidiaKey) ?? '';
    openaiModel.value = _hive.getSetting(AppConstants.keyOpenaiModel,
            defaultValue: 'gpt-5.2') ??
        'gpt-5.2';
    anthropicModel.value = _hive.getSetting(AppConstants.keyAnthropicModel,
            defaultValue: 'claude-sonnet-4-6') ??
        'claude-sonnet-4-6';
    googleModel.value = _hive.getSetting(AppConstants.keyGoogleModel,
            defaultValue: 'gemini-2.5-flash') ??
        'gemini-2.5-flash';
    kimiModel.value = _hive.getSetting(AppConstants.keyKimiModel,
            defaultValue: 'kimi-k2.6') ??
        'kimi-k2.6';
    stabilityModel.value = _hive.getSetting(AppConstants.keyStabilityModel,
            defaultValue: 'sd3.5-flash') ??
        'sd3.5-flash';
    nvidiaModel.value = _hive.getSetting(AppConstants.keyNvidiaModel,
            defaultValue: 'meta/llama-3.1-8b-instruct') ??
        'meta/llama-3.1-8b-instruct';
    globalSystemPrompt.value = _hive.getSetting(
            AppConstants.keyGlobalSystemPrompt,
            defaultValue: AppConstants.systemPrompt) ??
        AppConstants.systemPrompt;
    temperature.value = _hive.getSetting(AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature) ??
        AppConstants.defaultTemperature;
    maxTokens.value = _hive.getSetting(AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens) ??
        AppConstants.defaultMaxTokens;
    contextSize.value = _hive.getSetting(AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize) ??
        AppConstants.defaultContextSize;

    // Sync controllers with loaded values
    openaiKeyController.text = openaiKey.value;
    anthropicKeyController.text = anthropicKey.value;
    googleKeyController.text = googleKey.value;
    kimiKeyController.text = kimiKey.value;
    stabilityKeyController.text = stabilityKey.value;
    nvidiaKeyController.text = nvidiaKey.value;
    globalSystemPromptController.text = globalSystemPrompt.value;

    openaiModelController.text = openaiModel.value;
    anthropicModelController.text = anthropicModel.value;
    googleModelController.text = googleModel.value;
    kimiModelController.text = kimiModel.value;
    stabilityModelController.text = stabilityModel.value;
    nvidiaModelController.text = nvidiaModel.value;
  }

  TextEditingController apiKeyControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicKeyController;
      case 'google':
        return googleKeyController;
      case 'kimi':
        return kimiKeyController;
      case 'stability':
        return stabilityKeyController;
      case 'nvidia':
        return nvidiaKeyController;
      default:
        return openaiKeyController;
    }
  }

  TextEditingController modelControllerFor(String provider) {
    switch (provider) {
      case 'anthropic':
        return anthropicModelController;
      case 'google':
        return googleModelController;
      case 'kimi':
        return kimiModelController;
      case 'stability':
        return stabilityModelController;
      case 'nvidia':
        return nvidiaModelController;
      default:
        return openaiModelController;
    }
  }

  Future<void> setInferenceMode(String mode) async {
    inferenceMode.value = mode;
    await _hive.setSetting(AppConstants.keyInferenceMode, mode);
  }

  Future<void> setCloudProvider(String provider) async {
    cloudProvider.value = provider;
    await _hive.setSetting(AppConstants.keyCloudProvider, provider);
  }

  Future<void> setApiKey(String provider, String key) async {
    final trimmed = key.trim();
    switch (provider) {
      case 'openai':
        openaiKey.value = trimmed;
        openaiKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyOpenaiKey, trimmed);
        break;
      case 'anthropic':
        anthropicKey.value = trimmed;
        anthropicKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyAnthropicKey, trimmed);
        break;
      case 'google':
        googleKey.value = trimmed;
        googleKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyGoogleKey, trimmed);
        break;
      case 'kimi':
        kimiKey.value = trimmed;
        kimiKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyKimiKey, trimmed);
        break;
      case 'stability':
        stabilityKey.value = trimmed;
        stabilityKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyStabilityKey, trimmed);
        break;
      case 'nvidia':
        nvidiaKey.value = trimmed;
        nvidiaKeyController.text = trimmed;
        await _hive.setSetting(AppConstants.keyNvidiaKey, trimmed);
        await refreshNvidiaModels();
        break;
    }
  }

  void debouncedSetApiKey(String provider, String key) {
    _apiKeyDebounceTimer?.cancel();
    _apiKeyDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setApiKey(provider, key);
    });
  }

  void cancelApiKeyDebounce() {
    _apiKeyDebounceTimer?.cancel();
  }

  Future<void> setCloudModel(String provider, String model) async {
    switch (provider) {
      case 'openai':
        openaiModel.value = model;
        openaiModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenaiModel, model);
        break;
      case 'anthropic':
        anthropicModel.value = model;
        anthropicModelController.text = model;
        await _hive.setSetting(AppConstants.keyAnthropicModel, model);
        break;
      case 'google':
        googleModel.value = model;
        googleModelController.text = model;
        await _hive.setSetting(AppConstants.keyGoogleModel, model);
        break;
      case 'kimi':
        kimiModel.value = model;
        kimiModelController.text = model;
        await _hive.setSetting(AppConstants.keyKimiModel, model);
        break;
      case 'stability':
        stabilityModel.value = model;
        stabilityModelController.text = model;
        await _hive.setSetting(AppConstants.keyStabilityModel, model);
        break;
      case 'nvidia':
        nvidiaModel.value = model;
        nvidiaModelController.text = model;
        await _hive.setSetting(AppConstants.keyNvidiaModel, model);
        break;
    }
  }

  Future<void> setGlobalSystemPrompt(String prompt) async {
    final normalized =
        prompt.trim().isEmpty ? AppConstants.systemPrompt : prompt.trim();
    globalSystemPrompt.value = normalized;
    globalSystemPromptController.text = normalized;
    await _hive.setSetting(AppConstants.keyGlobalSystemPrompt, normalized);
  }

  Future<void> refreshNvidiaModels() async {
    if (nvidiaKey.value.trim().isEmpty) return;
    isLoadingNvidiaModels.value = true;
    try {
      final response = await http.get(
        Uri.parse('${AppConstants.nvidiaEndpoint}/models'),
        headers: {'Authorization': 'Bearer ${nvidiaKey.value.trim()}'},
      );
      if (response.statusCode != 200) {
        Get.find<AppLogService>().warning(
          'NVIDIA model list request failed',
          details: '${response.statusCode}: ${response.body}',
        );
        return;
      }
      final data = jsonDecode(response.body);
      final rawModels = data['data'] as List? ?? [];
      nvidiaModels.value = rawModels
          .map((model) => model is Map ? model['id']?.toString() : null)
          .whereType<String>()
          .toList();
    } catch (e) {
      Get.find<AppLogService>()
          .warning('NVIDIA model list request failed', details: e);
    } finally {
      isLoadingNvidiaModels.value = false;
    }
  }

  void debouncedSetCloudModel(String provider, String model) {
    _modelDebounceTimer?.cancel();
    _modelDebounceTimer = Timer(const Duration(milliseconds: 800), () {
      setCloudModel(provider, model);
    });
  }

  void cancelModelDebounce() {
    _modelDebounceTimer?.cancel();
  }

  Future<void> setTemperature(double value) async {
    temperature.value = value;
    await _hive.setSetting(AppConstants.keyTemperature, value);
  }

  Future<void> setMaxTokens(int value) async {
    maxTokens.value = value;
    await _hive.setSetting(AppConstants.keyMaxTokens, value);
  }

  Future<void> setContextSize(int value) async {
    contextSize.value = value;
    await _hive.setSetting(AppConstants.keyContextSize, value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _hive.setSetting('theme_mode', mode.name);
    Get.changeThemeMode(mode);
    _updateSystemUI();
  }

  void _updateSystemUI() {
    final isDark = themeMode.value == ThemeMode.dark ||
        (themeMode.value == ThemeMode.system &&
            Get.mediaQuery.platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor:
          isDark ? const Color(0xFF0A0A0F) : const Color(0xFFF8F9FA),
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ));
  }

  static ThemeMode _themeModeFromString(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
