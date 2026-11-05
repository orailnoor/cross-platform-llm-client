import 'package:flutter/services.dart';

/// A phone running as a cluster worker, scanned from its QR code (or seen
/// on the local network, to find a paired worker at a new address).
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

  /// This phone holds the worker's pairing key (from scanning its QR code).
  /// Workers saved before pairing existed have none and must be scanned again.
  final bool paired;

  const ClusterWorker({
    required this.name,
    required this.host,
    required this.port,
    this.ramMb,
    this.bandwidth,
    this.model,
    this.id,
    this.paired = false,
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
        paired: map['paired'] as bool? ?? false,
      );

  /// The same device at a new address.
  ClusterWorker movedTo(String host, int port) => ClusterWorker(
      name: name,
      host: host,
      port: port,
      ramMb: ramMb,
      bandwidth: bandwidth,
      model: model,
      id: id,
      paired: paired);

  Map<String, dynamic> toMap() => {
        'name': name,
        'host': host,
        'port': port,
        'ramMb': ramMb,
        'bandwidth': bandwidth,
        'model': model,
        'id': id,
        'paired': paired,
      };
}

/// What a worker said when this phone tried to connect.
enum ProbeResult {
  /// Reachable, and it holds the pairing key this phone has.
  ok,
  unreachable,

  /// Reachable, but its pairing was reset: scan its code again.
  rejected,

  /// This phone has no pairing key for it: scan its code again.
  unpaired,
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
/// Workers only let in masters that scanned their QR code (it carries a
/// pairing key), and everything between them is encrypted, so a worker is
/// safe on a public network.
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

  /// Whether [worker] answers and holds the pairing key this phone has.
  static Future<ProbeResult> probe(ClusterWorker worker) async {
    final result = await _channel
        .invokeMethod<Object>('probe', {'endpoint': worker.endpoint, 'id': worker.id});
    return ProbeResult.values.firstWhere((r) => r.name == result,
        orElse: () => ProbeResult.unreachable);
  }

  /// This phone's pairing key as a worker (base64url), for its QR code.
  static Future<String> workerPairingKey() async =>
      (await _channel.invokeMethod<String>('workerPairingKey'))!;

  /// Gives this worker a new pairing key: every master must scan again.
  static Future<void> resetPairing() => _channel.invokeMethod('resetPairing');

  /// Stores the pairing [key] scanned from worker [id]'s QR code.
  static Future<void> pairWorker(String id, String key) =>
      _channel.invokeMethod('pairWorker', {'id': id, 'key': key});

  /// Deletes this phone's pairing key for worker [id].
  static Future<void> forgetWorker(String id) =>
      _channel.invokeMethod('forgetWorker', {'id': id});

  /// Uses [workers] for the next GGUF model load. Layers are split by
  /// [weights] (one per worker, e.g. MB to hold), with this phone keeping a
  /// share by [localWeight]. Throws a [PlatformException] if any worker
  /// doesn't answer (code UNREACHABLE), was reset (REJECTED) or isn't paired
  /// (UNPAIRED). An empty list turns cluster mode off.
  static Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) =>
      _channel.invokeMethod('setCluster', {
        'endpoints': [for (final w in workers) w.endpoint],
        'ids': [for (final w in workers) w.id ?? ''],
        'weights': weights ?? List.filled(workers.length, 1.0),
        'localWeight': localWeight,
      });

  static Future<void> clear() => setCluster(const []);
}
