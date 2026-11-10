import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/src/windows_mdns.dart';

void main() {
  Uint8List announcement({int ttl = 120}) => encodeWorkerAnnouncement(
        id: '0123456789abcdef0123456789abcdef',
        name: 'GPU worker',
        port: 50052,
        ramMb: 4096,
        bandwidth: 32.5,
        addresses: ['192.168.1.25'],
        ttl: ttl,
      );

  test('Windows advertises the same rpc7 Bonjour service as mobile', () {
    final packet = decodeMdns(announcement(), '192.168.1.25');
    final workers = workersFromMdns(packet.records);
    expect(workers, hasLength(1));
    expect(workers.single, {
      'name': 'GPU worker',
      'model': 'GPU worker',
      'host': '192.168.1.25',
      'port': 50052,
      'ramMb': 4096,
      'bandwidth': 32.5,
      'id': '0123456789abcdef0123456789abcdef',
    });
  });

  test('goodbye records and incompatible protocols are not workers', () {
    expect(
        workersFromMdns(
            decodeMdns(announcement(ttl: 0), '192.168.1.25').records),
        isEmpty);
    final records = decodeMdns(announcement(), '192.168.1.25').records;
    final txt =
        records.singleWhere((r) => r.type == 16).value as Map<String, String>;
    txt['v'] = 'rpc6';
    expect(workersFromMdns(records), isEmpty);
  });

  test('DNS compression pointers are followed and pointer cycles rejected', () {
    final bytes = Uint8List.fromList([
      0,
      0,
      0x84,
      0,
      0,
      0,
      0,
      2,
      0,
      0,
      0,
      0,
      1,
      97,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      120,
      0,
      4,
      192,
      168,
      1,
      25,
      0xc0,
      12,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      120,
      0,
      4,
      192,
      168,
      1,
      26,
    ]);
    expect(decodeMdns(bytes, '192.168.1.25').records.map((r) => r.name),
        ['a', 'a']);
    bytes[12] = 0xc0;
    bytes[13] = 12;
    expect(() => decodeMdns(bytes, '192.168.1.25'), throwsFormatException);
  });

  test('truncated or malformed network packets produce explicit errors', () {
    final bytes = announcement();
    expect(() => decodeMdns(bytes.sublist(0, 15), '192.168.1.25'),
        throwsFormatException);
    expect(
        () => decodeMdns(Uint8List(1), '192.168.1.25'), throwsFormatException);
  });
}
