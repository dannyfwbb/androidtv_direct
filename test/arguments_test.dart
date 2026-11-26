// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';
import 'support/fake_session.dart';
import 'support/fake_tv.dart';
import 'support/fixtures.dart';

/// Wrong arguments fail at the call with an [ArgumentError] naming the parameter, before anything is sent.
void main() {
  final identity = testClient();
  final lo = InternetAddress.loopbackIPv4;
  const zero = Duration.zero;

  Matcher refuses(String name) => throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name));

  test('connect', () async {
    Future<TvRemote> connect(
      Object host, {
      int port = 1,
      String? fingerprint,
      Duration connectTimeout = const Duration(seconds: 1),
      Duration startTimeout = const Duration(seconds: 1),
      Duration idleTimeout = const Duration(seconds: 1),
      Duration textGiveUp = const Duration(seconds: 1),
    }) => TvRemote.connect(
      host,
      identity: identity,
      fingerprint: fingerprint,
      port: port,
      connectTimeout: connectTimeout,
      startTimeout: startTimeout,
      idleTimeout: idleTimeout,
      textGiveUp: textGiveUp,
    );

    for (final host in <Object>['', '  ', ' 10.0.0.2', 'tv.local ', 42, Uri.parse('http://tv')]) {
      await expectLater(connect(host), refuses('host'), reason: '$host');
    }
    for (final port in [0, -1, 65536]) {
      await expectLater(connect(lo, port: port), refuses('port'), reason: '$port');
    }
    for (final fingerprint in ['', 'nonsense', 'ab' * 31, 'zz' * 32, '${'ab' * 32}0']) {
      await expectLater(connect(lo, fingerprint: fingerprint), refuses('fingerprint'), reason: fingerprint);
    }
    await expectLater(connect(lo, connectTimeout: zero), refuses('connectTimeout'));
    await expectLater(connect(lo, startTimeout: const Duration(seconds: -1)), refuses('startTimeout'));
    await expectLater(connect(lo, idleTimeout: zero), refuses('idleTimeout'));
    await expectLater(connect(lo, textGiveUp: zero), refuses('textGiveUp'));
  });

  test('a fingerprint in upper case is the same fingerprint', () async {
    final tv = await startFakeTv(onRemote: FakeSession().serve);
    final remote = await TvRemote.connect(
      lo,
      port: tv.remotePort,
      identity: identity,
      fingerprint: tvFingerprint.toUpperCase(),
    );
    await remote.close();
  });

  test('errors name the address, an IPv6 one in brackets', () async {
    final server = await ServerSocket.bind(lo, 0);
    final port = server.port;
    await server.close();
    for (final (host, shown) in [(lo, '127.0.0.1:$port'), ('127.0.0.1', '127.0.0.1:$port'), ('::1', '[::1]:$port')]) {
      await expectLater(
        TvRemote.connect(host, port: port, identity: identity, fingerprint: null),
        throwsA(isA<TvRemoteException>().having((e) => e.message, 'message', contains(shown))),
      );
    }
  });

  test('an identity needs a name with more than spaces', () async {
    await expectLater(TvClientIdentity.generate(now: DateTime.now(), commonName: '  '), refuses('commonName'));
  });

  test('pairing, probe and scan', () async {
    await expectLater(TvPairing.start(lo, identity: identity, clientName: ' '), refuses('clientName'));
    await expectLater(TvPairing.start(lo, identity: identity, clientName: 'x', timeout: zero), refuses('timeout'));
    await expectLater(TvProbe.identify(lo, identity: identity, port: 0), refuses('port'));
    await expectLater(TvProbe.identify(lo, identity: identity, timeout: zero), refuses('timeout'));
    expect(() => TvProbe.scan([lo], timeout: zero), refuses('timeout'));
    expect(() => TvProbe.scan([lo], port: 70000), refuses('port'));
    expect(() => TvProbe.scan([lo], concurrency: 0), refuses('concurrency'));
    expect(() => TvMdnsBrowser(maxQueryInterval: const Duration(milliseconds: 999)), refuses('maxQueryInterval'));
  });

  test('calls on a session', () async {
    final remote = (await FakeRemote.connect(features: {...TvFeature.defaults, TvFeature.voice})).remote;
    await expectLater(remote.setVolume(1, stepTimeout: zero), refuses('stepTimeout'));
    await expectLater(remote.setVolume(1, timeout: zero), refuses('timeout'));
    await expectLater(remote.startVoice(timeout: zero), refuses('timeout'));
    expect(remote.isClosed, isFalse);
  });
}
