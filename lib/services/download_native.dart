import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';

final Dio _dio = Dio();
final Map<String, CancelToken> _cancelTokens = {};
const _channel = MethodChannel('com.aichat.ai_chat/model_import');

Future<String> getModelsDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final modelsPath = '${dir.path}/models';
  await Directory(modelsPath).create(recursive: true);
  return modelsPath;
}

Future<bool> isModelDownloaded(String path) async {
  return File(path).existsSync();
}

Future<List<String>> getDownloadedModels(String modelsDir) async {
  final dir = Directory(modelsDir);
  if (!await dir.exists()) return [];
  return dir
      .listSync()
      .where((f) =>
          f.path.endsWith('.gguf') ||
          f.path.endsWith('.litertlm') ||
          f.path.endsWith('.safetensors') ||
          f.path.endsWith('.coreml') ||
          f.path.endsWith('.mlpackage') ||
          f.path.endsWith('.mlmodelc'))
      .map((f) => f.path.split('/').last)
      .toList();
}

Future<int> getModelSize(String path) async {
  final file = File(path);
  if (!await file.exists()) return 0;
  return await file.length();
}

Future<int> getRemoteFileSize(String url, {String? authToken}) async {
  final headers = <String, dynamic>{};
  if (authToken != null && authToken.isNotEmpty) {
    headers['Authorization'] = 'Bearer $authToken';
  }

  // 1. Try HEAD request
  try {
    final response = await _dio.head(
      url,
      options: Options(headers: headers, followRedirects: true),
    );
    final length = response.headers.value(Headers.contentLengthHeader);
    final size = int.tryParse(length ?? '') ?? 0;
    if (size > 0) return size;
  } catch (_) {
    // If HEAD fails, fall back to GET with Range
  }

  // 2. Try GET request with Range: bytes=0-0 (efficiently fetch metadata only)
  try {
    final response = await _dio.get(
      url,
      options: Options(
        headers: {
          ...headers,
          'Range': 'bytes=0-0',
        },
        followRedirects: true,
      ),
    );
    
    // Check Content-Range header first (e.g., bytes 0-0/12345678)
    final contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final parts = contentRange.split('/');
      if (parts.length > 1) {
        final size = int.tryParse(parts.last.trim());
        if (size != null && size > 0) return size;
      }
    }

    // Fallback to Content-Length (if the server ignored Range and returned the whole file)
    final length = response.headers.value(Headers.contentLengthHeader);
    final size = int.tryParse(length ?? '') ?? 0;
    if (size > 0) return size;
  } catch (_) {
    // Both failed
  }

  return 0;
}

Future<String> downloadModel({
  required String url,
  required String savePath,
  String? authToken,
  void Function(int received, int total)? onProgress,
}) async {
  final tempPath = '$savePath.part';
  final cancelToken = CancelToken();
  final filename = savePath.split('/').last;
  _cancelTokens[filename] = cancelToken;
  var expectedTotalBytes = 0;

  try {
    final tempFile = File(tempPath);
    final oldTempFile = File('$savePath.tmp');
    if (await oldTempFile.exists()) {
      await oldTempFile.delete();
    }
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final headers = <String, dynamic>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    await _dio.download(
      url,
      tempPath,
      cancelToken: cancelToken,
      deleteOnError: false,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: true,
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          expectedTotalBytes = total;
        }
        onProgress?.call(received, total > 0 ? total : 0);
      },
    );

    final downloadedBytes = await tempFile.length();
    if (expectedTotalBytes > 0 && downloadedBytes < expectedTotalBytes) {
      await tempFile.delete();
      throw Exception(
        'Downloaded file is incomplete: $downloadedBytes of $expectedTotalBytes bytes.',
      );
    }
    final finalFile = File(savePath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(savePath);

    if (savePath.toLowerCase().endsWith('.zip')) {
      final modelsDir = finalFile.parent.path;
      extractFileToDisk(savePath, modelsDir);
      await File(savePath).delete();
    }

    _cancelTokens.remove(filename);
    return savePath;
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) {
      _cancelTokens.remove(filename);
      return 'PAUSED';
    }
    _cancelTokens.remove(filename);
    throw Exception('Download failed: ${e.message}');
  } catch (e) {
    _cancelTokens.remove(filename);
    rethrow;
  }
}

void pauseDownload(String filename) {
  _cancelTokens[filename]?.cancel('paused');
}

Future<void> deleteModel(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
  final partFile = File('$path.part');
  if (await partFile.exists()) await partFile.delete();
  final tempFile = File('$path.tmp');
  if (await tempFile.exists()) await tempFile.delete();
}

// ── Native MethodChannel bridges (Android DownloadManager) ──

Future<Map<String, dynamic>?> startNativeDownload({
  required String url,
  required String filename,
  required String modelsDir,
}) async {
  if (!Platform.isAndroid) return null;
  try {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'downloadModelInApp',
      {
        'url': url,
        'filename': filename,
        'modelsDir': modelsDir,
      },
    );
    return result;
  } catch (e) {
    print('[DownloadNative] startNativeDownload failed: $e');
    rethrow;
  }
}

Future<bool> cancelNativeDownload({
  required int downloadId,
  required String filename,
}) async {
  if (!Platform.isAndroid) return false;
  try {
    final result = await _channel.invokeMethod<bool>(
      'cancelDownloadInApp',
      {
        'downloadId': downloadId,
        'filename': filename,
      },
    );
    return result ?? false;
  } catch (e) {
    print('[DownloadNative] cancelNativeDownload failed: $e');
    return false;
  }
}

Future<List<Map<String, dynamic>>> getActiveNativeDownloads() async {
  if (!Platform.isAndroid) return [];
  try {
    final List<dynamic>? result = await _channel.invokeListMethod<dynamic>('getActiveDownloads');
    if (result == null) return [];
    return result.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  } catch (e) {
    print('[DownloadNative] getActiveNativeDownloads failed: $e');
    return [];
  }
}
