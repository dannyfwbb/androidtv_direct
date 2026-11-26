// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/discovery/dns_message.dart';
import 'package:test/test.dart';

import '../support/fake_mdns.dart';
import '../support/fuzz.dart';

void main() {
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

  test('fuzz: hostile packets only ever fail as FormatException', () {
    final avahi = File('test/fixtures/mdns/avahi_legacy_answer.bin').readAsBytesSync();
    final ours = Answer()
      ..ptr(v2type, instance)
      ..srv(instance, 'Android.local', 6466)
      ..txt(instance, ['bt=AA:BB:CC:DD:EE:FF', 'empty=', 'flag'])
      ..a('Android.local', '192.168.0.20')
      ..aaaa('Android.local', 'fe80::1');
    fuzz(DnsMessage.decode, seeds: [avahi, ours.bytes()], count: 50000);
  });

  test('records of unknown types are kept raw; other classes are dropped; a cache-flush bit is read', () {
    final message = DnsMessage.decode(
      Uint8List.fromList([
        0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0, //
        ...Answer.labels('x.local'), 0, 99, 0x80, 1, 0, 0, 0, 10, 0, 2, 7, 8, // type 99, IN, cache-flush
        ...Answer.labels('y.local'), 0, 1, 0, 3, 0, 0, 0, 10, 0, 4, 1, 2, 3, 4, // A, class CH
      ]),
    );
    final record = message.answers.single;
    expect((record.name, record.type, record.cacheFlush), ('x.local', 99, true));
    expect((record.data as DnsRaw).bytes, [7, 8]);
  });
}
