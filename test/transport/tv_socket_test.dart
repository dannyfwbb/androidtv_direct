// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  final client = testClient();

  Future<TvSocket> connect(FakeTv tv, {TvTracer? tracer}) => TvSocket.connect(
    InternetAddress.loopbackIPv4,
    tv.remotePort,
    context: client.securityContext(),
    timeout: const Duration(seconds: 5),
    tracer: tracer,
  );

  Future<FakeTv> fakeTv(FakeTvHandler onRemote) => startFakeTv(onRemote: onRemote);

  test('a frame over the limit ends the connection as a protocol error', () async {
    final tv = await fakeTv((c) async {
      c
        ..send(Uint8List(2 << 20))
        ..flush();
      await c.done;
    });
    final socket = await connect(tv);
    await expectLater(socket.receive(timeout: const Duration(seconds: 5)), throwsA(isA<TvProtocolException>()));
    expect(await socket.done, isA<TvProtocolException>());
  });

  test('frames that arrived before the TV closed are still read, then the close', () async {
    final tv = await fakeTv(
      (c) => c.run([
        const FakeTvSend([1]),
        const FakeTvSend([2]),
        const FakeTvClose(),
      ]),
    );
    final socket = await connect(tv);
    await socket.done;
    expect(await socket.receive(timeout: const Duration(seconds: 1)), [1]);
    expect(await socket.receive(timeout: const Duration(seconds: 1)), [2]);
    await expectLater(socket.receive(timeout: const Duration(seconds: 1)), throwsA(isA<TvClosedException>()));
  });

  test('closing from this side completes done with null; receive is then a cancellation', () async {
    final tv = await fakeTv((c) => c.done);
    final socket = await connect(tv);
    await socket.close();
    expect(await socket.done, isNull);
    await expectLater(socket.receive(timeout: const Duration(seconds: 1)), throwsA(isA<TvCancelledException>()));
  });

  test('traces kinds and sizes, bytes only at the raw level', () async {
    final tv = await fakeTv((c) async {
      await c.receive();
      await c.close();
    });
    for (final level in TvTraceLevel.values) {
      final events = <TvTraceEvent>[];
      final socket = await connect(tv, tracer: TvTracer(events.add, level: level));
      socket.send(Uint8List.fromList([9, 9]), kind: 'test');
      await socket.done;
      final message = events.whereType<TvMessageTrace>().single;
      expect((message.outgoing, message.kind, message.length), (true, 'test', 2));
      expect(message.raw, level == TvTraceLevel.raw ? [9, 9] : isNull);
      expect(events.whereType<TvNoteTrace>(), isNotEmpty);
    }
  });

  test('a TV that accepts TCP but never finishes TLS times out, and is not called unreachable', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    final clock = FakeClock();
    final outcome = TvSocket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
      context: client.securityContext(),
      timeout: const Duration(seconds: 5),
      clock: clock,
    );
    await until(() => held.isNotEmpty && clock.pendingTimers > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    clock.advance(const Duration(seconds: 5));
    await expectLater(outcome, throwsA(isA<TvTimeoutException>()));
  });
}
