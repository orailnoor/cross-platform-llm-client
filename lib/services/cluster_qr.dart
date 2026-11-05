import 'dart:convert';

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// The QR code a cluster worker shows and a master scans:
/// privatelm://worker?host=…&port=…&id=…&key=…&v=1 (plus name, ram, bw).
/// `key` is the worker's pairing secret, so the code is the only way to add
/// a worker.
const clusterQrScheme = 'privatelm';

/// Pairing protocol version (PLMC v1).
const clusterQrVersion = 1;

const _notAWorkerCode = "That isn't a PrivateLM worker code";

String buildWorkerQr({
  required String host,
  required int port,
  required String id,
  required String key,
  String? name,
  int? ramMb,
  double? bandwidth,
}) =>
    Uri(scheme: clusterQrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '$port',
      'id': id,
      'key': key,
      'v': '$clusterQrVersion',
      if (name != null && name.isNotEmpty) 'name': name,
      if (ramMb != null && ramMb > 0) 'ram': '$ramMb',
      if (bandwidth != null && bandwidth > 0) 'bw': bandwidth.toStringAsFixed(1),
    }).toString();

/// The worker in a scanned code, and its pairing key. Throws a
/// [FormatException] whose message can be shown as is.
({ClusterWorker worker, String key}) parseWorkerQr(String data) {
  final uri = Uri.tryParse(data.trim());
  final params = uri?.queryParameters ?? const {};
  final host = params['host'];
  final port = int.tryParse(params['port'] ?? '');
  if (uri == null || uri.scheme != clusterQrScheme || host == null || port == null) {
    throw const FormatException(_notAWorkerCode);
  }
  final key = params['key'];
  final id = params['id'];
  final version = int.tryParse(params['v'] ?? '');
  if (key == null || id == null || id.isEmpty || version == null) {
    throw const FormatException('This worker needs a newer PrivateLM. Update it, then scan again.');
  }
  if (version > clusterQrVersion) {
    throw const FormatException('Update PrivateLM on this phone to add this worker.');
  }
  if (version != clusterQrVersion || !_isPairingKey(key)) {
    throw const FormatException(_notAWorkerCode);
  }
  return (
    worker: ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: id,
      paired: true,
    ),
    key: key,
  );
}

/// 32 bytes, base64url without padding.
bool _isPairingKey(String key) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) return false;
  try {
    return base64Url.decode(base64Url.normalize(key)).length == 32;
  } on FormatException {
    return false;
  }
}
