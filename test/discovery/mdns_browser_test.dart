// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/discovery/dns_message.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_mdns.dart';

void main() {
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

  group('edge cases', () {
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
        ...Answer.labels('Android.local'),
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

    test('a flood of unrelated instances is bounded and a TV announced after it is still found', () async {
      await start();
      for (var i = 0; i < 3000; i++) {
        transport.deliver((Answer()..ptr(v2type, 'Fake $i.$v2type')).bytes(), '10.0.${i ~/ 250}.${i % 250 + 1}');
      }
      transport.deliver(fullTv().bytes());
      expect(events.whereType<TvServiceFound>().map((e) => e.service.instance), ['Living room TV']);
    });

    test('a TTL past 75 minutes is capped: a TV that went silent is lost after 75 minutes, not 136 years', () async {
      await start();
      transport.deliver(
        (Answer()
              ..ptr(v2type, instance, ttl: 0xffffffff)
              ..srv(instance, 'Android.local', 6466, ttl: 0xffffffff)
              ..a('Android.local', '192.168.0.20', ttl: 0xffffffff))
            .bytes(),
      );
      expect(events.single, isA<TvServiceFound>());
      for (var s = 0; s < 4501; s++) {
        clock.advance(const Duration(seconds: 1));
      }
      expect(events.last, isA<TvServiceLost>());
    });

    test('names in answers match without case; the instance keeps the case it was announced with', () async {
      await start();
      final upper = 'Big TV.${v2type.toUpperCase()}';
      transport.deliver(
        (Answer()
              ..ptr(v2type.toUpperCase(), upper)
              ..srv(upper.toLowerCase(), 'TV.LOCAL', 6466)
              ..a('tv.local', '192.168.0.30'))
            .bytes(),
      );
      expect(events.single.service.instance, 'Big TV');
      expect(events.single.service.address!.address, '192.168.0.30');
    });

    test('two TVs are two services; a new address is an update; each is lost on its own', () async {
      await start();
      transport
        ..deliver(fullTv().bytes())
        ..deliver(
          (Answer()
                ..ptr(v2type, 'Bedroom.$v2type')
                ..srv('Bedroom.$v2type', 'Bed.local', 6466)
                ..a('Bed.local', '192.168.0.21'))
              .bytes(),
          '192.168.0.21',
        );
      expect(events.whereType<TvServiceFound>().map((e) => e.service.instance), ['Living room TV', 'Bedroom']);
      transport.deliver((Answer()..a('Android.local', '192.168.0.99')).bytes());
      final updated = events.whereType<TvServiceUpdated>().single.service;
      expect(updated.addresses.map((a) => a.address), containsAll(['192.168.0.20', '192.168.0.99']));
      transport.deliver((Answer()..ptr(v2type, 'Bedroom.$v2type', ttl: 0)).bytes(), '192.168.0.21');
      clock.advance(const Duration(seconds: 2));
      expect(events.whereType<TvServiceLost>().map((e) => e.service.instance), ['Bedroom']);
    });
  });
}
