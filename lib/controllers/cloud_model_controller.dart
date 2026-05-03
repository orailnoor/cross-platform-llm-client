import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../services/app_log_service.dart';
import '../services/hive_service.dart';
import 'settings_controller.dart';

class CloudProviderInfo {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final bool requiresKeyForList;
  final bool supportsFetch;

  const CloudProviderInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.requiresKeyForList = true,
    this.supportsFetch = true,
  });
}

class CloudModelController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _cachePrefix = 'cloud_model_cache_';
  static const _cacheTimePrefix = 'cloud_model_cache_time_';

  final providers = const [
    CloudProviderInfo(
      id: 'openrouter',
      name: 'OpenRouter',
      description: 'Free model list · OpenAI compatible',
      icon: Icons.hub_outlined,
      requiresKeyForList: false,
    ),
    CloudProviderInfo(
      id: 'openai',
      name: 'OpenAI',
      description: 'Native OpenAI chat models',
      icon: Icons.auto_awesome,
    ),
    CloudProviderInfo(
      id: 'google',
      name: 'Google Gemini',
      description: 'Gemini native API models',
      icon: Icons.diamond_outlined,
    ),
    CloudProviderInfo(
      id: 'nvidia',
      name: 'NVIDIA NIM',
      description: 'OpenAI compatible hosted NIM models',
      icon: Icons.memory_outlined,
    ),
    CloudProviderInfo(
      id: 'custom',
      name: 'Custom API',
      description: 'Manual OpenAI-compatible endpoint',
      icon: Icons.tune,
      supportsFetch: false,
    ),
  ];

  final modelsByProvider = <String, List<String>>{}.obs;
  final fetchedAtByProvider = <String, DateTime>{}.obs;
  final isLoadingProvider = <String, bool>{}.obs;
  final errorByProvider = <String, String>{}.obs;
  final searchByProvider = <String, String>{}.obs;

  final customNameController = TextEditingController();
  final customBaseUrlController = TextEditingController();
  final customApiKeyController = TextEditingController();
  final customModelController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
    if (!providers.any((provider) => provider.id == activeProvider)) {
      _settings.setCloudProvider('openrouter');
    }
    for (final provider in providers) {
      _loadCachedModels(provider.id);
    }
    _syncCustomControllers();
  }

  @override
  void onClose() {
    customNameController.dispose();
    customBaseUrlController.dispose();
    customApiKeyController.dispose();
    customModelController.dispose();
    super.onClose();
  }

  String get activeProvider => _settings.cloudProvider.value;

  String activeModelFor(String provider) {
    switch (provider) {
      case 'openrouter':
        return _settings.openRouterModel.value;
      case 'google':
        return _settings.googleModel.value;
      case 'nvidia':
        return _settings.nvidiaModel.value;
      case 'custom':
        return _settings.customCloudModel.value;
      default:
        return _settings.openaiModel.value;
    }
  }

  String apiKeyFor(String provider) {
    switch (provider) {
      case 'openrouter':
        return _settings.openRouterKey.value;
      case 'google':
        return _settings.googleKey.value;
      case 'nvidia':
        return _settings.nvidiaKey.value;
      case 'custom':
        return _settings.customCloudKey.value;
      default:
        return _settings.openaiKey.value;
    }
  }

  TextEditingController apiKeyControllerFor(String provider) {
    return _settings.apiKeyControllerFor(provider);
  }

  bool isConfigured(String provider) {
    final info = providers.firstWhere((p) => p.id == provider);
    if (!info.requiresKeyForList && provider == 'openrouter') {
      return true;
    }
    if (provider == 'custom') {
      return _settings.customCloudBaseUrl.value.isNotEmpty &&
          _settings.customCloudModel.value.isNotEmpty &&
          _settings.customCloudKey.value.isNotEmpty;
    }
    return apiKeyFor(provider).isNotEmpty;
  }

  String statusLabel(String provider) {
    if (provider == 'openrouter') {
      return apiKeyFor(provider).isEmpty ? 'List Ready' : 'Connected';
    }
    return isConfigured(provider) ? 'Connected' : 'Needs Key';
  }

  List<String> filteredModelsFor(String provider) {
    final query = (searchByProvider[provider] ?? '').toLowerCase().trim();
    final active = activeModelFor(provider);
    final source = [...(modelsByProvider[provider] ?? const <String>[])];
    if (active.isNotEmpty && !source.contains(active)) {
      source.insert(0, active);
    }
    final filtered = query.isEmpty
        ? source
        : source.where((id) => id.toLowerCase().contains(query)).toList();
    filtered.sort((a, b) {
      if (a == active) return -1;
      if (b == active) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return filtered;
  }

  String fetchedLabel(String provider) {
    final fetchedAt = fetchedAtByProvider[provider];
    if (fetchedAt == null) return 'Not fetched yet';
    final diff = DateTime.now().difference(fetchedAt);
    if (diff.inMinutes < 1) return 'Updated just now';
    if (diff.inHours < 1) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inDays < 1) return 'Updated ${diff.inHours}h ago';
    return 'Updated ${diff.inDays}d ago';
  }

  Future<void> saveApiKey(String provider, String value) async {
    await _settings.setApiKey(provider, value);
  }

  Future<void> selectModel(String provider, String modelId) async {
    final normalized =
        provider == 'google' ? modelId.replaceFirst('models/', '') : modelId;
    await _settings.setCloudProvider(provider);
    await _settings.setCloudModel(provider, normalized);
    await _settings.setInferenceMode('cloud');
    Get.snackbar('Cloud Model Active', '$provider · $normalized',
        snackPosition: SnackPosition.BOTTOM);
  }

  Future<void> saveCustomProvider() async {
    await _settings.setCustomCloudConfig(
      name: customNameController.text,
      baseUrl: customBaseUrlController.text,
      apiKey: customApiKeyController.text,
      model: customModelController.text,
    );
    await selectModel('custom', _settings.customCloudModel.value);
  }

  Future<void> refreshModels(String provider) async {
    if (provider == 'custom') return;

    if (provider != 'openrouter' && apiKeyFor(provider).isEmpty) {
      errorByProvider[provider] = 'Add an API key first.';
      return;
    }

    isLoadingProvider[provider] = true;
    errorByProvider.remove(provider);

    try {
      final response = await _requestModelList(provider);
      if (response.statusCode != 200) {
        final detail = '${response.statusCode}: ${_shortBody(response.body)}';
        errorByProvider[provider] = detail;
        Get.find<AppLogService>().warning(
          'Model list request failed for $provider',
          details: detail,
        );
        return;
      }

      final ids = _parseModelIds(provider, response.body);
      modelsByProvider[provider] = ids;
      final fetchedAt = DateTime.now();
      fetchedAtByProvider[provider] = fetchedAt;
      await _hive.setSetting('$_cachePrefix$provider', ids);
      await _hive.setSetting(
          '$_cacheTimePrefix$provider', fetchedAt.toIso8601String());
    } catch (e) {
      errorByProvider[provider] = '$e';
      Get.find<AppLogService>().warning(
        'Model list request failed for $provider',
        details: e,
      );
    } finally {
      isLoadingProvider[provider] = false;
    }
  }

  Future<http.Response> _requestModelList(String provider) {
    switch (provider) {
      case 'openrouter':
        return http.get(Uri.parse('${AppConstants.openRouterEndpoint}/models'));
      case 'google':
        return http.get(Uri.parse(
            '${AppConstants.googleEndpoint}?key=${apiKeyFor(provider)}'));
      case 'nvidia':
        return http.get(
          Uri.parse('${AppConstants.nvidiaEndpoint}/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
      default:
        return http.get(
          Uri.parse('https://api.openai.com/v1/models'),
          headers: {'Authorization': 'Bearer ${apiKeyFor(provider)}'},
        );
    }
  }

  List<String> _parseModelIds(String provider, String body) {
    final data = jsonDecode(body);
    if (provider == 'google') {
      final raw = data['models'] as List? ?? [];
      return raw
          .map((model) => model is Map ? model['name']?.toString() : null)
          .whereType<String>()
          .toSet()
          .toList();
    }

    final raw = data['data'] as List? ?? [];
    return raw
        .map((model) => model is Map ? model['id']?.toString() : null)
        .whereType<String>()
        .toSet()
        .toList();
  }

  void _loadCachedModels(String provider) {
    final raw = _hive.getSetting<List>('$_cachePrefix$provider');
    if (raw != null) {
      modelsByProvider[provider] = raw.whereType<String>().toList();
    }
    final rawTime = _hive.getSetting<String>('$_cacheTimePrefix$provider');
    if (rawTime != null) {
      final parsed = DateTime.tryParse(rawTime);
      if (parsed != null) fetchedAtByProvider[provider] = parsed;
    }
  }

  void _syncCustomControllers() {
    customNameController.text = _settings.customCloudName.value;
    customBaseUrlController.text = _settings.customCloudBaseUrl.value;
    customApiKeyController.text = _settings.customCloudKey.value;
    customModelController.text = _settings.customCloudModel.value;
  }

  String _shortBody(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 280) return compact;
    return '${compact.substring(0, 280)}...';
  }
}
