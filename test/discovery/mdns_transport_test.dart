// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/discovery/mdns_transport.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_mdns.dart';

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
}
