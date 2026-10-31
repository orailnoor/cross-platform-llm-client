import 'package:flutter/services.dart';

/// A phone running as a cluster worker, found on the local network, scanned
/// from its QR code, or added by hand.
class ClusterWorker {
  final String name;
  final String host;
  final int port;

  /// Free RAM the worker reported when it started, in MB (null if unknown).
  final int? ramMb;

  /// Memory read speed the worker measured, in GB/s (null if unknown).
  /// Token generation speed follows this closely.
  final double? bandwidth;
  final String? model;

  /// The worker device's lasting ID: finds it again when its IP changes.
  final String? id;

  const ClusterWorker({
    required this.name,
    required this.host,
    required this.port,
    this.ramMb,
    this.bandwidth,
    this.model,
    this.id,
  });

  String get endpoint => '$host:$port';

  factory ClusterWorker.fromMap(Map<dynamic, dynamic> map) => ClusterWorker(
        name: map['name'] as String? ?? '${map['host']}',
        host: map['host'] as String,
        port: map['port'] as int,
        ramMb: (map['ramMb'] as num?)?.toInt(),
        bandwidth: (map['bandwidth'] as num?)?.toDouble(),
        model: map['model'] as String?,
        id: map['id'] as String?,
      );

  /// The same device at a new address.
  ClusterWorker movedTo(String host, int port) => ClusterWorker(
      name: name, host: host, port: port, ramMb: ramMb, bandwidth: bandwidth, model: model, id: id);

  Map<String, dynamic> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'ramMb': ramMb,
        'bandwidth': bandwidth,
        'model': model,
        'id': id,
      };
}

/// State of this phone's worker service.
class ClusterWorkerStatus {
  /// starting, running, stopped or error.
  final String state;
  final String? error;

  /// Address of the master using this worker right now, if any.
  final String? peer;

  /// Memory this worker holds, mostly the master's model layers.
  final int heldMb;
  final int ramMb;
  final double bandwidth;

  /// Android is throttling the worker (slow cores, low CPU share).
  final bool throttled;

  /// The app is exempt from battery optimization (Android).
  final bool batteryUnrestricted;

  /// This device's lasting worker ID (put in its QR code).
  final String? id;

  const ClusterWorkerStatus({
    required this.state,
    this.error,
    this.peer,
    this.heldMb = 0,
    this.ramMb = 0,
    this.bandwidth = 0,
    this.throttled = false,
    this.batteryUnrestricted = true,
    this.id,
  });

  bool get running => state == 'running';
  bool get starting => state == 'starting';
}

/// Phone cluster: one phone (the master) runs a model whose layers are
/// spread across other phones (workers) on the same Wi-Fi, using llama.cpp's
/// RPC backend. Android arm64 only.
///
/// The RPC protocol has no authentication: only run workers on a network you
/// trust.
class LlamaCluster {
  static const _channel = MethodChannel('llama_flutter_android/cluster');
  static const defaultPort = 50052;

  /// Starts serving this phone's CPU to a master, in a foreground service
  /// that keeps running in the background.
  static Future<void> startWorker({int port = defaultPort, int? threads}) =>
      _channel.invokeMethod('startWorker', {'port': port, 'threads': threads});

  static Future<void> stopWorker() => _channel.invokeMethod('stopWorker');

  static Future<ClusterWorkerStatus> workerStatus() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('workerStatus') ?? {};
    return ClusterWorkerStatus(
      state: m['state'] as String? ?? 'stopped',
      error: m['error'] as String?,
      peer: m['peer'] as String?,
      heldMb: (m['heldMb'] as num?)?.toInt() ?? 0,
      ramMb: (m['ramMb'] as num?)?.toInt() ?? 0,
      bandwidth: (m['bandwidth'] as num?)?.toDouble() ?? 0,
      throttled: m['throttled'] as bool? ?? false,
      batteryUnrestricted: m['batteryUnrestricted'] as bool? ?? true,
      id: m['id'] as String?,
    );
  }

  /// Android: asks to exempt the app from battery optimization, so a busy
  /// worker isn't moved to slow cores. No-op if already exempt.
  static Future<void> requestBatteryUnrestricted() =>
      _channel.invokeMethod('requestBatteryUnrestricted');

  /// Keeps this device's screen on (a worker runs at full speed only while
  /// PrivateLM is on screen).
  static Future<void> setKeepScreenOn(bool on) =>
      _channel.invokeMethod('setKeepScreenOn', {'on': on});

  static Future<int> localFreeRamMb() async =>
      await _channel.invokeMethod<int>('localFreeRamMb') ?? 0;

  /// This phone's memory read speed in GB/s (~0.2 s to measure).
  static Future<double> benchmark() async =>
      await _channel.invokeMethod<double>('benchmark') ?? 0;

  /// Where the last model load put its weights: llama.cpp buffer name
  /// ("CPU_Mapped", "RPC0[host:port]", …) and size in MB.
  static Future<List<({String name, double mb})>> lastLoadBuffers() async {
    final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>('lastLoadBuffers');
    return [
      for (final m in list ?? const [])
        (name: m['name'] as String, mb: (m['mb'] as num).toDouble()),
    ];
  }

  /// Looks for workers on the local network for [timeout].
  static Future<List<ClusterWorker>> discover(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
        'discover', {'timeoutMs': timeout.inMilliseconds});
    return (list ?? const []).map(ClusterWorker.fromMap).toList();
  }

  /// Whether something answers on [endpoint] ("host:port").
  static Future<bool> probe(String endpoint) async =>
      await _channel.invokeMethod<bool>('probe', {'endpoint': endpoint}) ??
      false;

  /// Uses [workers] for the next GGUF model load. Layers are split by
  /// [weights] (one per worker, e.g. MB to hold), with this phone keeping a
  /// share by [localWeight]. Throws a [PlatformException] (code UNREACHABLE)
  /// if any worker doesn't answer. An empty list turns cluster mode off.
  static Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) =>
      _channel.invokeMethod('setCluster', {
        'endpoints': [for (final w in workers) w.endpoint],
        'weights': weights ?? List.filled(workers.length, 1.0),
        'localWeight': localWeight,
      });

  static Future<void> clear() => setCluster(const []);
}
