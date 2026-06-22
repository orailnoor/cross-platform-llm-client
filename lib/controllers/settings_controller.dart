import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../services/hive_service.dart';
import '../services/secure_storage_service.dart';
import '../services/app_log_service.dart';
import '../services/local_image_service.dart';
import '../ffi/sd_ffi_bindings.dart';
import 'package:sd_flutter_android/sd_flutter_android.dart';

class SettingsController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final SecureStorageService _secure = Get.find<SecureStorageService>();

  // Observable settings
  final themeMode = ThemeMode.system.obs;
  final inferenceMode = 'local'.obs; // 'local' or 'cloud'
  final cloudProvider = 'openrouter'.obs;
  final openaiKey = ''.obs;
  final anthropicKey = ''.obs;
  final googleKey = ''.obs;
  final kimiKey = ''.obs;
  final stabilityKey = ''.obs;
  final nvidiaKey = ''.obs;
  final openRouterKey = ''.obs;
  final deepSeekKey = ''.obs;
  final customCloudName = 'Custom API'.obs;
  final customCloudBaseUrl = ''.obs;
  final customCloudKey = ''.obs;
  final openaiModel = 'gpt-5.2'.obs;
  final anthropicModel = 'claude-sonnet-4-6'.obs;
  final googleModel = 'gemini-2.5-flash'.obs;
  final kimiModel = 'kimi-k2.6'.obs;
  final stabilityModel = 'sd3.5-flash'.obs;
  final nvidiaModel = 'meta/llama-3.1-8b-instruct'.obs;
  final openRouterModel = 'openai/gpt-4o-mini'.obs;
  final deepSeekModel = 'deepseek-v4-flash'.obs;
  final customCloudModel = ''.obs;
  final globalSystemPrompt = AppConstants.systemPrompt.obs;
  final nvidiaModels = <String>[].obs;
  final isLoadingNvidiaModels = false.obs;
  final temperature = 0.1.obs;
  final maxTokens = 512.obs;
  final contextSize = 2048.obs;
  final liteRtPerformanceMode = AppConstants.defaultLiteRtPerformanceMode.obs;
  final imageSteps = 1.obs;
  final imageGenForceCpu = AppConstants.defaultImageGenForceCpu.obs;
  final imageGenBackend = Backend.cpu.obs;
  final imageGpuVendor = 'detecting'.obs;
  final imageGenGpuGuardMb = AppConstants.defaultImageGenGpuGuardMb.obs;
  final imageGenSize = AppConstants.defaultImageGenSize.obs;
  final fontScale = AppConstants.defaultFontScale.obs;

  // Persistent text controllers for settings fields
  final openaiKeyController = TextEditingController();
  final anthropicKeyController = TextEditingController();
  final googleKeyController = TextEditingController();
  final kimiKeyController = TextEditingController();
  final stabilityKeyController = TextEditingController();
  final nvidiaKeyController = TextEditingController();
  final openRouterKeyController = TextEditingController();
  final deepSeekKeyController = TextEditingController();
  final customCloudNameController = TextEditingController();
  final customCloudBaseUrlController = TextEditingController();
  final customCloudKeyController = TextEditingController();
  final globalSystemPromptController = TextEditingController();

  final openaiModelController = TextEditingController();
  final anthropicModelController = TextEditingController();
  final googleModelController = TextEditingController();
  final kimiModelController = TextEditingController();
  final stabilityModelController = TextEditingController();
  final nvidiaModelController = TextEditingController();
  final openRouterModelController = TextEditingController();
  final deepSeekModelController = TextEditingController();
  final customCloudModelController = TextEditingController();

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
    openRouterKeyController.dispose();
    deepSeekKeyController.dispose();
    customCloudNameController.dispose();
    customCloudBaseUrlController.dispose();
    customCloudKeyController.dispose();
    globalSystemPromptController.dispose();
    openaiModelController.dispose();
    anthropicModelController.dispose();
    googleModelController.dispose();
    kimiModelController.dispose();
    stabilityModelController.dispose();
    nvidiaModelController.dispose();
    openRouterModelController.dispose();
    deepSeekModelController.dispose();
    customCloudModelController.dispose();
    _apiKeyDebounceTimer?.cancel();
    _modelDebounceTimer?.cancel();
    super.onClose();
  }

  Future<void> _loadSettings() async {
    final savedTheme = _hive.getSetting<String>('theme_mode');
    themeMode.value = _themeModeFromString(savedTheme);
    inferenceMode.value = _hive.getSetting(AppConstants.keyInferenceMode,
            defaultValue: 'local') ??
        'local';
    cloudProvider.value = _hive.getSetting(AppConstants.keyCloudProvider,
            defaultValue: 'openrouter') ??
        'openrouter';
    openaiKey.value = (await _secure.readApiKey(AppConstants.keyOpenaiKey)) ?? '';
    anthropicKey.value = (await _secure.readApiKey(AppConstants.keyAnthropicKey)) ?? '';
    googleKey.value = (await _secure.readApiKey(AppConstants.keyGoogleKey)) ?? '';
    kimiKey.value = (await _secure.readApiKey(AppConstants.keyKimiKey)) ?? '';
    stabilityKey.value = (await _secure.readApiKey(AppConstants.keyStabilityKey)) ?? '';
    nvidiaKey.value = (await _secure.readApiKey(AppConstants.keyNvidiaKey)) ?? '';
    openRouterKey.value = (await _secure.readApiKey(AppConstants.keyOpenRouterKey)) ?? '';
    deepSeekKey.value = (await _secure.readApiKey(AppConstants.keyDeepSeekKey)) ?? '';
    customCloudName.value = _hive.getSetting(AppConstants.keyCustomCloudName,
            defaultValue: 'Custom API') ??
        'Custom API';
    customCloudBaseUrl.value =
        _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
    customCloudKey.value =
        (await _secure.readApiKey(AppConstants.keyCustomCloudKey)) ?? '';
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
    openRouterModel.value = _hive.getSetting(AppConstants.keyOpenRouterModel,
            defaultValue: 'openai/gpt-4o-mini') ??
        'openai/gpt-4o-mini';
    deepSeekModel.value = _hive.getSetting(AppConstants.keyDeepSeekModel,
            defaultValue: 'deepseek-v4-flash') ??
        'deepseek-v4-flash';
    customCloudModel.value =
        _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
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
    liteRtPerformanceMode.value = _hive.getSetting(
          AppConstants.keyLiteRtPerformanceMode,
          defaultValue: AppConstants.defaultLiteRtPerformanceMode,
        ) ??
        AppConstants.defaultLiteRtPerformanceMode;
    imageSteps.value = _hive.getSetting(AppConstants.keyImageSteps,
            defaultValue: AppConstants.defaultImageSteps) ??
        AppConstants.defaultImageSteps;
    imageGenForceCpu.value = _hive.getSetting(
            AppConstants.keyImageGenForceCpu,
            defaultValue: AppConstants.defaultImageGenForceCpu) ??
        AppConstants.defaultImageGenForceCpu;
    imageGenGpuGuardMb.value = _hive.getSetting(
            AppConstants.keyImageGenGpuGuardMb,
            defaultValue: AppConstants.defaultImageGenGpuGuardMb) ??
        AppConstants.defaultImageGenGpuGuardMb;
    imageGenSize.value = _hive.getSetting(AppConstants.keyImageGenSize,
            defaultValue: AppConstants.defaultImageGenSize) ??
        AppConstants.defaultImageGenSize;
    final savedImageBackend = _hive.getSetting<int>(
        AppConstants.keyImageGenBackend,
        defaultValue: Backend.cpu.index);
    if (savedImageBackend != null &&
        savedImageBackend >= 0 &&
        savedImageBackend < Backend.values.length &&
        !imageGenForceCpu.value) {
      imageGenBackend.value = Backend.values[savedImageBackend];
    } else {
      imageGenBackend.value = Backend.cpu;
    }
    _detectImageGpu();
    fontScale.value = _hive.getSetting(AppConstants.keyFontScale,
            defaultValue: AppConstants.defaultFontScale) ??
        AppConstants.defaultFontScale;

    // Sync controllers with loaded values
    openaiKeyController.text = openaiKey.value;
    anthropicKeyController.text = anthropicKey.value;
    googleKeyController.text = googleKey.value;
    kimiKeyController.text = kimiKey.value;
    stabilityKeyController.text = stabilityKey.value;
    nvidiaKeyController.text = nvidiaKey.value;
    openRouterKeyController.text = openRouterKey.value;
    deepSeekKeyController.text = deepSeekKey.value;
    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    globalSystemPromptController.text = globalSystemPrompt.value;

    openaiModelController.text = openaiModel.value;
    anthropicModelController.text = anthropicModel.value;
    googleModelController.text = googleModel.value;
    kimiModelController.text = kimiModel.value;
    stabilityModelController.text = stabilityModel.value;
    nvidiaModelController.text = nvidiaModel.value;
    openRouterModelController.text = openRouterModel.value;
    deepSeekModelController.text = deepSeekModel.value;
    customCloudModelController.text = customCloudModel.value;
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
      case 'openrouter':
        return openRouterKeyController;
      case 'deepseek':
        return deepSeekKeyController;
      case 'custom':
        return customCloudKeyController;
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
      case 'openrouter':
        return openRouterModelController;
      case 'deepseek':
        return deepSeekModelController;
      case 'custom':
        return customCloudModelController;
      default:
        return openaiModelController;
    }
  }

  String get selectedCloudModelName {
    switch (cloudProvider.value) {
      case 'anthropic':
        return anthropicModel.value;
      case 'google':
        return googleModel.value;
      case 'kimi':
        return kimiModel.value;
      case 'stability':
        return stabilityModel.value;
      case 'nvidia':
        return nvidiaModel.value;
      case 'openrouter':
        return openRouterModel.value;
      case 'deepseek':
        return deepSeekModel.value;
      case 'custom':
        return customCloudModel.value;
      default:
        return openaiModel.value;
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
        await _secure.writeApiKey(AppConstants.keyOpenaiKey, trimmed);
        break;
      case 'anthropic':
        anthropicKey.value = trimmed;
        anthropicKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyAnthropicKey, trimmed);
        break;
      case 'google':
        googleKey.value = trimmed;
        googleKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyGoogleKey, trimmed);
        break;
      case 'kimi':
        kimiKey.value = trimmed;
        kimiKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyKimiKey, trimmed);
        break;
      case 'stability':
        stabilityKey.value = trimmed;
        stabilityKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyStabilityKey, trimmed);
        break;
      case 'nvidia':
        nvidiaKey.value = trimmed;
        nvidiaKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyNvidiaKey, trimmed);
        await refreshNvidiaModels();
        break;
      case 'openrouter':
        openRouterKey.value = trimmed;
        openRouterKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyOpenRouterKey, trimmed);
        break;
      case 'deepseek':
        deepSeekKey.value = trimmed;
        deepSeekKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyDeepSeekKey, trimmed);
        break;
      case 'custom':
        customCloudKey.value = trimmed;
        customCloudKeyController.text = trimmed;
        await _secure.writeApiKey(AppConstants.keyCustomCloudKey, trimmed);
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
      case 'openrouter':
        openRouterModel.value = model;
        openRouterModelController.text = model;
        await _hive.setSetting(AppConstants.keyOpenRouterModel, model);
        break;
      case 'deepseek':
        deepSeekModel.value = model;
        deepSeekModelController.text = model;
        await _hive.setSetting(AppConstants.keyDeepSeekModel, model);
        break;
      case 'custom':
        customCloudModel.value = model;
        customCloudModelController.text = model;
        await _hive.setSetting(AppConstants.keyCustomCloudModel, model);
        break;
    }
  }

  Future<void> setCustomCloudConfig({
    required String name,
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final normalizedName = name.trim().isEmpty ? 'Custom API' : name.trim();
    final normalizedBaseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

    customCloudName.value = normalizedName;
    customCloudBaseUrl.value = normalizedBaseUrl;
    customCloudKey.value = apiKey.trim();
    customCloudModel.value = model.trim();

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.text = customCloudBaseUrl.value;
    customCloudKeyController.text = customCloudKey.value;
    customCloudModelController.text = customCloudModel.value;

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, customCloudBaseUrl.value);
    await _secure.writeApiKey(
        AppConstants.keyCustomCloudKey, customCloudKey.value);
    await _hive.setSetting(
        AppConstants.keyCustomCloudModel, customCloudModel.value);
  }

  Future<void> clearCustomCloudConfig() async {
    customCloudName.value = 'Custom API';
    customCloudBaseUrl.value = '';
    customCloudKey.value = '';
    customCloudModel.value = '';

    customCloudNameController.text = customCloudName.value;
    customCloudBaseUrlController.clear();
    customCloudKeyController.clear();
    customCloudModelController.clear();

    await _hive.setSetting(
        AppConstants.keyCustomCloudName, customCloudName.value);
    await _hive.setSetting(AppConstants.keyCustomCloudBaseUrl, '');
    await _secure.deleteApiKey(AppConstants.keyCustomCloudKey);
    await _hive.setSetting(AppConstants.keyCustomCloudModel, '');
  }

  Future<void> setGlobalSystemPrompt(String prompt) async {
    final normalized =
        prompt.trim().isEmpty ? AppConstants.systemPrompt : prompt.trim();
    globalSystemPrompt.value = normalized;
    globalSystemPromptController.text = normalized;
    await _hive.setSetting(AppConstants.keyGlobalSystemPrompt, normalized);
  }

  String effectiveSystemPromptForModel(String modelName) {
    final prompt = globalSystemPrompt.value.trim();
    final hasCustomPrompt =
        prompt.isNotEmpty && prompt != AppConstants.systemPrompt;
    if (hasCustomPrompt) return prompt;
    if (AppConstants.isUncensoredModelName(modelName)) {
      return AppConstants.uncensoredSystemPrompt;
    }
    return AppConstants.systemPrompt;
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

  Future<void> setLiteRtPerformanceMode(String mode) async {
    final normalized = switch (mode) {
      'gpu_fast' => 'gpu_fast',
      'cpu_safe' => 'cpu_safe',
      _ => AppConstants.defaultLiteRtPerformanceMode,
    };
    liteRtPerformanceMode.value = normalized;
    await _hive.setSetting(AppConstants.keyLiteRtPerformanceMode, normalized);
    if (normalized == 'gpu_fast') {
      await _hive.setSetting(AppConstants.keyLiteRtGpuCrashDetected, false);
    }
  }

  Future<void> setImageSteps(int value) async {
    imageSteps.value = value;
    await _hive.setSetting(AppConstants.keyImageSteps, value);
  }

  Future<void> setImageGenForceCpu(bool value) async {
    imageGenForceCpu.value = value;
    await _hive.setSetting(AppConstants.keyImageGenForceCpu, value);
  }

  Future<void> setImageGenGpuGuardMb(int value) async {
    imageGenGpuGuardMb.value = value;
    await _hive.setSetting(AppConstants.keyImageGenGpuGuardMb, value);
  }

  Future<void> setImageGenSize(int value) async {
    final allowed =
        value == 0 || value == 256 || value == 320 || value == 384 || value == 512;
    final normalized = allowed ? value : AppConstants.defaultImageGenSize;
    imageGenSize.value = normalized;
    await _hive.setSetting(AppConstants.keyImageGenSize, normalized);
  }

  Future<void> _detectImageGpu() async {
    try {
      imageGpuVendor.value = await SdFlutterAndroid.detectGpuVendor();
    } catch (_) {
      imageGpuVendor.value = 'unknown';
    }
  }

  Backend recommendedImageGpuBackend() {
    final vendor = imageGpuVendor.value;
    final preferred = switch (vendor) {
      'adreno' => Backend.opencl,
      'mali' || 'xclipse' || 'powervr' || 'imagination' => Backend.vulkan,
      _ => Backend.vulkan,
    };
    if (preferred.isAvailable) return preferred;
    if (Backend.opencl.isAvailable) return Backend.opencl;
    if (Backend.vulkan.isAvailable) return Backend.vulkan;
    return Backend.cpu;
  }

  String imageGpuLabel() {
    final vendor = imageGpuVendor.value;
    final backend = recommendedImageGpuBackend();
    final vendorLabel = vendor == 'detecting'
        ? 'Detecting'
        : vendor == 'unknown'
            ? 'Unknown GPU'
            : vendor.toUpperCase();
    return backend == Backend.cpu
        ? '$vendorLabel - GPU unavailable'
        : '$vendorLabel - ${backend.displayName}';
  }

  Future<void> setImageBackendMode(bool useGpu) async {
    final backend = useGpu ? recommendedImageGpuBackend() : Backend.cpu;
    imageGenBackend.value = backend;
    imageGenForceCpu.value = !useGpu || backend == Backend.cpu;
    await _hive.setSetting(AppConstants.keyImageGenBackend, backend.index);
    await _hive.setSetting(
        AppConstants.keyImageGenForceCpu, imageGenForceCpu.value);
    if (Get.isRegistered<LocalImageService>()) {
      Get.find<LocalImageService>().setBackend(backend);
    }
  }

  Future<void> setFontScale(double value) async {
    final clamped = value.clamp(0.8, 1.4);
    fontScale.value = clamped;
    await _hive.setSetting(AppConstants.keyFontScale, clamped);
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
      systemNavigationBarColor: isDark ? Colors.black : Colors.white,
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
