// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/discovery/dns_message.dart';
import 'package:androidtv_direct/src/discovery/mdns_transport.dart';

import 'fake_clock.dart';

/// A test-side writer for mDNS answers, independent of the library's code: plain labels, no compression.
final class Answer {
  final BytesBuilder _records = BytesBuilder();
  int _count = 0;

  /// [name] as plain DNS labels.
  static List<int> labels(String name) => [
    for (final label in name.split('.')) ...[label.length, ...utf8.encode(label)],
    0,
  ];

  void _add(String name, int type, int ttl, List<int> data, {bool flush = true}) {
    _records
      ..add(labels(name))
      ..add([type >> 8, type & 255, flush ? 0x80 : 0, 1])
      ..add([ttl >> 24 & 255, ttl >> 16 & 255, ttl >> 8 & 255, ttl & 255])
      ..add([data.length >> 8, data.length & 255])
      ..add(data);
    _count++;
  }

  void ptr(String type, String instance, {int ttl = 4500}) => _add(type, 12, ttl, labels(instance), flush: false);

  void srv(String instance, String host, int port, {int ttl = 120}) =>
      _add(instance, 33, ttl, [0, 0, 0, 0, port >> 8, port & 255, ...labels(host)]);

  void txt(String instance, List<String> strings, {int ttl = 4500}) => _add(instance, 16, ttl, [
    for (final s in strings) ...[s.length, ...utf8.encode(s)],
  ]);

  void a(String host, String address, {int ttl = 120}) => _add(host, 1, ttl, InternetAddress(address).rawAddress);

  void aaaa(String host, String address, {int ttl = 120}) => _add(host, 28, ttl, InternetAddress(address).rawAddress);

  Uint8List bytes() =>
      Uint8List.fromList([0, 0, 0x84, 0, 0, 0, _count >> 8, _count & 255, 0, 0, 0, 0, ..._records.toBytes()]);
}

final class FakeTransport implements MdnsTransport {
  FakeTransport({this.hearsMulticast = true, this.clock, this.startDelay});

  @override
  final bool hearsMulticast;

  /// Advanced past the browser's 100 ms report delay after each delivery.
  final FakeClock? clock;

  /// Makes [start] slow, to cancel during it.
  final Completer<void>? startDelay;

  void Function(Uint8List, InternetAddress)? _onPacket;
  final List<DnsMessage> sent = [];
  bool closed = false;
  int closes = 0;

  @override
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  ) async {
    _onPacket = onPacket;
    await startDelay?.future;
  }

  @override
  Future<void> refreshInterfaces() async {}

  @override
  void send(Uint8List packet) => sent.add(DnsMessage.decode(packet));

  @override
  Future<void> close() async {
    closed = true;
    closes++;
  }

  void deliver(Uint8List packet, [String from = '192.168.0.20']) {
    _onPacket!(packet, InternetAddress(from));
    clock?.advance(const Duration(milliseconds: 100));
  }
}

const v2type = '_androidtvremote2._tcp.local';
const instance = 'Living room TV.$v2type';

Answer fullTv({int port = 37123, String address = '192.168.0.20'}) => Answer()
  ..ptr(v2type, instance)
  ..srv(instance, 'Android.local', port)
  ..txt(instance, ['bt=AA:BB:CC:DD:EE:FF'])
  ..a('Android.local', address);
