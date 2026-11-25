// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'test_tv.dart';

void main() {
  group('controls', skip: TestTv.skip, () {
    late TvClientIdentity identity;
    late String fingerprint;
    late TvRemote remote;

    setUpAll(() async => (identity, fingerprint) = await TestTv.pairFresh());

    Future<TvRemote> connect() => TvRemote.connect(
      TestTv.host!,
      identity: identity,
      fingerprint: fingerprint,
      features: {...TvFeature.defaults, TvFeature.ime},
    );

    setUp(() async => remote = await connect());
    tearDown(() => remote.close());

    Future<String> activity() => TestTv.resumedActivity();

    test('setVolume moves the TV volume, which the TV and the state agree on', () async {
      final start = await TestTv.mediaVolume();
      addTearDown(() => TestTv.setMediaVolume(start));
      final target = start < 10 ? start + 2 : start - 2;
      await remote.setVolume(target);
      expect(await TestTv.mediaVolume(), target);
      await remote.setVolume(start);
      expect((await TestTv.mediaVolume(), remote.state.volume!.level), (start, start));
    });

    test('Home and Back reach the TV', () async {
      await TestTv.shell(['am', 'start', '-n', 'com.android.tv.settings/.MainSettings']);
      expect(await TestTv.waitFor(() async => (await activity()).contains('tv.settings'), true), isTrue);
      remote.press(TvKey.back);
      expect(await TestTv.waitFor(() async => (await activity()).contains('tv.settings'), false), isFalse);
      await TestTv.shell(['am', 'start', '-n', 'com.android.tv.settings/.MainSettings']);
      expect(await TestTv.waitFor(() async => (await activity()).contains('tv.settings'), true), isTrue);
      remote.press(TvKey.home);
      expect(await TestTv.waitFor(() async => (await activity()).contains('tv.settings'), false), isFalse);
    });

    test('the power key turns the TV off and on, and the state follows', () async {
      expect(await TestTv.wakefulness(), 'Awake');
      addTearDown(TestTv.wake);
      remote.press(TvKey.power);
      await remote.changes.firstWhere((s) => s.power == false).timeout(const Duration(seconds: 10));
      expect(await TestTv.waitFor(TestTv.wakefulness, 'Asleep'), 'Asleep');
      remote.press(TvKey.power);
      await remote.changes.firstWhere((s) => s.power == true).timeout(const Duration(seconds: 10));
      expect(await TestTv.waitFor(TestTv.wakefulness, 'Awake'), 'Awake');
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a web link opens its app; a bare package name ends the session, and a new one works', () async {
      addTearDown(() => TestTv.shell(['input', 'keyevent', 'KEYCODE_HOME']));
      remote.openLink('https://www.youtube.com');
      await remote.changes
          .firstWhere((s) => s.app == 'com.google.android.youtube.tv')
          .timeout(const Duration(seconds: 10));
      remote.openLink('com.android.tv.settings');
      expect(await remote.done, isA<TvLinkRefusedException>());
      remote = await connect();
      expect(remote.state.power, isTrue);
    });
  });
}
