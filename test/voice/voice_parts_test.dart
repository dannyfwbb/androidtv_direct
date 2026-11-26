// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:androidtv_direct/src/voice/voice.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';

/// Voice starts and voice sessions follow the remote session only while they need to: none stays behind.
void main() {
  test('many voice sessions, ended every way, and starts that time out leave no part behind', () async {
    final fake = FakeSession();
    final tv = await startFakeTv(onRemote: fake.serve);
    final clock = FakeClock();
    final socket = await TvSocket.connect(
      InternetAddress.loopbackIPv4,
      tv.remotePort,
      context: testClient().securityContext(),
      timeout: const Duration(seconds: 5),
    );
    final session = RemoteSession(
      socket,
      {TvFeature.key, TvFeature.voice},
      clock: clock,
      idleTimeout: const Duration(seconds: 16),
    );
    addTearDown(session.close);
    await session.start(const Duration(seconds: 5));
    final before = session.partCount;

    for (var i = 0; i < 20; i++) {
      final voice = await startVoiceSession(session, timeout: const Duration(seconds: 2), pace: false);
      await voice.add(Uint8List(TvVoiceSession.chunkBytes));
      switch (i % 3) {
        case 0:
          await voice.close();
        case 1:
          voice.cancel();
          clock.advance(TvVoiceSession.endConfirmation);
          await voice.done;
        case 2:
          fake.answerVoiceClose = false;
          final closing = voice.close();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          clock.advance(TvVoiceSession.endConfirmation);
          await closing;
          fake.answerVoiceClose = true;
      }
    }
    fake.answerSearch = false;
    for (var i = 0; i < 5; i++) {
      final starting = startVoiceSession(session, timeout: const Duration(seconds: 2), pace: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      clock.advance(const Duration(seconds: 2));
      await expectLater(starting, throwsA(isA<TvTimeoutException>()));
      // The start waits as long again for an open that comes late, then lets go.
      clock.advance(const Duration(seconds: 2));
    }
    expect(session.partCount, before);
  });
}
