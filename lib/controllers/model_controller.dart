import 'package:get/get.dart';
import '../core/constants.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final InferenceService _inference = Get.find<InferenceService>();

  Map<String, DownloadProgress> get activeDownloads => _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;

  @override
  void onInit() {
    super.onInit();
    availableModels.value =
        AppConstants.availableModels.map((m) => AiModel.fromMap(m)).toList();
    refreshDownloaded();
  }

  Future<void> refreshDownloaded() async {
    downloadedFiles.value = await _download.getDownloadedModels();
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
    final result = await _inference.loadModel(path, modelName: filename);
    Get.snackbar('Model', result, snackPosition: SnackPosition.BOTTOM);
  }

  Future<void> unloadModel() async {
    await _inference.unloadModel();
  }
}
