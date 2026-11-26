// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_field.dart';
import '../support/fake_remote.dart';

/// A TV that sends well-formed messages with odd values (negative and huge numbers, half an emoji, a selection
/// outside the text, a level above the maximum, ids of no voice session, a second setup) while the app uses the
/// whole API. Every call must end through its own future with a [TvRemoteException] or a [StateError], and the
/// state the app reads must stay within what the API promises.
void main() {
  final seeds = 60 * int.parse(Platform.environment['FUZZ_SCALE'] ?? '1');
  for (var seed = 0; seed < seeds; seed++) {
    test('seed $seed', () async {
      final random = Random(seed);
      final odd = _OddValues(random);
      final connected = await FakeRemote.connect(features: {...TvFeature.defaults, TvFeature.ime, TvFeature.voice});
      final (fake, clock, remote) = (connected.session, connected.clock, connected.remote);
      await fake.focus(FakeField(text: 'start'));

      final outcomes = <Future<void>>[];
      void track(FutureOr<void> Function() call) => outcomes.add(
        Future.sync(call).then<void>(
          (_) {},
          onError: (Object e) {
            if (e is! TvRemoteException && e is! StateError) fail('seed $seed: unexpected $e');
          },
        ),
      );

      void checkState() {
        final volume = remote.state.volume;
        if (volume != null) {
          expect(volume.maximum, greaterThanOrEqualTo(0), reason: '$volume');
          expect(volume.level, inInclusiveRange(0, volume.maximum), reason: '$volume');
        }
        final field = remote.textField;
        if (field != null) {
          final (:start, :end) = field.selection;
          expect([start, end], everyElement(inInclusiveRange(0, field.text.length)), reason: '${field.selection}');
        }
      }

      final subscription = remote.changes.listen((_) => checkState());
      addTearDown(subscription.cancel);
      for (var round = 0; round < 30 && !remote.isClosed; round++) {
        await fake.sendMessage(odd.message());
        switch (random.nextInt(6)) {
          case 0:
            final field = remote.textField;
            if (field != null) track(() => field.setText(odd.text()));
          case 1:
            final volume = remote.state.volume;
            if (volume != null) track(() => remote.setVolume(random.nextInt(min(volume.maximum, 1000) + 1)));
          case 2:
            track(() => remote.press(TvKey.dpadCenter));
          case 3:
            track(() async {
              final voice = await remote.startVoice(pace: false);
              await voice.add(Uint8List(random.nextInt(30000)));
              await voice.close();
            });
          case 4:
            clock.advance(Duration(milliseconds: random.nextInt(2000)));
          case 5:
            await Future<void>.delayed(Duration.zero);
        }
        await Future<void>.delayed(Duration(milliseconds: random.nextInt(3)));
        checkState();
      }
      await remote.close();
      clock.advance(const Duration(seconds: 30));
      await Future.wait(outcomes).timeout(const Duration(seconds: 10));
      expect(remote.isClosed, isTrue);
    });
  }
}

/// Well-formed messages with values a TV is not expected to send.
final class _OddValues {
  _OddValues(this._random);

  final Random _random;

  static const List<int> _numbers = [0, 1, 2, 7, 15, 100, -1, -100, 1 << 31, 1 << 62, -(1 << 62)];
  static const List<String> _texts = ['', 'a', 'start', 'ok 👍🏽', '\u{D83D}', 'x\u{DC4D}y', 'мир', '\u0000'];

  int? number() => _random.nextInt(8) == 0 ? null : _numbers[_random.nextInt(_numbers.length)];

  String text() => _random.nextInt(10) == 0 ? 'y' * 300 : _texts[_random.nextInt(_texts.length)];

  TextFieldState field() =>
      TextFieldState(fieldRevision: number(), text: text(), selectionStart: number(), selectionEnd: number());

  RemoteEnvelope message() => switch (_random.nextInt(11)) {
    0 => FocusReport(
      app: FocusedApp(
        keyboardRevision: number(),
        inputType: number(),
        imeOptions: number(),
        packageName: _random.nextBool() ? 'app.one' : text(),
        viewId: number(),
      ),
      textField: _random.nextInt(4) == 0 ? null : field(),
    ),
    1 || 2 => FieldReport(textField: field()),
    3 => KeyboardReport(keyboardRevision: number(), fieldRevision: number()),
    4 || 5 => VolumeReport(maximum: number(), level: number(), muteState: number()),
    6 => PowerReport(state: number()),
    7 => VoiceOpenMessage(voiceId: number()),
    8 => VoiceEndedMessage(voiceId: number()),
    9 => PingMessage(id: number()),
    _ => SetupMessage(features: number()),
  };
}
