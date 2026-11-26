// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'test_tv.dart';

/// A tracer that keeps every message in [messages].
TvTracer messageTracer(List<TvMessageTrace> messages) => TvTracer((e) => e is TvMessageTrace ? messages.add(e) : null);

void main() {
  group('session', skip: TestTv.skip, () {
    late TvClientIdentity identity;
    late String fingerprint;

    setUpAll(() async => (:identity, :fingerprint) = await TestTv.pairFresh());

    Future<TvRemote> connect({TvClientIdentity? as, String? pin, TvTracer? tracer}) =>
        TvRemote.connect(TestTv.host!, identity: as ?? identity, fingerprint: pin ?? fingerprint, tracer: tracer);

    test('starts with the TV described and its state filled, and stays up while quiet', () async {
      final messages = <TvMessageTrace>[];
      final remote = await connect(tracer: messageTracer(messages));
      expect(remote.device.serviceVersion, isNotNull);
      expect(remote.state.power, isNotNull);
      expect(remote.features, containsAll([TvFeature.key, TvFeature.power]));
      await Future<void>.delayed(const Duration(seconds: 12));
      expect(remote.isClosed, isFalse);
      expect(messages.where((m) => m.kind == 'pong'), isNotEmpty);
      await remote.close();
      expect(await remote.done, isNull);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('the TV logs what the client says about itself, and an iOS client gets the same session', () async {
      final mark = 'Model ${DateTime.now().microsecondsSinceEpoch}';
      final remote = await TvRemote.connect(
        TestTv.host!,
        identity: identity,
        fingerprint: fingerprint,
        client: TvClientInfo(model: mark, vendor: 'Maker', os: TvClientOs.ios, osVersion: '18.1', appId: 'app.test'),
      );
      expect(remote.features, containsAll(TvFeature.defaults));
      final logged = await TestTv.waitFor(() async => (await TestTv.log()).contains(mark), true);
      expect(logged, isTrue);
      final line = (await TestTv.log()).split('\n').lastWhere((line) => line.contains(mark));
      expect(line, allOf(contains('device_manufacturer=Maker'), contains('os=ios'), contains('os_version=18.1')));
      expect(line, allOf(contains('app_name=app.test'), contains('app_version=1.0.0')));
      await remote.close();
    });

    test('an identity the TV does not know is not paired', () async {
      final stranger = await TvClientIdentity.generate(now: DateTime.now());
      await expectLater(connect(as: stranger), throwsA(isA<TvNotPairedException>()));
    });

    test('another fingerprint is refused before anything is sent', () async {
      final messages = <TvMessageTrace>[];
      await expectLater(
        connect(pin: 'ab' * 32, tracer: messageTracer(messages)),
        throwsA(isA<TvWrongTvException>().having((e) => e.actual, 'actual', fingerprint)),
      );
      expect(messages, isEmpty);
    });
  });
}
