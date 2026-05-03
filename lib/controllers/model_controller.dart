import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';
import '../models/ai_model.dart';
import '../core/constants.dart';
import 'settings_controller.dart';

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final LocalImageService _localImage = Get.find<LocalImageService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _customModelsKey = 'custom_url_models';

  Map<String, DownloadProgress> get activeDownloads =>
      _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;
  final isImporting = false.obs;
  final customModels = <AiModel>[].obs;
  final fileSizes = <String, int>{}.obs;

  List<AiModel> get displayedModels {
    final active = _inference.loadedModelName.value;
    final models = [...availableModels];
    models.sort((a, b) {
      if (a.filename == active) return -1;
      if (b.filename == active) return 1;
      final aDownloaded = isDownloaded(a.filename);
      final bDownloaded = isDownloaded(b.filename);
      if (aDownloaded != bDownloaded) return aDownloaded ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return models;
  }

  @override
  void onInit() {
    super.onInit();
    _loadCustomModels();
    availableModels.value = AppConstants.availableModels
        .map((m) => AiModel.fromMap(m))
        .toList()
      ..addAll(customModels);
    refreshDownloaded();
  }

  void _loadCustomModels() {
    final raw =
        _hive.getSetting<List>(_customModelsKey, defaultValue: []) ?? [];
    customModels.value = raw
        .whereType<Map>()
        .map((m) => AiModel.fromMap(Map<String, String>.from(m)))
        .toList();
  }

  Future<void> _saveCustomModels() async {
    await _hive.setSetting(
      _customModelsKey,
      customModels.map((m) => m.toMap()).toList(),
    );
  }

  Future<void> refreshDownloaded() async {
    final files = await _download.getDownloadedModels();
    downloadedFiles.value = files;
    for (final file in files) {
      fileSizes[file] = await _download.getModelSize(file);
    }

    // Add any downloaded files that are not in availableModels
    final existingFilenames = availableModels.map((m) => m.filename).toSet();
    for (final file in files) {
      if (!existingFilenames.contains(file)) {
        final lower = file.toLowerCase();
        final isVision = lower.contains('vl-') ||
            lower.contains('llava') ||
            lower.contains('vision') ||
            lower.contains('-vl');

        availableModels.add(AiModel(
          name: file,
          filename: file,
          url: '',
          size: _formatModelSize(file),
          description: 'Imported from local storage',
          template: 'chatml',
          isImported: true,
          isVision: isVision,
        ));
      }
    }

    // Remove any imported models that are no longer downloaded
    availableModels.removeWhere(
        (model) => model.isImported && !files.contains(model.filename));
  }

  bool isDownloaded(String filename) => downloadedFiles.contains(filename);

  bool get isDownloading => _download.isDownloadingAny;

  DownloadProgress? getDownloadProgress(String filename) =>
      _download.activeDownloads[filename];

  bool isDownloadingModel(String filename) =>
      _download.activeDownloads.containsKey(filename);

  String modelSizeLabel(AiModel model) {
    final bytes = fileSizes[model.filename] ?? 0;
    if (bytes > 0) return DownloadService.formatBytes(bytes);
    return model.size;
  }

  String _formatModelSize(String filename) {
    final bytes = fileSizes[filename] ?? 0;
    if (bytes <= 0) return 'Local File';
    return DownloadService.formatBytes(bytes);
  }

  String filenameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : 'model.gguf';
    final decoded = Uri.decodeComponent(segment.split('?').first);
    if (decoded.toLowerCase().endsWith('.gguf') ||
        decoded.toLowerCase().endsWith('.safetensors')) {
      return decoded;
    }
    return '$decoded.gguf';
  }

  Future<String> detectUrlSize(String url) async {
    try {
      final bytes = await _download.getRemoteFileSize(url);
      if (bytes <= 0) return 'Unknown size';
      return DownloadService.formatBytes(bytes);
    } catch (_) {
      return 'Unknown size';
    }
  }

  Future<void> addModelFromUrl({
    required String name,
    required String url,
    String? filename,
    String? description,
    String template = 'chatml',
    String? size,
    bool isVision = false,
  }) async {
    final resolvedFilename = (filename == null || filename.trim().isEmpty)
        ? filenameFromUrl(url)
        : filename.trim();

    final model = AiModel(
      name: name.trim().isEmpty ? resolvedFilename : name.trim(),
      filename: resolvedFilename,
      url: url.trim(),
      size: size == null || size.trim().isEmpty ? 'Unknown size' : size.trim(),
      description: description == null || description.trim().isEmpty
          ? 'Added from custom URL'
          : description.trim(),
      template: template.trim().isEmpty ? 'chatml' : template.trim(),
      isVision: isVision,
      isCustom: true,
    );

    customModels.removeWhere((m) => m.filename == model.filename);
    customModels.add(model);
    availableModels.removeWhere((m) => m.filename == model.filename);
    availableModels.add(model);
    await _saveCustomModels();
  }

  Future<void> downloadModel(AiModel model) async {
    try {
      await _download.downloadModel(
        url: model.url,
        filename: model.filename,
      );
      await refreshDownloaded();
    } catch (e) {
      Get.find<AppLogService>().error('Model download failed', details: e);
      Get.snackbar('Download Failed', '$e',
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  void pauseDownload(String filename) {
    _download.pauseDownload(filename);
  }

  Future<void> deleteModel(String filename) async {
    await _download.deleteModel(filename);
    await refreshDownloaded();
    // Unload if this was the active model
    if (_inference.loadedModelName.value == filename) {
      await _inference.unloadModel();
    }
  }

  Future<void> loadModel(String filename) async {
    final path = await _download.modelPath(filename);

    if (filename.toLowerCase().endsWith('.safetensors')) {
      final result = await _localImage.loadModel(path, modelName: filename);
      Get.snackbar('Image Model', result, snackPosition: SnackPosition.BOTTOM);
    } else {
      final model =
          availableModels.firstWhereOrNull((m) => m.filename == filename);
      final result = await _inference.loadModel(path, modelName: filename);
      if (_inference.isModelLoaded.value) {
        _inference.isVisionLoaded.value = model?.isVision ?? false;
        await _settings.setInferenceMode('local');
      }
      Get.snackbar('Text Model', result, snackPosition: SnackPosition.BOTTOM);
    }
  }

  Future<void> unloadModel() async {
    await _inference.unloadModel();
  }

  Future<void> importModelFromStorage() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        isImporting.value = true;
        final file = File(result.files.single.path!);
        final filename = file.uri.pathSegments.last;

        final modelsDir = await _download.modelsDir;
        final destPath = '$modelsDir/$filename';

        Get.snackbar('Importing', 'Copying $filename to app storage...',
            snackPosition: SnackPosition.BOTTOM);
        await file.copy(destPath);
        fileSizes[filename] = await File(destPath).length();

        await refreshDownloaded();
        Get.snackbar('Import Successful', 'Model $filename imported.',
            snackPosition: SnackPosition.BOTTOM);
      }
    } catch (e) {
      Get.find<AppLogService>().error('Model import failed', details: e);
      Get.snackbar('Import Failed', '$e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      isImporting.value = false;
    }
  }
}
