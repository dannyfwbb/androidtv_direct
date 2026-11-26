// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/transport/secure_link.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';

/// The write side of a connection: queued writes, a close that sends them first and is bounded in time.
void main() {
  final client = testClient();

  Future<TvSocket> connect(int port) => TvSocket.connect(
    InternetAddress.loopbackIPv4,
    port,
    context: client.securityContext(),
    timeout: const Duration(seconds: 5),
  );

  test('megabytes sent and closed at once all arrive, in order, before the close', () async {
    final received = Completer<List<int>>();
    final tv = await startFakeTv(
      onRemote: (c) async {
        final lengths = <int>[];
        while (true) {
          final frame = await c.receive(timeout: const Duration(seconds: 10));
          if (frame == null) break;
          lengths.add(frame[0]);
        }
        received.complete(lengths);
      },
    );
    final socket = await connect(tv.remotePort);
    for (var i = 0; i < 200; i++) {
      socket.send(Uint8List(20480)..[0] = i, kind: 'chunk');
    }
    await socket.close();
    expect(await received.future.timeout(const Duration(seconds: 10)), List.generate(200, (i) => i));
  });

  test('closing is bounded also when only TLS itself still holds unsent bytes', () async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      FakeTv.serverContext(trusted: [testIdentity('client').certificatePem]),
      requestClientCertificate: true,
    );
    final held = <SecureSocket>[];
    server.listen((socket) {
      socket.setRawOption(_bufferSize(receive: true));
      held.add(socket..listen((_) {}).pause());
    });
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    final plain = await RawSocket.connect(InternetAddress.loopbackIPv4, server.port)
      ..setRawOption(_bufferSize(receive: false));
    final tls = await RawSecureSocket.secure(plain, context: client.securityContext(), onBadCertificate: (_) => true);
    final link = SecureLink(tls, plain)..listen(onData: (_) {}, onEnd: ([_]) {});
    // Fill TLS's buffers directly, past what the kernel takes: the link's own queue stays empty.
    // Fill TLS's own buffers, past the kernel's (made small): the link's own queue stays empty.
    final chunk = Uint8List(100);
    for (var refused = 0; refused < 200;) {
      refused = tls.write(chunk) < chunk.length ? refused + 1 : 0;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final stopwatch = Stopwatch()..start();
    await link.close().timeout(const Duration(seconds: 10));
    expect(stopwatch.elapsed, lessThan(SecureLink.flushTimeout * 2));
  });

  test('closing towards a TV that stopped reading gives up after the flush timeout', () async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      FakeTv.serverContext(trusted: [testIdentity('client').certificatePem]),
      requestClientCertificate: true,
    );
    final held = <SecureSocket>[];
    // Never read: the TCP buffers fill and the client's writes queue up.
    server.listen((socket) => held.add(socket..listen((_) {}).pause()));
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    final socket = await connect(server.port);
    for (var i = 0; i < 1000; i++) {
      socket.send(Uint8List(20480), kind: 'chunk');
    }
    final stopwatch = Stopwatch()..start();
    await socket.close().timeout(const Duration(seconds: 10));
    // It waited for the writes to go out, then cut the connection.
    expect(stopwatch.elapsed, greaterThanOrEqualTo(SecureLink.flushTimeout));
    expect(stopwatch.elapsed, lessThan(SecureLink.flushTimeout * 2));
    expect(await socket.done, isNull);
  });
}

/// A small socket buffer, so that a peer that does not read fills it quickly.
RawSocketOption _bufferSize({required bool receive}) {
  final linux = Platform.isLinux || Platform.isAndroid;
  final option = receive ? (linux ? 8 : 0x1002) : (linux ? 7 : 0x1001);
  return RawSocketOption.fromInt(RawSocketOption.levelSocket, option, 4096);
}
