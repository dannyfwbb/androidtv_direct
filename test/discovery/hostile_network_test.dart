// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_mdns.dart';

/// A network that sends well-formed answers with odd values (TTLs of 0 and 2^32-1, port 0, names in other cases,
/// records pointing at each other, odd TXT strings, every kind of address) and damaged packets, with time jumping
/// between them. The browser must never fail, and what it reports must be consistent: every service it reports is
/// complete and of a browsed type, an update or a loss follows a find, and a service is found again only after it
/// was lost.
void main() {
  final seeds = 40 * int.parse(Platform.environment['FUZZ_SCALE'] ?? '1');
  for (var seed = 0; seed < seeds; seed++) {
    test('seed $seed', () async {
      final random = Random(seed);
      final odd = _OddAnswers(random);
      final clock = FakeClock();
      final transport = FakeTransport(clock: clock);
      final errors = <Object>[];
      final events = <TvServiceEvent>[];
      final subscription = TvMdnsBrowser(
        clock: clock,
        transport: transport,
      ).browse(TvServiceType.all).listen(events.add, onError: errors.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 300; i++) {
        transport.deliver(odd.packet(), odd.sender());
        if (random.nextInt(10) == 0) clock.advance(Duration(seconds: random.nextInt(5000)));
      }
      clock.advance(const Duration(days: 2));

      expect(errors, isEmpty);
      final known = <String>{};
      for (final event in events) {
        final service = event.service;
        final key = '${service.type}/${service.instance}'.toLowerCase();
        expect(TvServiceType.all, contains(service.type), reason: '$service');
        expect(service.port, inInclusiveRange(1, 65535), reason: '$service');
        expect(service.addresses, isNotEmpty, reason: '$service');
        expect(service.instance, isNotEmpty, reason: '$service');
        switch (event) {
          case TvServiceFound():
            expect(known.add(key), isTrue, reason: 'found twice: $service');
          case TvServiceUpdated():
            expect(known, contains(key), reason: 'updated before found: $service');
          case TvServiceLost():
            expect(known.remove(key), isTrue, reason: 'lost before found: $service');
        }
      }
      expect(known, isEmpty, reason: 'two days later every record has expired');
    });
  }
}

/// Answers about a few names, so that records meet: some well-formed with odd values, some damaged.
final class _OddAnswers {
  _OddAnswers(this._random);

  final Random _random;

  static const List<String> _types = [
    '${TvServiceType.v2}.local',
    '${TvServiceType.v1}.local',
    '_AndroidTvRemote2._TCP.local',
    '_other._tcp.local',
  ];
  static const List<String> _hosts = ['Android.local', 'android.LOCAL', 'tv-2.local', 'Living room TV.local'];
  static const List<String> _addresses = [
    '192.168.0.20',
    '10.0.0.7',
    '127.0.0.1',
    '0.0.0.0',
    '169.254.1.1',
    'fe80::1',
    '2001:db8::5',
    '::1',
  ];
  static const List<int> _ttls = [0, 1, 120, 4500, 0x7fffffff, 0xffffffff];
  static const List<int> _ports = [0, 1, 6466, 37123, 65535];
  static const List<String> _txt = ['', '=', 'bt=', 'bt=AA:BB:CC:DD:EE:FF', 'BT=x', 'noequals', 'k=v=w'];

  T _pick<T>(List<T> from) => from[_random.nextInt(from.length)];

  String _instance() => '${_pick(['Living room TV', 'TV', 'тв', 'a.b', ''])}.${_pick(_types)}';

  String sender() => _pick(['192.168.0.20', '192.168.0.21', 'fe80::1%2']);

  Uint8List packet() {
    final answer = Answer();
    for (var n = 1 + _random.nextInt(4); n > 0; n--) {
      final ttl = _pick(_ttls);
      switch (_random.nextInt(6)) {
        case 0 || 1:
          answer.ptr(_pick(_types), _random.nextInt(8) == 0 ? _pick(_types) : _instance(), ttl: ttl);
        case 2:
          answer.srv(_instance(), _random.nextInt(8) == 0 ? _instance() : _pick(_hosts), _pick(_ports), ttl: ttl);
        case 3:
          answer.txt(_instance(), [for (var i = _random.nextInt(4); i > 0; i--) _pick(_txt)], ttl: ttl);
        case 4:
          final address = _pick(_addresses);
          if (address.contains(':')) {
            answer.aaaa(_pick(_hosts), address, ttl: ttl);
          } else {
            answer.a(_pick(_hosts), address, ttl: ttl);
          }
        case _:
          answer.a(_instance(), _pick(_addresses.where((a) => !a.contains(':')).toList()), ttl: ttl);
      }
    }
    final bytes = answer.bytes();
    if (_random.nextInt(5) != 0) return bytes;
    // A damaged one: a byte changed, or the end cut off.
    final damaged = Uint8List.fromList(bytes);
    damaged[_random.nextInt(damaged.length)] = _random.nextInt(256);
    return _random.nextBool() ? damaged : Uint8List.sublistView(damaged, 0, _random.nextInt(damaged.length));
  }
}
