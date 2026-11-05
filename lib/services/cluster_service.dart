import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'cluster_qr.dart';
import 'hive_service.dart';

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  const ClusterShare(this.name, this.mb, {this.isThisPhone = false});
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed);
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Running a model across workers is Android-only for now; iOS devices
  /// can be workers (their GPU serves a master's layers).
  static bool get canBeMaster => !kIsWeb && Platform.isAndroid;

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  static const rejectedMessage = 'This worker was reset. Scan its code again.';
  static const unpairedMessage = 'Scan again to reconnect';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// This phone's pairing key as a worker (in its QR code), once loaded.
  final pairingKey = RxnString();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    if (isSupported) {
      if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    super.onClose();
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    LlamaCluster.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    final key = pairingKey.value;
    if (host == null || !status.running || key == null || status.id == null) return null;
    return buildWorkerQr(
      host: host,
      port: LlamaCluster.defaultPort,
      id: status.id!,
      key: key,
      name: deviceName,
      ramMb: status.ramMb,
      bandwidth: status.bandwidth,
    );
  }

  /// Gives this worker a new pairing key and QR code: every master that
  /// paired with it must scan again.
  Future<void> resetPairing() async {
    await LlamaCluster.resetPairing();
    pairingKey.value = await LlamaCluster.workerPairingKey();
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted) await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    await LlamaCluster.startWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    await LlamaCluster.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    try {
      worker.value = await LlamaCluster.workerStatus();
      if (worker.value.running && pairingKey.value == null) {
        pairingKey.value = await LlamaCluster.workerPairingKey();
      }
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi (wlan* on Android, en0 on
  /// iOS), if any.
  Future<void> refreshWifiAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final wifi = interfaces.where((i) => i.name.startsWith('wlan') || i.name == 'en0');
      wifiAddress.value = wifi.isEmpty || wifi.first.addresses.isEmpty
          ? null
          : wifi.first.addresses.first.address;
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds (pairs) the worker from a scanned QR code: the only way to add
  /// one, because the code carries its pairing key. Returns an error
  /// message, or null on success.
  Future<String?> addFromQr(String data) async {
    final ({ClusterWorker worker, String key}) scanned;
    try {
      scanned = parseWorkerQr(data);
    } on FormatException catch (e) {
      return e.message;
    }
    final w = scanned.worker;
    final wasPaired = workers.any((x) => x.id == w.id && x.paired);
    await LlamaCluster.pairWorker(w.id!, scanned.key);
    final result = await LlamaCluster.probe(w);
    if (result != ProbeResult.ok) {
      // Keep the key of a worker that was already paired: a stale code can't
      // unpair it, and it may just be away right now.
      if (!wasPaired) await LlamaCluster.forgetWorker(w.id!);
      return result == ProbeResult.rejected
          ? rejectedMessage
          : 'Can\'t reach ${w.endpoint}. Check that the phone is a worker '
              'and on the same Wi-Fi.';
    }
    workers.removeWhere((x) => x.endpoint == w.endpoint || x.id == w.id);
    workers.add(w);
    await _save();
    return null;
  }

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable,
  /// including any that must be scanned again.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final result = await relocate(workers.toList(),
        probe: LlamaCluster.probe, discover: LlamaCluster.discover);
    if (result.moved > 0) {
      workers.assignAll(result.workers);
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found ${result.moved} worker(s) at a new address');
    }
    return result.unreachable;
  }

  /// [relocateWorkers] without the platform: [probe] checks a worker (and
  /// its pairing key), [discover] lists workers seen on the network. A worker
  /// only moves to an address where it proves it holds its key, so another
  /// device announcing the same ID can't take its place.
  static Future<({List<ClusterWorker> workers, List<ClusterWorker> unreachable, int moved})> relocate(
    List<ClusterWorker> workers, {
    required Future<ProbeResult> Function(ClusterWorker) probe,
    required Future<List<ClusterWorker>> Function() discover,
  }) async {
    final unreachable = <ClusterWorker>[];
    final missing = <ClusterWorker>[];
    for (final w in workers) {
      if (!w.paired) {
        unreachable.add(w);
        continue;
      }
      switch (await probe(w)) {
        case ProbeResult.ok:
          break;
        case ProbeResult.rejected:
          // Reachable, but reset: only scanning its new code helps.
          unreachable.add(w);
        case ProbeResult.unreachable:
        case ProbeResult.unpaired:
          missing.add(w);
      }
    }
    final updated = [...workers];
    var moved = 0;
    if (missing.isNotEmpty) {
      final seen = await discover();
      for (final w in missing) {
        final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
        final candidate = match == null || match.endpoint == w.endpoint ? null : w.movedTo(match.host, match.port);
        if (candidate == null || await probe(candidate) != ProbeResult.ok) {
          unreachable.add(w);
          continue;
        }
        updated[updated.indexOf(w)] = candidate;
        moved++;
      }
    }
    return (workers: updated, unreachable: unreachable, moved: moved);
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    if (w.id != null) await LlamaCluster.forgetWorker(w.id!);
    await _save();
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    if (!enabled.value || workers.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    // Workers that are off or away are left out, not fatal: the model may
    // fit without them.
    final offline = await relocateWorkers();
    final available = workers.where((w) => !offline.any((o) => o.endpoint == w.endpoint)).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= await LlamaCluster.benchmark();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own.
    final master = _Phone(null, await LlamaCluster.localFreeRamMb() * 0.7, _localSpeed!);
    final phones = [
      master,
      for (final w in available)
        _Phone(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed),
    ];
    final totalMb = phones.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${phones.length} phones: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the phones, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    if (needMb <= master.capacityMb) {
      final share = await _askFitsHere(
          modelName ?? modelPath.split('/').last, modelMb, available.length);
      if (!share) {
        await LlamaCluster.clear();
        return 0;
      }
      _splitBySpeed(phones, needMb);
    } else {
      _fillFastestFirst(phones, needMb);
    }

    final used = phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    try {
      await LlamaCluster.setCluster(
        [for (final p in used) p.worker!],
        weights: [for (final p in used) p.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(switch (e.code) {
        'REJECTED' => '${e.message}. $rejectedMessage',
        'UNPAIRED' => '${e.message}. $unpairedMessage',
        _ => '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
            'phone, or set this phone\'s Phone cluster to Off.',
      });
    }
    return used.length;
  }

  /// Fastest first, each up to its free memory, until the model is placed.
  static void _fillFastestFirst(List<_Phone> phones, double needMb) {
    final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each phone's free memory
  /// (what a capped phone can't take goes to the others).
  static void _splitBySpeed(List<_Phone> phones, double needMb) {
    var open = [...phones];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name = workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ?? endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() => split.clear();

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
