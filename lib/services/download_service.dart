import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

import 'download_native.dart' if (dart.library.html) 'download_web.dart'
    as platform_dl;

/// State for an individual download.
class DownloadProgress {
  final String filename;
  final RxDouble progress = 0.0.obs;
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxBool isPaused = false.obs;

  DownloadProgress({required this.filename});
}

/// Service for downloading GGUF model files with progress tracking.
/// On web: downloads are not supported (models are too large for browser).
class DownloadService extends GetxService {
  /// Currently active downloads.
  final activeDownloads = <String, DownloadProgress>{}.obs;

  bool get isDownloadingAny => activeDownloads.isNotEmpty;

  /// Whether the platform supports downloading models.
  bool get supportsDownload => !kIsWeb;

  Future<String> get modelsDir async => await platform_dl.getModelsDir();

  Future<String> modelPath(String filename) async {
    return '${await modelsDir}/$filename';
  }

  Future<bool> isModelDownloaded(String filename) async {
    if (kIsWeb) return false;
    return await platform_dl.isModelDownloaded(await modelPath(filename));
  }

  Future<List<String>> getDownloadedModels() async {
    if (kIsWeb) return [];
    return await platform_dl.getDownloadedModels(await modelsDir);
  }

  Future<String> downloadModel({
    required String url,
    required String filename,
    String? authToken,
  }) async {
    if (kIsWeb) return 'ERROR: Downloading models is not supported on web.';

    final savePath = await modelPath(filename);
    final downloadProgress = DownloadProgress(filename: filename);
    activeDownloads[filename] = downloadProgress;

    try {
      final result = await platform_dl.downloadModel(
        url: url,
        savePath: savePath,
        authToken: authToken,
        onProgress: (received, total) {
          downloadProgress.downloadedBytes.value = received;
          downloadProgress.totalBytes.value = total;
          if (total > 0) {
            downloadProgress.progress.value = received / total;
          }
        },
      );
      activeDownloads.remove(filename);
      return result;
    } catch (e) {
      activeDownloads.remove(filename);
      rethrow;
    }
  }

  void pauseDownload(String filename) {
    platform_dl.pauseDownload(filename);
    activeDownloads[filename]?.isPaused.value = true;
  }

  Future<void> deleteModel(String filename) async {
    if (kIsWeb) return;
    await platform_dl.deleteModel(await modelPath(filename));
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
