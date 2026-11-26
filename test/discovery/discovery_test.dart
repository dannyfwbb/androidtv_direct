// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/discovery/dns_message.dart';
import 'package:androidtv_direct/src/discovery/mdns_transport.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';

/// A test-side writer for mDNS answers, independent of the library's code: plain labels, no compression.
final class Answer {
  final BytesBuilder _records = BytesBuilder();
  int _count = 0;

  static List<int> _name(String name) => [
    for (final label in name.split('.')) ...[label.length, ...utf8.encode(label)],
    0,
  ];

  void _add(String name, int type, int ttl, List<int> data, {bool flush = true}) {
    _records
      ..add(_name(name))
      ..add([type >> 8, type & 255, flush ? 0x80 : 0, 1])
      ..add([ttl >> 24 & 255, ttl >> 16 & 255, ttl >> 8 & 255, ttl & 255])
      ..add([data.length >> 8, data.length & 255])
      ..add(data);
    _count++;
  }

  void ptr(String type, String instance, {int ttl = 4500}) => _add(type, 12, ttl, _name(instance), flush: false);

  void srv(String instance, String host, int port, {int ttl = 120}) =>
      _add(instance, 33, ttl, [0, 0, 0, 0, port >> 8, port & 255, ..._name(host)]);

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

void main() {
  group('addresses from the network', () {
    test('an IPv4-mapped sender is the IPv4 one', () {
      expect(IoMdnsTransport.unmapped(InternetAddress('::ffff:192.0.2.1')).address, '192.0.2.1');
      expect(IoMdnsTransport.unmapped(InternetAddress('192.0.2.1')).address, '192.0.2.1');
      expect(IoMdnsTransport.unmapped(InternetAddress('2001:db8::1')).address, '2001:db8::1');
    });

    test('a link-local address takes the zone of its sender', () async {
      final clock = FakeClock();
      final transport = FakeTransport(clock: clock);
      final events = <TvServiceEvent>[];
      final sub = TvMdnsBrowser(clock: clock, transport: transport).browse([v2type]).listen(events.add);
      await pumpEventQueue();
      final answer = Answer()
        ..ptr(v2type, instance)
        ..srv(instance, 'Android.local', 37123)
        ..txt(instance, ['bt=AA:BB:CC:DD:EE:FF'])
        ..aaaa('Android.local', 'fe80::2');
      transport.deliver(answer.bytes(), 'fe80::2%lo');
      expect((events.single as TvServiceFound).service.addresses.single.address, 'fe80::2%lo');
      await sub.cancel();
    }, testOn: 'linux');
  });

  group('DNS messages', () {
    test('a real Avahi answer (legacy unicast, compressed names)', () {
      final message = DnsMessage.decode(File('test/fixtures/mdns/avahi_legacy_answer.bin').readAsBytesSync());
      expect(message.isResponse, isTrue);
      expect(message.id, 0x1234);
      expect(message.questions.single.name, '_androidtvdirect-test._tcp.local');
      final byType = {for (final r in message.answers) r.type: r};
      expect((byType[DnsType.ptr]!.data as DnsPointer).target, 'Test TV._androidtvdirect-test._tcp.local');
      expect((byType[DnsType.srv]!.data as DnsSrv).port, 6466);
      expect((byType[DnsType.txt]!.data as DnsText).strings, ['bt=AA:BB:CC:DD:EE:FF']);
      expect((byType[DnsType.a]!.data as DnsAddress).address.address, '192.168.0.20');
      expect((byType[DnsType.aaaa]!.data as DnsAddress).address.address, 'fe80::14');
      expect(message.answers.every((r) => r.ttl <= 10), isTrue);
    });

    test('a query: id, question count, QU bit', () {
      final bytes = DnsMessage.query([const DnsQuestion(v2type, DnsType.ptr, unicastResponse: true)]);
      expect(bytes.sublist(0, 6), [0, 0, 0, 0, 0, 1]);
      final back = DnsMessage.decode(bytes);
      expect(back.questions.single.name, v2type);
      expect(back.questions.single.unicastResponse, isTrue);
    });

    test('malformed input: FormatException, also for pointer loops', () {
      expect(() => DnsMessage.decode(Uint8List.fromList([0, 0, 0x84, 0])), throwsFormatException);
      // One answer whose name points at itself.
      final loop = Uint8List.fromList([
        0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, //
        0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 10, 0, 4, 1, 2, 3, 4,
      ]);
      expect(() => DnsMessage.decode(loop), throwsFormatException);
    });
  });

  group('services', () {
    test('protocol from the type, Bluetooth address from the TXT record', () {
      final v2 = TvService(type: TvServiceType.v2, instance: 'TV', port: 6466, txt: const {'bt': 'AA:BB'});
      final v1 = TvService(type: '_AndroidTvRemote._tcp', instance: 'Old TV', port: 6466);
      expect((v2.protocol, v2.bluetoothAddress), (TvProtocol.v2, 'AA:BB'));
      expect(v1.protocol, TvProtocol.v1);
      expect(v1.bluetoothAddress, isNull);
    });
  });

  group('browsing (fake network, fake clock)', () {
    late FakeClock clock;
    late FakeTransport transport;
    late List<TvServiceEvent> events;
    late StreamSubscription<TvServiceEvent> sub;

    Future<void> start({bool multicast = true}) async {
      clock = FakeClock();
      transport = FakeTransport(hearsMulticast: multicast, clock: clock);
      events = [];
      sub = TvMdnsBrowser(clock: clock, transport: transport).browse([TvServiceType.v2]).listen(events.add);
      await Future<void>.delayed(Duration.zero);
    }

    tearDown(() => sub.cancel());

    test('asks, finds, updates, and loses on a goodbye', () async {
      await start();
      expect(transport.sent.first.questions.single.name, v2type);
      transport.deliver(fullTv().bytes());
      expect(events.single, isA<TvServiceFound>());
      final tv = events.single.service;
      expect((tv.instance, tv.protocol), ('Living room TV', TvProtocol.v2));
      expect(tv.port, 37123);
      expect(tv.address!.address, '192.168.0.20');
      expect(tv.bluetoothAddress, 'AA:BB:CC:DD:EE:FF');

      // The same again changes nothing.
      transport.deliver(fullTv().bytes());
      expect(events, hasLength(1));

      // The service restarted on another port (cache-flush SRV).
      clock.advance(const Duration(seconds: 2));
      transport.deliver((Answer()..srv(instance, 'Android.local', 40001)).bytes());
      expect(events.last, isA<TvServiceUpdated>());
      expect(events.last.service.port, 40001);

      transport.deliver((Answer()..ptr(v2type, instance, ttl: 0)).bytes());
      // Gone after a second's grace (RFC 6762 10.1).
      expect(events, hasLength(2));
      clock.advance(const Duration(milliseconds: 2200));
      expect(events.last, isA<TvServiceLost>());
      expect(events, hasLength(3));
    });

    test('a PTR alone makes it ask for SRV and TXT, then the address', () async {
      await start();
      transport.sent.clear();
      transport.deliver((Answer()..ptr(v2type, instance)).bytes());
      expect(events, isEmpty);
      expect(
        transport.sent.last.questions.map((q) => (q.name, q.type)),
        containsAll([(instance, DnsType.srv), (instance, DnsType.txt)]),
      );
      transport.deliver((Answer()..srv(instance, 'Android.local', 37123)).bytes());
      expect(events, isEmpty);
      expect(transport.sent.last.questions.map((q) => (q.name, q.type)), contains(('Android.local', DnsType.a)));
      transport.deliver((Answer()..a('Android.local', '192.168.0.20')).bytes());
      expect(events.single, isA<TvServiceFound>());
    });

    test('records expire with their TTL; questions back off', () async {
      await start();
      transport.deliver(fullTv().bytes());
      final asked = <Duration>[];
      var count = transport.sent.length;
      for (var s = 0; s < 130; s++) {
        clock.advance(const Duration(seconds: 1));
        if (transport.sent.length > count) {
          asked.add(clock.elapsed);
          count = transport.sent.length;
        }
      }
      // SRV and A live 120 s: the TV is lost when they expire.
      expect(events.last, isA<TvServiceLost>());
      // 1, 2, 4, 8, 16, 32, then every 60 s.
      expect(asked.take(4).map((d) => d.inSeconds), [1, 3, 7, 15]);
    });

    test('cache-flush works per sender: two interfaces do not fight', () async {
      await start();
      transport.deliver(fullTv().bytes(), '192.168.0.20');
      clock.advance(const Duration(seconds: 2));
      transport.deliver((Answer()..a('Android.local', '127.0.0.1')).bytes(), '127.0.0.1');
      expect(events.last.service.addresses.map((a) => a.address), ['192.168.0.20', '127.0.0.1']);
      clock.advance(const Duration(seconds: 2));
      transport.deliver((Answer()..a('Android.local', '192.168.0.21')).bytes(), '192.168.0.20');
      expect(events.last.service.addresses.map((a) => a.address), ['192.168.0.21', '127.0.0.1']);
    });

    test('other types, garbage and queries are ignored', () async {
      await start();
      transport
        ..deliver(Uint8List.fromList([1, 2, 3]))
        ..deliver(DnsMessage.query([const DnsQuestion(v2type, DnsType.ptr)]))
        ..deliver((Answer()..ptr('_googlecast._tcp.local', 'x._googlecast._tcp.local')).bytes());
      expect(events, isEmpty);
    });

    test('without multicast it asks at least every 5 s', () async {
      await start(multicast: false);
      var count = transport.sent.length;
      final asked = <int>[];
      for (var s = 0; s < 40; s++) {
        clock.advance(const Duration(seconds: 1));
        if (transport.sent.length > count) {
          asked.add(clock.elapsed.inSeconds);
          count = transport.sent.length;
        }
      }
      final gaps = [for (var i = 1; i < asked.length; i++) asked[i] - asked[i - 1]];
      expect(gaps.every((g) => g <= 5), isTrue);
    });

    test('cancelling closes the transport', () async {
      await start();
      await sub.cancel();
      expect(transport.closed, isTrue);
    });
  });

  group('review cases', () {
    late FakeClock clock;
    late FakeTransport transport;
    late List<TvServiceEvent> events;
    late StreamSubscription<TvServiceEvent> sub;

    Future<void> start({Completer<void>? startDelay}) async {
      clock = FakeClock();
      transport = FakeTransport(clock: clock, startDelay: startDelay);
      events = [];
      sub = TvMdnsBrowser(clock: clock, transport: transport).browse(['_ANDROIDTVREMOTE2._tcp.']).listen(events.add);
      await Future<void>.delayed(Duration.zero);
    }

    tearDown(() => sub.cancel());

    test('an A record of the wrong size is skipped, nothing crashes', () async {
      await start();
      // The TV's records plus a 5-byte A record for the same host.
      final tv =
          (Answer()
                ..ptr(v2type, instance)
                ..srv(instance, 'Android.local', 37123)
                ..a('Android.local', '192.168.0.20'))
              .bytes();
      final withBad = Uint8List.fromList([
        ...tv.sublist(0, 7),
        tv[7] + 1,
        ...tv.sublist(8),
        ...Answer._name('Android.local'),
        0,
        1,
        0x80,
        1,
        0,
        0,
        0,
        120,
        0,
        5,
        1,
        2,
        3,
        4,
        5,
      ]);
      transport.deliver(withBad);
      expect(events.single.service.addresses.map((a) => a.address), ['192.168.0.20']);
    });

    test('types are matched without case or trailing dot', () async {
      await start();
      transport.deliver(fullTv().bytes());
      expect(events.single, isA<TvServiceFound>());
    });

    test('cancelled while starting: the transport is closed once started', () async {
      final gate = Completer<void>();
      await start(startDelay: gate);
      await sub.cancel();
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(transport.closed, isTrue);
      expect(transport.sent, isEmpty);
    });

    test('a PTR that never resolves does not cause a question storm', () async {
      await start();
      transport.sent.clear();
      for (var i = 0; i < 50; i++) {
        transport.deliver((Answer()..ptr(v2type, instance)).bytes());
      }
      final srvQuestions = transport.sent.expand((m) => m.questions).where((q) => q.type == DnsType.srv).length;
      // 50 packets over 5 s: asked at 0, 1, 3 s.
      expect(srvQuestions, lessThanOrEqualTo(4));
    });

    test('a goodbye from one interface keeps the service from another', () async {
      await start();
      transport
        ..deliver(fullTv().bytes(), '192.168.0.20')
        ..deliver(fullTv().bytes(), '10.0.0.7')
        ..deliver((Answer()..ptr(v2type, instance, ttl: 0)).bytes(), '10.0.0.7');
      clock.advance(const Duration(seconds: 2));
      expect(events.whereType<TvServiceLost>(), isEmpty);
    });

    test('TXT keys: no case, first wins, empty keys ignored', () async {
      await start();
      transport.deliver((fullTv()..txt(instance, ['V=2', 'v=3', '=x', 'flag'])).bytes());
      expect(events.single.service.txt, {'v': '2', 'flag': ''});
    });

    test('records of other services are not kept', () async {
      await start();
      final noise = Answer();
      for (var i = 0; i < 2000; i++) {
        noise.a('host$i.local', '10.1.${i ~/ 250}.${i % 250 + 1}');
      }
      transport
        ..deliver(noise.bytes())
        ..deliver(fullTv().bytes());
      // The TV's host is not among the noise; only its address shows.
      expect(events.single.service.addresses, hasLength(1));
    });

    test('records are refreshed at 80 % of their TTL', () async {
      await start();
      transport.deliver(fullTv().bytes());
      transport.sent.clear();
      clock.advance(const Duration(seconds: 97)); // 80 % of 120 s
      final asked = transport.sent.expand((m) => m.questions).toList();
      expect(asked.map((q) => (q.name, q.type)), contains((instance, DnsType.srv)));
      expect(asked.map((q) => (q.name, q.type)), contains(('Android.local', DnsType.a)));
    });
  });
}
