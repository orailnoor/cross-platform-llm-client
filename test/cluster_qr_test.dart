import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/cluster_qr.dart';

void main() {
  final key = base64Url.encode(List.generate(32, (i) => i)).replaceAll('=', '');

  String code(Map<String, String> params) =>
      Uri(scheme: 'privatelm', host: 'worker', queryParameters: params).toString();

  Matcher throwsMessage(String message) =>
      throwsA(isA<FormatException>().having((e) => e.message, 'message', message));

  test('roundTrip', () {
    final data = buildWorkerQr(
      host: '192.168.1.20',
      port: 50052,
      id: 'w1',
      key: key,
      name: 'Pixel 6',
      ramMb: 4096,
      bandwidth: 12.5,
    );
    final parsed = parseWorkerQr(data);
    expect(parsed.key, key);
    expect(parsed.worker.host, '192.168.1.20');
    expect(parsed.worker.port, 50052);
    expect(parsed.worker.id, 'w1');
    expect(parsed.worker.name, 'Pixel 6');
    expect(parsed.worker.ramMb, 4096);
    expect(parsed.worker.bandwidth, 12.5);
    expect(parsed.worker.paired, isTrue);
  });

  test('rejectsNonPrivateLmCode', () {
    expect(() => parseWorkerQr('https://example.com'),
        throwsMessage("That isn't a PrivateLM worker code"));
  });

  test('oldWorkerCodeAsksToUpdateWorker', () {
    const message = 'This worker needs a newer PrivateLM. Update it, then scan again.';
    expect(() => parseWorkerQr(code({'host': '10.0.0.5', 'port': '50052', 'id': 'w1'})),
        throwsMessage(message));
    expect(() => parseWorkerQr(code({'host': '10.0.0.5', 'port': '50052', 'key': key, 'v': '1'})),
        throwsMessage(message));
  });

  test('newerWorkerCodeAsksToUpdateThisPhone', () {
    expect(
        () => parseWorkerQr(
            code({'host': '10.0.0.5', 'port': '50052', 'id': 'w1', 'key': key, 'v': '2'})),
        throwsMessage('Update PrivateLM on this phone to add this worker.'));
  });

  test('rejectsKeyThatIsNotExactly32Bytes', () {
    final short = base64Url.encode(List.generate(31, (i) => i)).replaceAll('=', '');
    for (final bad in [short, 'not*base64!']) {
      expect(
          () => parseWorkerQr(
              code({'host': '10.0.0.5', 'port': '50052', 'id': 'w1', 'key': bad, 'v': '1'})),
          throwsMessage("That isn't a PrivateLM worker code"));
    }
  });
}
