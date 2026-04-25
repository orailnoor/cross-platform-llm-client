/// Web stub — model downloads are not supported on web.

Future<String> getModelsDir() async => '/web/models';

Future<bool> isModelDownloaded(String path) async => false;

Future<List<String>> getDownloadedModels(String modelsDir) async => [];

Future<String> downloadModel({
  required String url,
  required String savePath,
  String? authToken,
  void Function(int received, int total)? onProgress,
}) async {
  return 'ERROR: Downloads not supported on web.';
}

void pauseDownload(String filename) {}

Future<void> deleteModel(String path) async {}
