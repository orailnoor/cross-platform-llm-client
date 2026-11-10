import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

const _service = '_privatelm._tcp.local';
final _group = InternetAddress('224.0.0.251');

class MdnsRecord {
  final String name;
  final int type, ttl;
  final Object value;
  final String source;
  MdnsRecord(this.name, this.type, this.ttl, this.value, this.source);
}

class _Reader {
  final Uint8List bytes;
  int at = 0;
  _Reader(this.bytes);

  int u16() {
    if (at + 2 > bytes.length) {
      throw const FormatException('Truncated DNS integer');
    }
    final value = (bytes[at] << 8) | bytes[at + 1];
    at += 2;
    return value;
  }

  String name() {
    var cursor = at;
    var jumped = false;
    final visited = <int>{};
    final labels = <String>[];
    while (true) {
      if (cursor >= bytes.length || !visited.add(cursor)) {
        throw const FormatException('Invalid DNS name pointer');
      }
      final length = bytes[cursor++];
      if (length == 0) {
        if (!jumped) at = cursor;
        return labels.join('.').toLowerCase();
      }
      if ((length & 0xc0) == 0xc0) {
        if (cursor >= bytes.length) {
          throw const FormatException('Truncated DNS pointer');
        }
        final pointer = ((length & 0x3f) << 8) | bytes[cursor++];
        if (!jumped) at = cursor;
        jumped = true;
        cursor = pointer;
      } else {
        if (length > 63 ||
            cursor + length > bytes.length ||
            labels.length > 127) {
          throw const FormatException('Invalid DNS label');
        }
        labels.add(utf8.decode(bytes.sublist(cursor, cursor + length)));
        cursor += length;
      }
    }
  }
}

({List<String> questions, List<MdnsRecord> records}) decodeMdns(
    Uint8List packet, String source) {
  final reader = _Reader(packet);
  reader.u16();
  reader.u16();
  final questions = reader.u16();
  final count = reader.u16() + reader.u16() + reader.u16();
  final names = <String>[];
  for (var i = 0; i < questions; i++) {
    names.add(reader.name());
    reader.u16();
    reader.u16();
  }
  final records = <MdnsRecord>[];
  for (var i = 0; i < count; i++) {
    final name = reader.name();
    final type = reader.u16();
    reader.u16();
    final ttl = (reader.u16() << 16) | reader.u16();
    final length = reader.u16();
    final end = reader.at + length;
    if (end > packet.length) {
      throw const FormatException('Truncated DNS record');
    }
    Object? value;
    switch (type) {
      case 12:
        value = reader.name();
      case 33:
        if (length < 7) throw const FormatException('Invalid DNS SRV record');
        reader.u16();
        reader.u16();
        value = {'port': reader.u16(), 'host': reader.name()};
      case 16:
        final txt = <String, String>{};
        while (reader.at < end) {
          final size = packet[reader.at++];
          if (reader.at + size > end) {
            throw const FormatException('Invalid DNS TXT record');
          }
          final text = utf8.decode(packet.sublist(reader.at, reader.at + size));
          reader.at += size;
          final equals = text.indexOf('=');
          if (equals > 0) {
            txt[text.substring(0, equals)] = text.substring(equals + 1);
          }
        }
        value = txt;
      case 1:
        if (length == 4) value = packet.sublist(reader.at, end).join('.');
    }
    if (reader.at > end) {
      throw const FormatException('DNS record length mismatch');
    }
    reader.at = end;
    if (value != null) records.add(MdnsRecord(name, type, ttl, value, source));
  }
  return (questions: names, records: records);
}

List<int> _u16(int value) => [(value >> 8) & 255, value & 255];
List<int> _name(String name) => [
      for (final label in name.split('.')) ...[
        utf8.encode(label).length,
        ...utf8.encode(label)
      ],
      0,
    ];

Uint8List encodeWorkerAnnouncement({
  required String id,
  required String name,
  required int port,
  required int ramMb,
  required double bandwidth,
  required List<String> addresses,
  int ttl = 120,
}) {
  final instance = 'PrivateLM-${id.substring(0, 8)}.$_service';
  final host = 'privatelm-${id.substring(0, 8)}.local';
  List<int> record(String owner, int type, List<int> data) => [
        ..._name(owner),
        ..._u16(type),
        ..._u16(type == 12 ? 1 : 0x8001),
        (ttl >> 24) & 255,
        (ttl >> 16) & 255,
        (ttl >> 8) & 255,
        ttl & 255,
        ..._u16(data.length),
        ...data,
      ];
  final txt = [
    'v=rpc7',
    'id=$id',
    'model=$name',
    'ram=$ramMb',
    'bw=$bandwidth'
  ];
  return Uint8List.fromList([
    ..._u16(0),
    ..._u16(0x8400),
    ..._u16(0),
    ..._u16(3 + addresses.length),
    ..._u16(0),
    ..._u16(0),
    ...record(_service, 12, _name(instance)),
    ...record(instance, 33, [0, 0, 0, 0, ..._u16(port), ..._name(host)]),
    ...record(instance, 16, [
      for (final field in txt) ...[
        utf8.encode(field).length,
        ...utf8.encode(field)
      ],
    ]),
    for (final address in addresses)
      ...record(host, 1, InternetAddress(address).rawAddress),
  ]);
}

List<Map<String, Object?>> workersFromMdns(Iterable<MdnsRecord> records) {
  final live = records.where((r) => r.ttl > 0).toList();
  final result = <Map<String, Object?>>[];
  for (final ptr in live.where((r) => r.name == _service && r.type == 12)) {
    final instance = ptr.value as String;
    final srv =
        live.where((r) => r.name == instance && r.type == 33).firstOrNull;
    final txtRecord =
        live.where((r) => r.name == instance && r.type == 16).firstOrNull;
    if (srv == null || txtRecord == null) continue;
    final txt = txtRecord.value as Map<String, String>;
    if (txt['v'] != 'rpc7') continue;
    final target = srv.value as Map<String, Object>;
    final port = target['port'] as int;
    if (port < 1 || port > 65535) continue;
    result.add({
      'name': txt['model'] ?? instance,
      'model': txt['model'],
      'host': srv.source,
      'port': port,
      'ramMb': int.tryParse(txt['ram'] ?? ''),
      'bandwidth': double.tryParse(txt['bw'] ?? ''),
      'id': txt['id'],
    });
  }
  return result;
}

/// Interoperates with the Android NSD/iOS Bonjour rpc7 service.
class WindowsMdns {
  final RawDatagramSocket socket;
  Timer? _timer;
  Uint8List? _goodbye;
  WindowsMdns._(this.socket);

  static Future<RawDatagramSocket> _open() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353,
        reuseAddress: true);
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    var joined = 0;
    for (final interface in interfaces) {
      try {
        socket.joinMulticast(_group, interface);
        joined++;
      } on SocketException catch (error) {
        debugPrint(
            '[Windows cluster] mDNS interface ${interface.name}: $error');
      }
    }
    if (joined == 0) {
      socket.close();
      throw const SocketException(
          'No multicast-capable LAN interface for worker discovery');
    }
    socket.multicastHops = 255;
    return socket;
  }

  static Future<WindowsMdns> advertise({
    required String id,
    required String name,
    required int port,
    required int ramMb,
    required double bandwidth,
  }) async {
    final socket = await _open();
    final service = WindowsMdns._(socket);
    final addresses =
        (await NetworkInterface.list(type: InternetAddressType.IPv4))
            .expand((i) => i.addresses)
            .where((a) => !a.isLoopback)
            .map((a) => a.address)
            .toList();
    Uint8List packet(int ttl) => encodeWorkerAnnouncement(
          id: id,
          name: name,
          port: port,
          ramMb: ramMb,
          bandwidth: bandwidth,
          addresses: addresses,
          ttl: ttl,
        );
    final announcement = packet(120);
    service._goodbye = packet(0);
    void announce() => socket.send(announcement, _group, 5353);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? data;
      while ((data = socket.receive()) != null) {
        try {
          final decoded = decodeMdns(data!.data, data.address.address);
          if (decoded.questions
              .any((q) => q == _service || q.endsWith('.$_service'))) {
            announce();
          }
        } on FormatException catch (error) {
          debugPrint('[Windows cluster] Ignoring malformed mDNS: $error');
        }
      }
    }, onError: (Object error) {
      debugPrint('[Windows cluster] mDNS advertising failed: $error');
      service.close();
    });
    announce();
    service._timer =
        Timer.periodic(const Duration(seconds: 30), (_) => announce());
    return service;
  }

  static Future<List<Map<String, Object?>>> discover(
      {required Duration timeout}) async {
    final socket = await _open();
    final records = <String, MdnsRecord>{};
    Object? failure;
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? data;
      while ((data = socket.receive()) != null) {
        try {
          for (final record
              in decodeMdns(data!.data, data.address.address).records) {
            final key = '${record.name}:${record.type}'
                '${record.type == 12 ? ':${record.value}' : ''}';
            if (record.ttl == 0) {
              records.remove(key);
            } else {
              records[key] = record;
            }
          }
        } on FormatException catch (error) {
          debugPrint('[Windows cluster] Ignoring malformed mDNS: $error');
        }
      }
    }, onError: (Object error) => failure = error);
    final query = Uint8List.fromList([
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      ..._name(_service),
      0,
      12,
      0,
      1,
    ]);
    try {
      socket.send(query, _group, 5353);
      await Future<void>.delayed(timeout ~/ 2);
      socket.send(query, _group, 5353);
      await Future<void>.delayed(timeout ~/ 2);
      if (failure != null) {
        throw StateError('Worker discovery failed: $failure');
      }
      return workersFromMdns(records.values);
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    final goodbye = _goodbye;
    _goodbye = null;
    if (goodbye != null) socket.send(goodbye, _group, 5353);
    socket.close();
  }
}
