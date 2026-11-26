// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fake_field.dart';
import '../support/fake_remote.dart';
import '../support/wait.dart';

/// Every public call once the session has ended, closed by the app or by the TV: each fails at once with why the
/// session ended (or does nothing, where its documentation says so), nothing hangs, the streams are closed and what
/// was read stays readable.
void main() {
  final endings = <String, ({Future<void> Function(FakeRemote) end, TypeMatcher<TvRemoteException> reason})>{
    'closed by the app': (end: (c) => c.remote.close(), reason: isA<TvCancelledException>()),
    'closed by the TV': (
      end: (c) async {
        await (await c.session.connection.future).close();
        await c.remote.done;
      },
      reason: isA<TvClosedException>(),
    ),
  };

  for (final MapEntry(key: name, value: (:end, :reason)) in endings.entries) {
    test('every call after the session was $name', () async {
      final connected = await FakeRemote.connect(features: {...TvFeature.defaults, TvFeature.ime, TvFeature.voice});
      final (fake, remote) = (connected.session, connected.remote);
      await fake.focus(FakeField(text: 'kept'));
      await until(() => remote.textField != null);
      final field = remote.textField!;
      final hold = remote.hold(TvKey.dpadUp);
      final voice = await remote.startVoice(pace: false);
      final streamsDone = [
        remote.changes.drain<void>(),
        remote.textFieldChanges.drain<void>(),
        remote.rawMessages.drain<void>(),
        field.changes.drain<void>(),
        field.keyboardChanges.drain<void>(),
      ];
      final (state, device, features) = (remote.state, remote.device, remote.features);

      final ending = end(connected);
      if (name == 'closed by the app') expect(remote.textField, isNull, reason: 'at once');
      await ending;

      expect(remote.isClosed, isTrue);
      expect(await remote.done, name == 'closed by the app' ? isNull : reason);
      expect(() => remote.press(TvKey.home), throwsA(reason));
      expect(() => remote.sendKeyCode(3), throwsA(reason));
      expect(() => remote.hold(TvKey.home), throwsA(reason));
      expect(() => remote.holdCode(3), throwsA(reason));
      expect(() => remote.openLink('https://example.com'), throwsA(reason));
      expect(() => remote.sendRaw(99, [1]), throwsA(reason));
      await expectLater(remote.setVolume(1), throwsA(reason));
      await expectLater(remote.startVoice(), throwsA(reason));
      hold.release();

      expect(remote.textField, isNull);
      expect((field.isFocused, field.text), (false, 'kept'));
      await expectLater(field.setText('x'), throwsA(isA<TvRemoteException>()));
      expect(() => field.insert('x'), throwsA(reason));
      expect(field.submit, throwsA(reason));

      expect(voice.isDone, isTrue);
      await expectLater(voice.add(Uint8List(10)), throwsA(anyOf(reason, isStateError)));
      await expectLater(voice.done, throwsA(reason));
      voice.cancel();

      await Future.wait(streamsDone).timeout(const Duration(seconds: 5));
      expect((remote.state, remote.device, remote.features), (state, device, features));
      await remote.close();
      await remote.close();
    });
  }
}
