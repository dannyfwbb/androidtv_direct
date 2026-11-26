// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/probe/scan.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  test("finds a TV's remote service, and only that, sending nothing", () async {
    final received = <int?>[];
    final tv = await startFakeTv(
      identityName: 'remote-tv',
      onPairing: (c) async => received.add((await c.receive(timeout: const Duration(seconds: 5)))?.length),
    );
    final results = await TvProbe.scan(
      [InternetAddress.loopbackIPv4, InternetAddress('127.0.0.2')],
      port: tv.pairingPort,
      identity: testClient(),
    ).toList();
    expect(results.single.host, InternetAddress.loopbackIPv4);
    expect(results.single.tv.model, 'Test TV');
    expect(results.single.tv.macAddress, 'AA:BB:CC:DD:EE:FF');
    await until(() => received.isNotEmpty);
    expect(received, [null], reason: 'the connection closed without a message');
  });

  test('a TLS server whose certificate is not a TV remote service is left out', () async {
    final other = await startFakeTv();
    final results = TvProbe.scan([InternetAddress.loopbackIPv4], port: other.pairingPort, identity: testClient());
    expect(await results.toList(), isEmpty);
  });

  test('never more than the concurrency at once, and every host tried', () async {
    var running = 0;
    var most = 0;
    final tried = <Object>[];
    Future<TvIdentity> identify(Object host) async {
      tried.add(host);
      most = ++running > most ? running : most;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      throw const TvUnreachableException('nobody');
    }

    final results = await scanHosts(List.generate(20, (i) => 'host$i'), concurrency: 3, identify: identify).toList();
    expect(results, isEmpty);
    expect((tried.length, most), (20, 3));
  });

  test('pausing stops new probes; resuming goes on; cancelling stops without results', () async {
    final tried = <Object>[];
    Future<TvIdentity> identify(Object host) async {
      tried.add(host);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      throw const TvUnreachableException('nobody');
    }

    final subscription = scanHosts(List.generate(10, (i) => i), concurrency: 2, identify: identify).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final whilePaused = tried.length;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(tried.length, whilePaused);
    subscription.resume();
    await until(() => tried.length > whilePaused);
    await subscription.cancel();
    final atCancel = tried.length;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(tried.length, atCancel);
  });

  test('an error from the host list is reported and ends the scan', () async {
    Iterable<Object> hosts() sync* {
      yield 'a';
      throw StateError('broken list');
    }

    final scan = scanHosts(hosts(), concurrency: 2, identify: (_) async => throw const TvUnreachableException('x'));
    await expectLater(scan, emitsInOrder([emitsError(isStateError), emitsDone]));
  });

  test('a probe failing with something other than a TV error is no result, and the scan still ends', () async {
    final results = await scanHosts(
      [1, 2],
      concurrency: 2,
      identify: (_) async => throw ArgumentError('bad host'),
    ).toList();
    expect(results, isEmpty);
  });

  test('a concurrency below one is refused', () {
    expect(() => TvProbe.scan(const ['a'], concurrency: 0), throwsArgumentError);
  });
}
