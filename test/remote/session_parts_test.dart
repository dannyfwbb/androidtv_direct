// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/text/field_tracker.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:test/test.dart';

import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

/// What the session promises its parts: each is told in order, never after it detached or the session ended, and
/// [SessionPart.onEnd] is its last call; a part that throws ends the session with the error as the cause.
void main() {
  late FakeSession fake;
  late RemoteSession session;

  Future<void> connect({TvTracer? tracer}) async {
    fake = FakeSession();
    final tv = await startFakeTv(onRemote: fake.serve);
    final socket = await TvSocket.connect(
      InternetAddress.loopbackIPv4,
      tv.remotePort,
      context: testClient().securityContext(),
      timeout: const Duration(seconds: 5),
      tracer: tracer,
    );
    session = RemoteSession(
      socket,
      {...TvFeature.defaults, TvFeature.ime},
      clock: TvClock.system,
      idleTimeout: const Duration(seconds: 16),
    );
    addTearDown(session.close);
    await session.start(const Duration(seconds: 5));
  }

  final focus = FocusReport(
    app: FocusedApp(packageName: 'app'),
    textField: TextFieldState(text: 'x'),
  );

  test('a part that throws ends the session with the error as the cause; the others are told the end', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await connect();
      final first = _Recorder(onMessage: (_) => throw StateError('a bug'));
      final second = _Recorder();
      session
        ..attach(first)
        ..attach(second);
      await fake.sendMessage(focus);
      await until(() => session.isClosed);
      expect(await session.done, isA<TvProtocolException>().having((e) => e.cause, 'cause', isA<StateError>()));
      expect(second.calls, ['end: protocol'], reason: 'not told the message after the session ended');
      expect(first.calls.last, 'end: protocol');
    }, (error, _) => errors.add(error));
    expect(errors.single, isA<StateError>(), reason: 'the bug is not swallowed');
  });

  test('a part detached by an earlier one during a message is not told it', () async {
    await connect();
    final later = _Recorder();
    final earlier = _Recorder(onMessage: (_) => session.detach(later));
    session
      ..attach(earlier)
      ..attach(later);
    await fake.sendMessage(focus);
    await until(() => earlier.calls.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(later.calls, isEmpty);
  });

  test('a part that ends the session in onMessage gets no field event after its end', () async {
    await connect();
    final part = _Recorder(onMessage: (_) => unawaited(session.close()));
    session.attach(part);
    await fake.sendMessage(focus);
    await until(() => session.isClosed);
    expect(part.calls, ['message: focusReport', 'end: cancelled']);
  });

  test('a part whose end throws does not keep the others from theirs, or the session from closing', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await connect();
      final throwing = _Recorder(onEnd: (_) => throw StateError('a bug'));
      final other = _Recorder();
      session
        ..attach(throwing)
        ..attach(other);
      await session.close();
      expect(other.calls, ['end: cancelled']);
      await expectLater(session.changes.isEmpty, completion(isTrue), reason: 'the streams are closed');
    }, (error, _) => errors.add(error));
    expect(errors.single, isA<StateError>());
  });

  test("the app's tracer throwing does not break the connection", () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await connect(tracer: TvTracer((_) => throw StateError('the app')));
      final part = _Recorder();
      session.attach(part);
      await fake.sendMessage(focus);
      await until(() => part.calls.isNotEmpty);
      expect(session.isClosed, isFalse);
      await session.close();
    }, (error, _) => errors.add(error));
    expect(errors, isNotEmpty);
    expect(errors, everyElement(isA<StateError>()));
  });
}

final class _Recorder extends SessionPart {
  _Recorder({void Function(RemoteEnvelope)? onMessage, void Function(TvRemoteException)? onEnd})
    : _onMessage = onMessage,
      _onEnd = onEnd;

  final void Function(RemoteEnvelope)? _onMessage;
  final void Function(TvRemoteException)? _onEnd;
  final List<String> calls = [];

  @override
  void onMessage(RemoteEnvelope message) {
    calls.add('message: ${message.kind}');
    _onMessage?.call(message);
  }

  @override
  void onFieldEvent(FieldEvent event) => calls.add('field: ${event.name}');

  @override
  void onEnd(TvRemoteException reason) {
    calls.add('end: ${reason.code.name}');
    _onEnd?.call(reason);
  }
}
