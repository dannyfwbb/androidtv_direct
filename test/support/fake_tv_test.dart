// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/protocol/frame.dart';
import 'package:test/test.dart';

import 'fake_tv.dart';
import 'fixtures.dart';
import 'hex.dart';

/// A bare TLS client with a test identity, reading frames.
final class TestClient {
  TestClient._(this.socket) {
    socket.listen(_onChunk, onError: (Object _) {}, onDone: closed.complete);
    // Write errors after the TV went away surface here; the tests look at what was read instead.
    socket.done.ignore();
  }

  static Future<TestClient> connect(int port, {String identity = 'client'}) async {
    final id = testIdentity(identity);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(id.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
    return TestClient._(
      await SecureSocket.connect(InternetAddress.loopbackIPv4, port, context: context, onBadCertificate: (_) => true),
    );
  }

  final SecureSocket socket;
  final FrameReader _reader = FrameReader();
  final List<int> chunkSizes = [];
  final List<Uint8List> frames = [];
  final Completer<void> closed = Completer();

  void send(List<int> body) => socket.add(encodeFrame(body));

  void _onChunk(Uint8List chunk) {
    chunkSizes.add(chunk.length);
    frames.addAll(_reader.add(chunk));
  }
}

void main() {
  final client = testIdentity('client').certificatePem;

  test('exchanges frames over TLS by script, and shows its certificate', () async {
    final tv = await FakeTv.start(
      trusted: [client],
      onRemote: (c) => c.run([
        FakeTvSend(unhex('c202020801')),
        FakeTvExpect.bytes(unhex('4a020801')),
        FakeTvSend(Uint8List(3000)),
        const FakeTvClose(),
      ]),
    );
    addTearDown(tv.close);
    final remote = await TestClient.connect(tv.remotePort);
    expect(remote.socket.peerCertificate!.der, tv.certificateDer);
    remote.send(unhex('4a020801'));
    await remote.closed.future.timeout(const Duration(seconds: 5));
    expect(remote.frames.map(hexEncode), ['c202020801', hexEncode(Uint8List(3000))]);
    expect(tv.errors, isEmpty);
  });

  test('records what goes against the script and closes', () async {
    final tv = await FakeTv.start(
      trusted: [client],
      onPairing: (c) => c.run([
        FakeTvExpect.bytes(const [1]),
      ]),
    );
    addTearDown(tv.close);
    final pairing = await TestClient.connect(tv.pairingPort);
    pairing.send(const [2]);
    await pairing.closed.future.timeout(const Duration(seconds: 5));
    expect(tv.errors, ['step 1: expected 01, got 02']);
  });

  test('a client whose certificate the TV does not trust fails the handshake', () async {
    final tv = await FakeTv.start(trusted: [client]);
    addTearDown(tv.close);
    try {
      // With TLS 1.3 the client may finish its side of the handshake before the TV checks the certificate; the TV
      // then closes the connection.
      final other = await TestClient.connect(tv.remotePort, identity: 'other');
      await other.closed.future.timeout(const Duration(seconds: 5));
    } on IOException {
      // The handshake failed on the client's side too.
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tv.rejected, 1);
  });

  test('a frozen connection stays open and silent', () async {
    final frozen = Completer<FakeTvConnection>();
    final tv = await FakeTv.start(
      trusted: [client],
      onRemote: (c) async {
        await c.run([const FakeTvFreeze()]);
        frozen.complete(c);
      },
    );
    addTearDown(tv.close);
    final remote = await TestClient.connect(tv.remotePort);
    remote.send(const [1]);
    await frozen.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remote.frames, isEmpty);
    expect(remote.closed.isCompleted, isFalse);
  });

  for (final mode in FakeTvChunking.values) {
    test('${mode.name} chunking delivers the same messages in its own pieces', () async {
      final tv = await FakeTv.start(
        trusted: [client],
        onRemote: (c) {
          c.chunking = mode;
          return c.run([FakeTvSend(Uint8List(50)), FakeTvSend(Uint8List(50)), const FakeTvClose()]);
        },
      );
      addTearDown(tv.close);
      final remote = await TestClient.connect(tv.remotePort);
      await remote.closed.future.timeout(const Duration(seconds: 5));
      expect(remote.frames.map(hexEncode), [hexEncode(Uint8List(50)), hexEncode(Uint8List(50))]);
      expect(remote.chunkSizes.fold(0, (a, b) => a + b), 102);
      // How reads split is up to the network stack; only the extremes are certain enough to check.
      if (mode == FakeTvChunking.coalesce) expect(remote.chunkSizes, [102]);
      if (mode == FakeTvChunking.bytes) expect(remote.chunkSizes.length, greaterThan(10));
    });
  }
}
