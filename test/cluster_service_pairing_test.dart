import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_qr.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/services/hive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('llama_flutter_android/cluster');
  final key = base64Url.encode(List.generate(32, (i) => i)).replaceAll('=', '');
  final code = buildWorkerQr(host: '10.0.0.5', port: 50052, id: 'w1', key: key);
  late Directory dir;
  late List<MethodCall> calls;
  late String probeAnswer;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cluster_pairing_test');
    Hive.init(dir.path);
    await Get.putAsync(() => HiveService().init());
    calls = [];
    probeAnswer = 'ok';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'probe' ? probeAnswer : null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('scannedKeyIsCheckedBeforeItIsStored', () async {
    final cluster = ClusterService();
    expect(await cluster.addFromQr(code), isNull);

    final methods = calls.map((c) => c.method).toList();
    expect(methods, ['probe', 'pairWorker']);
    expect((calls.first.arguments as Map)['key'], key);
    expect(cluster.workers.single.paired, isTrue);
  });

  test('failedRescanOfPairedWorkerKeepsItsKey', () async {
    final cluster = ClusterService();
    cluster.workers.add(const ClusterWorker(
        name: 'Pixel', host: '10.0.0.5', port: 50052, id: 'w1', paired: true));
    probeAnswer = 'rejected';

    expect(await cluster.addFromQr(code), ClusterService.rejectedMessage);
    expect(calls.map((c) => c.method), isNot(contains('pairWorker')));
    expect(calls.map((c) => c.method), isNot(contains('forgetWorker')));
    expect(cluster.workers.single.paired, isTrue);
  });
}
