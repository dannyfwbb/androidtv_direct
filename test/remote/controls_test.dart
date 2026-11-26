// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_remote.dart';
import '../support/fake_session.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  late FakeSession fake;
  late FakeClock clock;

  Future<TvRemote> connect({Set<TvFeature> features = TvFeature.defaults}) async {
    final connected = await FakeRemote.connect(features: features);
    (fake, clock) = (connected.session, connected.clock);
    return connected.remote;
  }

  /// The client's messages of type [T], once [count] of them arrived.
  Future<List<T>> sent<T>(int count) => fake.received<T>(count: count);

  group('keys', () {
    test('press sends the key as the recording has it', () async {
      final remote = await connect();
      remote.press(TvKey.volumeUp);
      final [key] = await sent<KeyMessage>(1);
      expect(hexEncode(key.encodeEnvelope()), hexEncode(sessionMessage('key', outgoing: true)));
    });

    test('any code from 1 to 999, with any action', () async {
      final remote = await connect();
      remote
        ..sendKeyCode(999, action: TvKeyAction.down)
        ..sendKeyCode(1, action: TvKeyAction.up);
      final keys = await sent<KeyMessage>(2);
      expect(keys.map((k) => (k.code, k.action)), [(999, KeyAction.press), (1, KeyAction.release)]);
      expect(() => remote.sendKeyCode(0), throwsRangeError);
      expect(() => remote.sendKeyCode(1000), throwsRangeError);
    });

    test('a held key goes down, and up once, also when the session closes', () async {
      final remote = await connect();
      final first = remote.hold(TvKey.dpadDown);
      first
        ..release()
        ..release();
      final second = remote.holdCode(TvKey.dpadUp.code);
      await remote.close();
      expect(second.isReleased, isTrue);
      final keys = await sent<KeyMessage>(4);
      expect(keys.map((k) => (k.code, k.action)), [
        (TvKey.dpadDown.code, KeyAction.press),
        (TvKey.dpadDown.code, KeyAction.release),
        (TvKey.dpadUp.code, KeyAction.press),
        (TvKey.dpadUp.code, KeyAction.release),
      ]);
    });

    test('a session without the key feature refuses keys before sending', () async {
      final remote = await connect(features: {TvFeature.volume});
      expect(() => remote.press(TvKey.home), throwsA(isA<TvNotSupportedException>()));
      expect(() => remote.hold(TvKey.home), throwsA(isA<TvNotSupportedException>()));
    });

    test('keys after the end throw why it ended', () async {
      final remote = await connect();
      await remote.close();
      expect(() => remote.press(TvKey.home), throwsA(isA<TvCancelledException>()));
    });
  });

  group('links', () {
    test('a link goes out as the recording has it', () async {
      final remote = await connect();
      remote.openLink('https://www.youtube.com');
      final [link] = await sent<OpenLinkMessage>(1);
      expect(hexEncode(link.encodeEnvelope()), hexEncode(sessionMessage('openLink', outgoing: true)));
    });

    test('an empty or overlong link is refused before sending', () async {
      final remote = await connect();
      expect(() => remote.openLink(''), throwsArgumentError);
      expect(() => remote.openLink('x' * 8193), throwsArgumentError);
      expect(() => remote.openLink('я' * 4097), throwsArgumentError, reason: '8194 bytes in UTF-8');
      expect(() => remote.openLink('x' * 8192), returnsNormally);
    });

    test('a bare package name is refused by the TV, which ends the session', () async {
      final remote = await connect();
      remote.openLink('com.android.tv.settings');
      expect(await remote.done, isA<TvLinkRefusedException>().having((e) => e.link, 'link', 'com.android.tv.settings'));
    });

    test('a session without the app link feature refuses links', () async {
      final remote = await connect(features: {TvFeature.key});
      expect(() => remote.openLink('https://www.youtube.com'), throwsA(isA<TvNotSupportedException>()));
    });
  });

  group('volume', () {
    test('setVolume presses keys until the reported level matches, up and down', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      await remote.setVolume(12);
      expect(remote.state.volume!.level, 12);
      await remote.setVolume(10);
      expect(remote.state.volume!.level, 10);
      final keys = await sent<KeyMessage>(5);
      expect(keys.map((k) => k.code), [24, 24, 24, 25, 25]);
    });

    test(
      'down to 0 (which mutes) and back up: each press is one step, so the walk never presses past an end',
      () async {
        final remote = await connect();
        await until(() => remote.state.volume != null);
        final start = remote.state.volume!.level;
        final maximum = remote.state.volume!.maximum;
        for (final target in [0, 2, 0, maximum, 1]) {
          final pressesBefore = fake.fromClient.whereType<KeyMessage>().length;
          final from = remote.state.volume!.level;
          await remote.setVolume(target);
          expect(remote.state.volume!.level, target);
          expect(fake.volume, target);
          final presses = fake.fromClient.whereType<KeyMessage>().length - pressesBefore;
          expect(presses, (target - from).abs(), reason: 'from $from to $target');
        }
        expect(start, isNot(1), reason: 'the walk ends somewhere it did not start');
      },
    );

    test('a TV whose first press while muted only unmutes still gets there, one step wait later', () async {
      final remote = await connect();
      fake.upOnlyUnmutes = true;
      await until(() => remote.state.volume != null);
      await remote.setVolume(0);
      expect(remote.state.volume!.muted, isTrue);
      final rising = remote.setVolume(2);
      await until(() => remote.state.volume!.muted == false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      clock.advance(const Duration(seconds: 2));
      await rising;
      expect((remote.state.volume!.level, fake.volume), (2, 2));
    });

    test('a press the TV loses is pressed again, and the level is reached', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      final from = remote.state.volume!.level;
      fake.loseVolumeKeys = 1;
      final setting = remote.setVolume(from + 2);
      await sent<KeyMessage>(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      clock.advance(const Duration(seconds: 2));
      await setting;
      expect((remote.state.volume!.level, fake.volume), (from + 2, from + 2));
      expect(fake.fromClient.whereType<KeyMessage>(), hasLength(3), reason: 'two steps and the lost one again');
    });

    test('a TV that answers no press at all fails within the timeout', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      fake.answerVolumeKeys = false;
      final setting = expectLater(
        remote.setVolume(remote.state.volume!.level + 1, timeout: const Duration(seconds: 5)),
        throwsA(isA<TvTimeoutException>()),
      );
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        clock.advance(const Duration(seconds: 2));
      }
      await setting;
    });

    test('a newer call takes over from an older one', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      fake.answerVolumeKeys = false;
      final older = expectLater(remote.setVolume(12), throwsA(isA<TvCancelledException>()));
      await sent<KeyMessage>(1);
      fake.answerVolumeKeys = true;
      await remote.setVolume(8);
      await older;
      expect(remote.state.volume!.level, 8);
    });

    test('a session without keys cannot set the volume', () async {
      final remote = await connect(features: {TvFeature.volume});
      await until(() => remote.state.volume != null);
      expect(() => remote.setVolume(10), throwsA(isA<TvNotSupportedException>()));
    });

    test('a level out of range is refused', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      expect(() => remote.setVolume(16), throwsRangeError);
      expect(() => remote.setVolume(-1), throwsRangeError);
    });

    test('a session that ends while setting throws why it ended', () async {
      final remote = await connect();
      await until(() => remote.state.volume != null);
      fake.answerVolumeKeys = false;
      final outcome = expectLater(remote.setVolume(12), throwsA(isA<TvCancelledException>()));
      await sent<KeyMessage>(1);
      await remote.close();
      await outcome;
    });
  });

  test('an unknown raw message is refused by the TV, which ends the session', () async {
    final remote = await connect();
    remote.sendRaw(99, const [8, 1]);
    expect(await remote.done, isA<TvProtocolException>());
  });
}
