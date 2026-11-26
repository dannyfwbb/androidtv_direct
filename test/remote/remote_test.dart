// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  final recordedApp =
      (RemoteEnvelope.fromTv(sessionMessage('focusReport', outgoing: false)) as FocusReport).app!.packageName;
  final tvFingerprint = TvIdentity.fromCertificate(pemOf(testIdentity('tv').certificatePem)).fingerprint;

  Future<(FakeTv, FakeSession)> fakeTv([FakeSession? session]) async {
    final fake = session ?? FakeSession();
    return (await startFakeTv(onRemote: fake.serve), fake);
  }

  Future<TvRemote> connect(
    FakeTv tv, {
    String? fingerprint,
    Set<TvFeature> features = TvFeature.defaults,
    TvClock clock = TvClock.system,
    Future<void>? cancelOn,
    TvTracer? tracer,
    TvClientInfo client = TvClientInfo.standard,
  }) => TvRemote.connect(
    InternetAddress.loopbackIPv4,
    port: tv.remotePort,
    identity: testClient(),
    fingerprint: fingerprint ?? tvFingerprint,
    features: features,
    clock: clock,
    cancelOn: cancelOn,
    tracer: tracer,
    client: client,
  );

  group('start', () {
    test('answers the setup and activation, and is ready with the state the TV reported', () async {
      final (tv, fake) = await fakeTv();
      final remote = await connect(tv);
      expect(remote.device.model, 'AOSP TV on x86');
      expect(remote.device.serviceVersion, '7.00.999235495');
      expect(remote.features, TvFeature.defaults);
      expect(remote.state.power, isTrue);
      expect(remote.state.app, recordedApp);
      expect(remote.state.volume, const TvVolume(level: 9, maximum: 15, muted: false));
      final [setup, activate] = fake.fromClient.take(2).toList();
      final mask = TvFeature.maskOf(TvFeature.defaults);
      expect(
        hexEncode(setup.encodeEnvelope()),
        hexEncode(SetupMessage(features: mask, device: TvClientInfo.standard.toMessage()).encodeEnvelope()),
      );
      expect((activate as ActivateMessage).features, mask);
      await remote.close();
    });

    test('the setup describes the client as the app says', () async {
      final (tv, fake) = await fakeTv();
      const client = TvClientInfo(
        model: 'Phone',
        vendor: 'Maker',
        os: TvClientOs.ios,
        osVersion: '18.1',
        appId: 'app.example.remote',
        appVersion: '2.3.4',
      );
      final remote = await connect(tv, client: client);
      final device = (fake.fromClient.first as SetupMessage).device!;
      expect(
        (device.model, device.vendor, device.os, device.androidRelease, device.packageName, device.serviceVersion),
        ('Phone', 'Maker', 2, '18.1', 'app.example.remote', '2.3.4'),
      );
      await remote.close();
    });

    test('features are what was asked and offered; power is always asked for', () async {
      final (tv, fake) = await fakeTv(FakeSession(offered: 639 & ~TvFeature.key.bit));
      final remote = await connect(tv, features: {TvFeature.key, TvFeature.ime});
      expect(remote.features, {TvFeature.ime, TvFeature.power});
      expect((fake.fromClient.first as SetupMessage).features, TvFeature.maskOf({TvFeature.ime, TvFeature.power}));
      await remote.close();
    });

    test('a TV that never reports its power state times out', () async {
      final (tv, fake) = await fakeTv(FakeSession(fault: SessionFault.noPower));
      final clock = FakeClock();
      final outcome = connect(tv, clock: clock);
      await until(() => fake.fromClient.length == 2 && clock.pendingTimers > 0);
      clock.advance(const Duration(seconds: 10));
      await expectLater(outcome, throwsA(isA<TvTimeoutException>()));
      expect(clock.pendingTimers, 0);
    });

    test('a TV that closes before its first message has not paired this client', () async {
      final (tv, _) = await fakeTv(FakeSession(fault: SessionFault.closeFirst));
      await expectLater(connect(tv), throwsA(isA<TvNotPairedException>()));
    });

    test('a device that resets during TLS with a pin set is a network error, not a wrong TV', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) => socket.destroy());
      addTearDown(server.close);
      await expectLater(
        TvRemote.connect(
          InternetAddress.loopbackIPv4,
          port: server.port,
          identity: testClient(),
          fingerprint: tvFingerprint,
        ),
        throwsA(isNot(isA<TvWrongTvException>())),
      );
    });

    test('without a fingerprint, a TV that refuses the certificate is still not paired', () async {
      final tv = await FakeTv.start(trusted: [testIdentity('other').certificatePem]);
      addTearDown(tv.close);
      await expectLater(
        TvRemote.connect(InternetAddress.loopbackIPv4, port: tv.remotePort, identity: testClient(), fingerprint: null),
        throwsA(isA<TvNotPairedException>()),
      );
    });

    test('a TV that refuses the certificate in TLS has not paired this client', () async {
      final tv = await FakeTv.start(trusted: [testIdentity('other').certificatePem]);
      addTearDown(tv.close);
      await expectLater(connect(tv), throwsA(isA<TvNotPairedException>()));
    });

    test('a device with another key is refused before anything is sent', () async {
      var accepted = 0;
      final tv = await startFakeTv(onRemote: (c) async => accepted++);
      await expectLater(
        connect(tv, fingerprint: 'ab' * 32),
        throwsA(isA<TvWrongTvException>().having((e) => e.actual, 'actual', tvFingerprint)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(accepted, 0);
    });

    test('garbage from the TV is a protocol error', () async {
      final (tv, _) = await fakeTv(FakeSession(fault: SessionFault.garbage));
      await expectLater(connect(tv), throwsA(isA<TvProtocolException>()));
    });

    test('cancelOn stops a start that waits for the TV', () async {
      final (tv, fake) = await fakeTv(FakeSession(fault: SessionFault.noPower));
      final cancel = Completer<void>();
      final outcome = connect(tv, cancelOn: cancel.future);
      await until(() => fake.fromClient.length == 2);
      cancel.complete();
      await expectLater(outcome, throwsA(isA<TvCancelledException>()));
    });
  });

  group('a running session', () {
    late FakeSession fake;
    late TvRemote remote;
    late FakeClock clock;

    setUp(() async {
      clock = FakeClock();
      final (tv, session) = await fakeTv();
      fake = session;
      remote = await connect(tv, clock: clock);
      addTearDown(remote.close);
    });

    test('answers pings with their id', () async {
      await fake.sendMessage(PingMessage(id: 7));
      await fake.received<PongMessage>();
      expect(fake.fromClient.whereType<PongMessage>().single.id, 7);
    });

    test('reports state changes once each', () async {
      final changes = <TvState>[];
      remote.changes.listen(changes.add);
      await fake.sendMessage(PowerReport(state: 0));
      await fake.sendMessage(PowerReport(state: 0));
      await fake.sendMessage(FocusReport(app: FocusedApp(packageName: 'com.example.app')));
      await until(() => changes.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(changes.map((s) => (s.power, s.app)), [(false, recordedApp), (false, 'com.example.app')]);
      expect(remote.state, same(changes.last));
    });

    test('ends after the idle limit without a message either way; sending counts', () async {
      clock.advance(const Duration(seconds: 10));
      remote.sendRaw(99, const [1]);
      clock.advance(const Duration(seconds: 10));
      expect(remote.isClosed, isFalse);
      clock.advance(const Duration(seconds: 6));
      expect(await remote.done, isA<TvTimeoutException>());
      expect(clock.pendingTimers, 0);
    });

    test('a message from the TV counts as activity', () async {
      clock.advance(const Duration(seconds: 10));
      await fake.sendMessage(PingMessage(id: 1));
      await fake.received<PongMessage>();
      clock.advance(const Duration(seconds: 10));
      expect(remote.isClosed, isFalse);
    });

    test('close ends it with null, once, and leaves no timers', () async {
      await remote.close();
      await remote.close();
      expect(await remote.done, isNull);
      expect(clock.pendingTimers, 0);
      expect(() => remote.sendRaw(99, const [1]), throwsA(isA<TvCancelledException>()));
    });

    test('a refused link ends the session with the link', () async {
      await fake.sendMessage(RemoteEnvelope.fromTv(sessionMessage('refusal', outgoing: false)));
      expect(
        await remote.done,
        isA<TvLinkRefusedException>()
            .having((e) => e.link, 'link', 'com.android.tv.settings')
            .having((e) => e.refusalCode, 'refusalCode', 7),
      );
    });

    test('a TV that closes ends the session as closed', () async {
      await (await fake.connection.future).close();
      expect(await remote.done, isA<TvClosedException>());
      expect(() => remote.sendRaw(99, const [1]), throwsA(isA<TvClosedException>()));
    });

    test('a refusal of something else than a link ends the session as a protocol error', () async {
      final refused = KeyMessage(code: 0, action: KeyAction.short).encodeEnvelope();
      await fake.sendMessage(RefusalMessage(code: const RefusalCode(3), refused: refused));
      expect(await remote.done, isA<TvProtocolException>());
    });

    test('a refusal with a malformed echo, or a malformed message, is a protocol error', () async {
      final changes = remote.changes.toList();
      await fake.sendMessage(RefusalMessage(code: RefusalCode.cannotAct, refused: Uint8List.fromList([0x0b])));
      expect(await remote.done, isA<TvProtocolException>());
      expect(await changes, isEmpty, reason: 'the changes stream closes with the session');
    });

    test('a malformed message after the start is a protocol error', () async {
      FakeSession.send(await fake.connection.future, const [0x0b]);
      expect(await remote.done, isA<TvProtocolException>());
    });

    test('raw messages carry the bytes as they arrived, for known messages too', () async {
      final raw = <TvRawMessage>[];
      remote.rawMessages.listen(raw.add);
      final bytes = sessionMessage('volumeReport.2', outgoing: false);
      FakeSession.send(await fake.connection.future, bytes);
      await until(() => raw.isNotEmpty);
      expect((raw.single.field, hexEncode(raw.single.envelope)), (VolumeReport.fieldNumber, hexEncode(bytes)));
    });

    test('raw messages both ways', () async {
      final raw = <TvRawMessage>[];
      remote.rawMessages.where((m) => m.field == 123).listen(raw.add);
      await fake.sendMessage(UnknownEnvelope(ProtoField.bytes(123, [5])));
      await until(() => raw.isNotEmpty);
      expect((raw.single.field, hexEncode(raw.single.envelope)), (123, 'da070105'));
      remote.sendRaw(124, const [6]);
      await fake.received<UnknownEnvelope>();
      expect(fake.fromClient.whereType<UnknownEnvelope>().single.field, 124);
    });

    test('two closes at once both complete; done completes once with null', () async {
      await Future.wait([remote.close(), remote.close()]);
      expect(await remote.done, isNull);
      expect(remote.isClosed, isTrue);
    });

    test('streams listened to after the end are done at once', () async {
      await remote.close();
      expect(await remote.changes.toList(), isEmpty);
      expect(await remote.rawMessages.toList(), isEmpty);
      expect(await remote.textFieldChanges.toList(), isEmpty);
    });

    test('a ping without an id is answered without one', () async {
      await fake.sendMessage(PingMessage());
      final pong = (await fake.received<PongMessage>()).single;
      expect(pong.id, isNull);
    });

    test('a key held when the TV ends the session can still be released, which does nothing', () async {
      final hold = remote.hold(TvKey.dpadUp);
      await fake.received<KeyMessage>();
      (await fake.connection.future).freeze();
      await (await fake.connection.future).close();
      await remote.done;
      hold.release();
      hold.release();
    });

    test('a raw message that is not a valid envelope still goes out, traced by its field', () async {
      final traces = <TvTraceEvent>[];
      final (tv, _) = await fakeTv();
      final traced = await connect(tv, tracer: TvTracer(traces.add));
      addTearDown(traced.close);
      traced.sendRaw(VolumeLevelRequest.fieldNumber, const [0xff]);
      final sent = traces.whereType<TvMessageTrace>().where((t) => t.outgoing).map((t) => t.kind);
      expect(sent.last, 'raw(50)');
    });

    test("a second setup from the TV mid-session is answered again with the client's features", () async {
      final before = fake.fromClient.whereType<SetupMessage>().length;
      await fake.sendMessage(SetupMessage(features: FakeSession.recordedFeatures));
      await fake.received<SetupMessage>(count: before + 1);
      expect(remote.isClosed, isFalse);
      expect(remote.features, isNotEmpty);
    });
  });
}
