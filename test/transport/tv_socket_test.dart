// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
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

  /// A server that accepts TCP and never answers TLS; [closed] completes per connection when the client ends it.
  Future<({int port, List<Future<void>> closed})> holdingServer() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    final closed = <Future<void>>[];
    server.listen((socket) {
      held.add(socket);
      closed.add(socket.drain<void>().catchError((_) {}));
    });
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    return (port: server.port, closed: closed);
  }

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

  test('a TV that accepts TCP but never finishes TLS times out, is not called unreachable, and is let go', () async {
    final server = await holdingServer();
    final clock = FakeClock();
    final outcome = TvSocket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
      context: client.securityContext(),
      timeout: const Duration(seconds: 5),
      clock: clock,
    );
    await until(() => server.closed.isNotEmpty && clock.pendingTimers > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    clock.advance(const Duration(seconds: 5));
    await expectLater(outcome, throwsA(isA<TvTimeoutException>()));
    await server.closed.single.timeout(const Duration(seconds: 5));
  });

  group('receive', () {
    test('a timed-out receive leaves the connection usable: the next frame still arrives', () async {
      final sent = Completer<void>();
      final tv = await fakeTv((c) async {
        await sent.future;
        c
          ..send([1, 2, 3])
          ..flush();
        await c.done;
      });
      final clock = FakeClock();
      final socket = await TvSocket.connect(
        InternetAddress.loopbackIPv4,
        tv.remotePort,
        context: client.securityContext(),
        timeout: const Duration(seconds: 5),
        clock: clock,
      );
      addTearDown(socket.close);
      final first = socket.receive(timeout: const Duration(seconds: 1));
      await until(() => clock.pendingTimers > 0);
      clock.advance(const Duration(seconds: 1));
      await expectLater(first, throwsA(isA<TvTimeoutException>()));
      expect(socket.isClosed, isFalse);
      sent.complete();
      expect(await socket.receive(timeout: const Duration(seconds: 5)), [1, 2, 3]);
    });

    test('a second receive while one waits, or a receive after listen, is refused', () async {
      final tv = await fakeTv((c) => c.done);
      final socket = await connect(tv);
      addTearDown(socket.close);
      final waiting = socket.receive(timeout: const Duration(seconds: 5));
      expect(() => socket.receive(timeout: const Duration(seconds: 1)), throwsStateError);
      unawaited(socket.close());
      await expectLater(waiting, throwsA(isA<TvCancelledException>()));
    });

    test('listen hands over the frames that arrived before it, in order, then the later ones', () async {
      final more = Completer<void>();
      final tv = await fakeTv((c) async {
        for (final i in [1, 2, 3]) {
          c.send([i]);
        }
        c.flush();
        await more.future;
        c
          ..send([4])
          ..flush();
        await c.done;
      });
      final socket = await connect(tv);
      addTearDown(socket.close);
      // Read one, so the others are known to have been buffered before listen.
      expect(await socket.receive(timeout: const Duration(seconds: 5)), [1]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final frames = <List<int>>[];
      socket.listen(frames.add, onEnd: (_) {});
      expect(() => socket.receive(timeout: const Duration(seconds: 1)), throwsStateError);
      more.complete();
      await until(() => frames.length == 3);
      expect(frames, [
        [2],
        [3],
        [4],
      ]);
    });

    test('the TV dropping the connection ends it: pending and later receives fail the same way', () async {
      final tv = await fakeTv((c) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await c.close();
      });
      final socket = await connect(tv);
      final pending = socket.receive(timeout: const Duration(seconds: 5));
      await expectLater(pending, throwsA(isA<TvClosedException>()));
      await expectLater(socket.receive(timeout: const Duration(seconds: 1)), throwsA(isA<TvClosedException>()));
      expect(await socket.done, isA<TvClosedException>());
      socket.send(Uint8List(1), kind: 'after the end');
    });
  });

  group('connect', () {
    test('a cancellation that is already due stops the attempt with TvCancelledException', () async {
      final tv = await fakeTv((c) => c.done);
      await expectLater(
        TvSocket.connect(
          InternetAddress.loopbackIPv4,
          tv.remotePort,
          context: client.securityContext(),
          timeout: const Duration(seconds: 5),
          cancelOn: Future.value(),
        ),
        throwsA(isA<TvCancelledException>()),
      );
    });

    test('cancelling during the TLS handshake stops it with TvCancelledException and ends the connection', () async {
      final server = await holdingServer();
      final cancel = Completer<void>();
      final outcome = TvSocket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        context: client.securityContext(),
        timeout: const Duration(seconds: 30),
        cancelOn: cancel.future,
      );
      await until(() => server.closed.isNotEmpty);
      cancel.complete();
      await expectLater(outcome.timeout(const Duration(seconds: 5)), throwsA(isA<TvCancelledException>()));
      await server.closed.single.timeout(const Duration(seconds: 5));
    });

    test('a cancellation at any moment of the attempt: a working connection, or none left open', () async {
      final tv = await fakeTv((c) async {
        // Answers one frame, to show the connection works.
        if (await c.receive(timeout: const Duration(seconds: 5)) case final frame?) {
          c
            ..send(frame)
            ..flush();
        }
        await c.done;
      });
      final outcomes = <String>{};
      for (var i = 0; i < 60; i++) {
        final cancel = Completer<void>();
        final attempt = TvSocket.connect(
          InternetAddress.loopbackIPv4,
          tv.remotePort,
          context: client.securityContext(),
          timeout: const Duration(seconds: 5),
          cancelOn: cancel.future,
        );
        // From before the TCP connection to after the handshake, in steps of a fraction of a millisecond.
        Timer(Duration(microseconds: i * 150), cancel.complete);
        try {
          final socket = await attempt;
          outcomes.add('connected');
          socket.send(Uint8List.fromList([i]), kind: 'echo');
          expect(await socket.receive(timeout: const Duration(seconds: 5)), [i]);
          await socket.close();
        } on TvCancelledException {
          outcomes.add('cancelled');
        }
      }
      await until(() => tv.openConnections == 0);
      expect(outcomes, containsAll(['connected', 'cancelled']), reason: 'the cancellations should hit both sides');
    });

    test('a cancellation after the connection opened changes nothing', () async {
      final tv = await fakeTv((c) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        c
          ..send([7])
          ..flush();
        await c.done;
      });
      final cancel = Completer<void>();
      final socket = await TvSocket.connect(
        InternetAddress.loopbackIPv4,
        tv.remotePort,
        context: client.securityContext(),
        timeout: const Duration(seconds: 5),
        cancelOn: cancel.future,
      );
      addTearDown(socket.close);
      cancel.complete();
      expect(await socket.receive(timeout: const Duration(seconds: 5)), [7]);
      expect(socket.isClosed, isFalse);
    });

    test(
      'a server that closes during the TLS handshake closed the connection; one that is not TLS is a protocol error',
      () async {
        final closing = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        closing.listen((socket) => socket.close());
        final garbage = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        garbage.listen((socket) => socket..add(List.filled(64, 0x41)));
        addTearDown(() => Future.wait([closing.close(), garbage.close()]));
        Future<TvSocket> to(int port) => TvSocket.connect(
          InternetAddress.loopbackIPv4,
          port,
          context: client.securityContext(),
          timeout: const Duration(seconds: 5),
        );
        await expectLater(to(closing.port), throwsA(isA<TvClosedException>()));
        await expectLater(to(garbage.port), throwsA(isA<TvProtocolException>()));
      },
    );

    test('a closed port is TvNoServiceException', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      await expectLater(
        TvSocket.connect(
          InternetAddress.loopbackIPv4,
          port,
          context: client.securityContext(),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<TvNoServiceException>()),
      );
    });

    test('a host that cannot be resolved is TvUnreachableException', () async {
      await expectLater(
        TvSocket.connect(
          'no-such-tv.invalid',
          6466,
          context: client.securityContext(),
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<TvUnreachableException>()),
      );
    });
  });
}
