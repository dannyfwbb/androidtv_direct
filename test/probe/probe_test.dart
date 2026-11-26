// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  test('reads the certificate, sends nothing and closes', () async {
    final connections = <FakeTvConnection>[];
    final received = <int?>[];
    final tv = await startFakeTv(
      onPairing: (c) async {
        connections.add(c);
        received.add((await c.receive(timeout: const Duration(seconds: 10)))?.length);
      },
    );
    final identity = await TvProbe.identify(InternetAddress.loopbackIPv4, port: tv.pairingPort, identity: testClient());
    expect(identity.certificateDer, tv.certificateDer);
    await until(() => received.isNotEmpty);
    expect(received, [null]);
    await connections.single.done.timeout(const Duration(seconds: 1));
  });

  test('a port where nothing listens has no service', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await expectLater(
      TvProbe.identify(InternetAddress.loopbackIPv4, port: port, identity: testClient()),
      throwsA(isA<TvNoServiceException>()),
    );
  });

  test('cancelOn stops a probe that waits for the handshake', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    final cancel = Completer<void>();
    final outcome = TvProbe.identify(
      InternetAddress.loopbackIPv4,
      port: server.port,
      identity: testClient(),
      timeout: const Duration(seconds: 30),
      cancelOn: cancel.future,
    );
    await until(() => held.isNotEmpty);
    cancel.complete();
    await expectLater(outcome.timeout(const Duration(seconds: 5)), throwsA(isA<TvCancelledException>()));
  });
}
