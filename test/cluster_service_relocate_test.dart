import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_service.dart';

void main() {
  const saved = ClusterWorker(name: 'Pixel', host: '10.0.0.5', port: 50052, id: 'w1', paired: true);
  const seenElsewhere = ClusterWorker(name: 'Pixel', host: '10.0.0.9', port: 50052, id: 'w1');

  test('relocateUpdatesAddressWhenNewAddressAuthenticates', () async {
    final result = await ClusterService.relocate(
      [saved],
      probe: (w) async => w.host == '10.0.0.9' ? ProbeResult.ok : ProbeResult.unreachable,
      discover: () async => [seenElsewhere],
    );
    expect(result.workers.single.host, '10.0.0.9');
    expect(result.workers.single.paired, isTrue);
    expect(result.moved, 1);
    expect(result.unreachable, isEmpty);
  });

  test('relocateIgnoresIdMatchThatFailsAuth', () async {
    final result = await ClusterService.relocate(
      [saved],
      probe: (w) async => w.host == '10.0.0.9' ? ProbeResult.rejected : ProbeResult.unreachable,
      discover: () async => [seenElsewhere],
    );
    expect(result.workers.single.host, '10.0.0.5');
    expect(result.moved, 0);
    expect(result.unreachable.single.endpoint, '10.0.0.5:50052');
    expect(result.rejected, isEmpty, reason: 'an impostor at a new address is not a reset');
  });

  test('relocateSkipsUnpairedWorkers', () async {
    const legacy = ClusterWorker(name: 'Old', host: '10.0.0.7', port: 50052, id: 'w2');
    final probed = <String>[];
    final result = await ClusterService.relocate(
      [legacy],
      probe: (w) async {
        probed.add(w.endpoint);
        return ProbeResult.ok;
      },
      discover: () async => const [],
    );
    expect(probed, isEmpty);
    expect(result.unreachable.single.endpoint, '10.0.0.7:50052');
    expect(result.workers.single.host, '10.0.0.7');
  });

  test('relocateKeepsResetWorkerOutWithoutSearching', () async {
    var searched = false;
    final result = await ClusterService.relocate(
      [saved],
      probe: (w) async => ProbeResult.rejected,
      discover: () async {
        searched = true;
        return const [];
      },
    );
    expect(searched, isFalse);
    expect(result.unreachable.single.endpoint, '10.0.0.5:50052');
    expect(result.rejected.single.endpoint, '10.0.0.5:50052');
  });
}
