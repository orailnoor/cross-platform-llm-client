import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import '../services/download_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../models/ai_model.dart';
import '../core/constants.dart';

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final LocalImageService _localImage = Get.find<LocalImageService>();
  final InferenceService _inference = Get.find<InferenceService>();

  Map<String, DownloadProgress> get activeDownloads =>
      _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;
  final isImporting = false.obs;

  @override
  void onInit() {
    super.onInit();
    availableModels.value =
        AppConstants.availableModels.map((m) => AiModel.fromMap(m)).toList();
    refreshDownloaded();
  }

  Future<void> refreshDownloaded() async {
    final files = await _download.getDownloadedModels();
    downloadedFiles.value = files;

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
          size: 'Local File',
          description: 'Imported from local storage',
          template: 'chatml',
          isImported: true,
          isVision: isVision,
        ));
      }
    }
    
    // Remove any imported models that are no longer downloaded
    availableModels.removeWhere((model) => 
      model.isImported && !files.contains(model.filename));
  }

  bool isDownloaded(String filename) => downloadedFiles.contains(filename);

  bool get isDownloading => _download.isDownloadingAny;

  DownloadProgress? getDownloadProgress(String filename) =>
      _download.activeDownloads[filename];

  bool isDownloadingModel(String filename) =>
      _download.activeDownloads.containsKey(filename);

  Future<void> downloadModel(AiModel model) async {
    try {
      await _download.downloadModel(
        url: model.url,
        filename: model.filename,
      );
      await refreshDownloaded();
    } catch (e) {
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
      final model = availableModels.firstWhereOrNull((m) => m.filename == filename);
      final result = await _inference.loadModel(path, modelName: filename);
      if (_inference.isModelLoaded.value) {
        _inference.isVisionLoaded.value = model?.isVision ?? false;
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
        final filename = p.basename(file.path);

        final modelsDir = await _download.modelsDir;
        final destPath = '$modelsDir/$filename';

        Get.snackbar('Importing', 'Copying $filename to app storage...',
            snackPosition: SnackPosition.BOTTOM);
        await file.copy(destPath);

        await refreshDownloaded();
        Get.snackbar('Import Successful', 'Model $filename imported.',
            snackPosition: SnackPosition.BOTTOM);
      }
    } catch (e) {
      Get.snackbar('Import Failed', '$e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      isImporting.value = false;
    }
  }
}
