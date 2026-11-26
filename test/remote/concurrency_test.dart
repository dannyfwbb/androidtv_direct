// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fake_field.dart';
import '../support/fake_remote.dart';
import '../support/wait.dart';

/// Everything an app may have going at once, cut off at a random moment by the TV or the app: every call must end in
/// a [TvRemoteException] or a [StateError] through its own future, and nothing may escape as an unhandled error.
void main() {
  for (var seed = 0; seed < 40; seed++) {
    test('seed $seed', () async {
      final random = Random(seed);
      final connected = await FakeRemote.connect(features: {...TvFeature.defaults, TvFeature.ime, TvFeature.voice});
      final (fake, clock, remote) = (connected.session, connected.clock, connected.remote);
      await fake.focus(FakeField(text: 'start'));
      await until(() => remote.textField != null);
      final field = remote.textField!;

      final outcomes = <Future<void>>[];
      void track(Future<Object?> future) => outcomes.add(
        future.then<void>(
          (_) {},
          onError: (Object e) {
            if (e is! TvRemoteException && e is! StateError) fail('seed $seed: unexpected $e');
          },
        ),
      );

      final hold = remote.hold(TvKey.dpadUp);
      track(remote.setVolume(random.nextInt(remote.state.volume!.maximum + 1)));
      track(field.setText('x' * random.nextInt(20)));
      track(field.setText('typed ${random.nextInt(100)}'));
      track(
        remote.startVoice(pace: random.nextBool()).then<void>((voice) async {
          await voice.add(Uint8List(random.nextInt(50000)));
          await voice.close();
        }),
      );
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(30)));
      clock.advance(Duration(milliseconds: random.nextInt(3000)));

      switch (random.nextInt(4)) {
        case 0:
          await remote.close();
        case 1:
          await (await fake.connection.future).close();
        case 2:
          (await fake.connection.future).freeze();
          clock.advance(const Duration(seconds: 20));
        case 3:
          await fake.focus(FakeField(text: 'other'));
          await remote.close();
      }
      hold.release();
      clock.advance(const Duration(seconds: 30));
      await Future.wait(outcomes).timeout(const Duration(seconds: 10));
      expect(remote.isClosed, isTrue);
    });
  }
}
