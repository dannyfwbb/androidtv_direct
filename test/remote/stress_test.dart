// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_field.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

/// Load on the real socket path: many sessions at once, bursts of keys with the TV's pings in the middle, voice and
/// text alongside. Nothing may be lost or reordered, and every session stays up.
void main() {
  const sessions = 10;
  const presses = 1000;
  const pings = 20;

  test('$sessions sessions at once, each $presses keys with pings during the burst, then text and voice', () async {
    final fakes = <FakeSession>[];
    final tv = await startFakeTv(
      onRemote: (c) {
        final fake = FakeSession();
        fakes.add(fake);
        return fake.serve(c);
      },
    );
    final remotes = await Future.wait([
      for (var i = 0; i < sessions; i++)
        TvRemote.connect(
          InternetAddress.loopbackIPv4,
          port: tv.remotePort,
          identity: testClient(),
          fingerprint: tvFingerprint,
          features: {...TvFeature.defaults, TvFeature.ime, TvFeature.voice},
        ),
    ]);
    for (final remote in remotes) {
      addTearDown(remote.close);
    }
    await until(() => fakes.length == sessions);

    final stopwatch = Stopwatch()..start();
    await Future.wait([
      for (final (i, remote) in remotes.indexed)
        () async {
          final fake = fakes[i];
          for (var k = 0; k < presses; k++) {
            remote.press(k.isEven ? TvKey.dpadUp : TvKey.dpadDown);
            if (k % (presses ~/ pings) == 0) await fake.sendMessage(PingMessage(id: k));
          }
        }(),
    ]);
    for (final fake in fakes) {
      await until(
        () => fake.fromClient.whereType<KeyMessage>().length == presses,
        timeout: const Duration(seconds: 30),
      );
    }
    final elapsed = stopwatch.elapsed;

    for (final fake in fakes) {
      final keys = fake.fromClient.whereType<KeyMessage>().map((k) => k.code).toList();
      expect(keys, [for (var k = 0; k < presses; k++) k.isEven ? TvKey.dpadUp.code : TvKey.dpadDown.code]);
      await until(() => fake.fromClient.whereType<PongMessage>().length == pings);
      expect(fake.fromClient.whereType<PongMessage>().map((p) => p.id), [
        for (var k = 0; k < presses; k += presses ~/ pings) k,
      ]);
    }
    printOnFailure('${sessions * presses} keys in ${elapsed.inMilliseconds} ms');
    expect(elapsed, lessThan(const Duration(seconds: 10)), reason: 'at least 1000 keys a second over all sessions');

    // Text and voice in every session at once, on top.
    await Future.wait([for (final fake in fakes) fake.focus(FakeField(text: 'start'))]);
    await until(() => remotes.every((r) => r.textField?.text == 'start'));
    final texts = await Future.wait([for (final (i, r) in remotes.indexed) r.textField!.setText('session $i 👍🏽')]);
    expect(texts, [for (var i = 0; i < sessions; i++) 'session $i 👍🏽']);
    await Future.wait([
      for (final remote in remotes)
        () async {
          final voice = await remote.startVoice(pace: false);
          await voice.add(Uint8List(5 * TvVoiceSession.chunkBytes));
          await voice.close();
        }(),
    ]);
    for (final fake in fakes) {
      final audio = fake.fromClient.whereType<VoiceAudioMessage>();
      expect(audio.map((a) => a.samples!.length), List.filled(5, TvVoiceSession.chunkBytes));
    }
    expect(remotes.map((r) => r.isClosed), everyElement(isFalse));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
