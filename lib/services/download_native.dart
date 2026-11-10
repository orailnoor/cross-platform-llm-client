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
      .where((f) {
        final path = f.path.toLowerCase();
        return path.endsWith('.gguf') ||
            path.endsWith('.litertlm') ||
            path.endsWith('.safetensors') ||
            path.endsWith('.coreml') ||
            path.endsWith('.mlpackage') ||
            path.endsWith('.mlmodelc');
      })
      .map((f) => f.path.split(RegExp(r'[/\\]')).last)
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

/// Suffix for in-progress downloads. Distinct from the `.part` files used by
/// imports, so stale-import cleanup never touches a paused download.
const partialDownloadSuffix = '.download';

/// How long a download may go without receiving data before it fails.
Duration receiveIdleTimeout = const Duration(seconds: 60);

/// Resumable download. Bytes received so far are kept in
/// `<savePath>.download`; calling this again after a pause (or a dropped
/// connection) continues from where it stopped using an HTTP Range request.
/// Returns the saved path, or `'PAUSED'` if [pauseDownload] stopped it.
Future<String> downloadModel({
  required String url,
  required String savePath,
  String? authToken,
  void Function(int received, int total)? onProgress,
}) async {
  final partial = File('$savePath$partialDownloadSuffix');
  final cancelToken = CancelToken();
  final filename = savePath.split(RegExp(r'[/\\]')).last;
  _cancelTokens[filename] = cancelToken;
  RandomAccessFile? sink;

  try {
    // Leftovers from older app versions can't be resumed safely.
    for (final legacy in [File('$savePath.tmp'), File('$savePath.part')]) {
      if (await legacy.exists()) await legacy.delete();
    }

    var existing = await partial.exists() ? await partial.length() : 0;
    final headers = <String, dynamic>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    if (existing > 0) headers['Range'] = 'bytes=$existing-';

    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: true,
        // Idle timeout between chunks: a stalled connection fails (keeping
        // the partial file for resume) instead of hanging forever.
        receiveTimeout: receiveIdleTimeout,
        validateStatus: (s) => s != null && (s < 300 || s == 416),
      ),
    );

    if (response.statusCode == 416) {
      // Our partial file doesn't match the remote one (it changed, or we
      // already have every byte). Start over rather than guess.
      await partial.delete();
      _cancelTokens.remove(filename);
      return downloadModel(
        url: url,
        savePath: savePath,
        authToken: authToken,
        onProgress: onProgress,
      );
    }

    // 206 = server honoured the Range; anything else is the whole file.
    final resumed = response.statusCode == 206;
    if (!resumed) existing = 0;
    final total = resumed
        ? _totalFromContentRange(response.headers.value('content-range'))
        : int.tryParse(
                response.headers.value(Headers.contentLengthHeader) ?? '') ??
            0;

    sink = await partial.open(mode: resumed ? FileMode.append : FileMode.write);
    var received = existing;
    onProgress?.call(received, total);
    await for (final chunk in response.data!.stream) {
      await sink.writeFrom(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
    sink = null;

    final downloadedBytes = await partial.length();
    if (total > 0 && downloadedBytes < total) {
      // Keep the partial file so the next attempt resumes.
      throw Exception(
        'Download was interrupted at $downloadedBytes of $total bytes. '
        'Tap download again to resume.',
      );
    }
    if (total > 0 && downloadedBytes > total) {
      await partial.delete();
      throw Exception('Downloaded file is larger than expected; please retry.');
    }

    final finalFile = File(savePath);
    if (await finalFile.exists()) await finalFile.delete();
    await partial.rename(savePath);

    if (savePath.toLowerCase().endsWith('.zip')) {
      final modelsDir = finalFile.parent.path;
      extractFileToDisk(savePath, modelsDir);
      await File(savePath).delete();
    }

    _cancelTokens.remove(filename);
    return savePath;
  } on DioException catch (e) {
    _cancelTokens.remove(filename);
    if (e.type == DioExceptionType.cancel) return 'PAUSED';
    throw Exception(
        'Download failed: ${e.message}. Tap download again to resume.');
  } catch (e) {
    _cancelTokens.remove(filename);
    rethrow;
  } finally {
    await sink?.close();
  }
}

/// Parses the total size from a `Content-Range: bytes 100-199/1234` header.
int _totalFromContentRange(String? header) {
  if (header == null) return 0;
  final slash = header.lastIndexOf('/');
  if (slash < 0) return 0;
  return int.tryParse(header.substring(slash + 1).trim()) ?? 0;
}

void pauseDownload(String filename) {
  _cancelTokens[filename]?.cancel('paused');
}

Future<void> deleteModel(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
  final partFile = File('$path.part');
  if (await partFile.exists()) await partFile.delete();
  final partialDownload = File('$path$partialDownloadSuffix');
  if (await partialDownload.exists()) await partialDownload.delete();
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
