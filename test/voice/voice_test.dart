// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_remote.dart';
import '../support/fake_session.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

const int chunk = TvVoiceSession.chunkBytes;

void main() {
  late FakeSession fake;
  late FakeClock clock;
  late TvRemote remote;

  Future<void> connect({Set<TvFeature> features = const {TvFeature.key, TvFeature.voice}}) async {
    final connected = await FakeRemote.connect(features: features);
    (fake, clock, remote) = (connected.session, connected.clock, connected.remote);
  }

  List<VoiceAudioMessage> audio() => fake.fromClient.whereType<VoiceAudioMessage>().toList();

  setUp(connect);

  test('Search opens the session; the acknowledgement is the recorded one', () async {
    final voice = await remote.startVoice();
    expect(voice.voiceId, 1);
    expect(fake.fromClient.whereType<KeyMessage>().single.code, TvKey.search.code);
    await fake.received<VoiceOpenMessage>();
    expect(
      hexEncode(fake.fromClient.whereType<VoiceOpenMessage>().single.encodeEnvelope()),
      hexEncode(recorded('voiceOpen', outgoing: true, file: 'voice.txt').bytes),
    );
  });

  test('without pacing, whole chunks go out at once; close pads the last and ends with the recorded close', () async {
    final voice = await remote.startVoice(pace: false);
    await voice.add(Uint8List(chunk * 2 + 100));
    await until(() => audio().length == 2);
    await voice.close();
    await fake.received<VoiceCloseMessage>();
    expect(audio().map((a) => a.samples!.length), [chunk, chunk, chunk]);
    expect(
      hexEncode(fake.fromClient.whereType<VoiceCloseMessage>().single.encodeEnvelope()),
      hexEncode(recorded('voiceClose', outgoing: true, file: 'voice.txt').bytes),
    );
    expect(voice.isOpen, isFalse);
  });

  test('with pacing, one chunk per 1.28 s; add waits once ten seconds are buffered', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 3));
    await until(() => audio().length == 1);
    clock.advance(const Duration(milliseconds: 1279));
    expect(audio(), hasLength(1));
    clock.advance(const Duration(milliseconds: 1));
    await until(() => audio().length == 2);
    var added = false;
    final big = voice.add(Uint8List(TvVoiceSession.maxBufferedBytes)).then((_) => added = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(added, isFalse);
    clock.advance(const Duration(seconds: 3));
    await big;
  });

  test('a second close while the first sends the rest waits for it: every chunk goes out before the close', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 3));
    final closes = [voice.close(), voice.close()];
    for (var sent = 1; sent < 3; sent++) {
      await until(() => audio().length == sent);
      clock.advance(const Duration(milliseconds: 1280));
    }
    await fake.received<VoiceCloseMessage>();
    expect(audio(), hasLength(3), reason: 'the second close did not cut the rest off');
    clock.advance(TvVoiceSession.endConfirmation);
    await Future.wait(closes);
  });

  test('cancel ends the session without the audio left', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 3));
    voice.cancel();
    await fake.received<VoiceCloseMessage>();
    expect(audio(), hasLength(1));
    await expectLater(voice.add(Uint8List(1)), throwsStateError);
  });

  test('the TV ending the session ends it here: done completes, audio is dropped, close does nothing', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 2));
    await fake.sendMessage(RemoteEnvelope.fromTv(recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes));
    await voice.done;
    expect(voice.isOpen, isFalse);
    await voice.add(Uint8List(chunk * 2));
    await voice.close();
    await until(() => audio().isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(audio(), hasLength(1), reason: 'only the chunk sent before the TV ended the session');
    expect(fake.fromClient.whereType<VoiceCloseMessage>(), isEmpty, reason: 'the TV ended it already');
  });

  test('an end for another voice session is not this one', () async {
    final voice = await remote.startVoice();
    await fake.sendMessage(VoiceEndedMessage(voiceId: voice.voiceId + 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(voice.isOpen, isTrue);
  });

  test('a paced close pads only the last chunk, and waits for the TV to confirm', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk + 100));
    final closing = voice.close();
    await until(() => audio().length == 1);
    clock.advance(const Duration(milliseconds: 1280));
    await closing;
    expect(audio().map((a) => a.samples!.length), [chunk, chunk]);
    expect(audio().last.samples!.skip(100).every((b) => b == 0), isTrue);
    expect(voice.isDone, isTrue);
  });

  test('without the TV confirming, done completes after a second', () async {
    final voice = await remote.startVoice(pace: false);
    fake.answerVoiceClose = false;
    final closing = voice.close();
    await fake.received<VoiceCloseMessage>();
    expect(voice.isDone, isFalse);
    clock.advance(TvVoiceSession.endConfirmation);
    await closing;
  });

  test('the remote session ending during close fails close, without hanging', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 3));
    final closing = expectLater(voice.close(), throwsA(isA<TvCancelledException>()));
    await until(() => audio().isNotEmpty);
    await remote.close();
    await closing;
  });

  test('a second voice session waits for the first to be done', () async {
    final voice = await remote.startVoice(pace: false);
    expect(remote.startVoice, throwsStateError);
    await voice.close();
    await fake.received<VoiceOpenMessage>();
    expect(await remote.startVoice(), isA<TvVoiceSession>());
  });

  test('close completes done', () async {
    final voice = await remote.startVoice(pace: false);
    await voice.close();
    await voice.done;
  });

  test('a TV that does not open a session times out', () async {
    fake.answerSearch = false;
    final outcome = remote.startVoice();
    await fake.received<KeyMessage>();
    clock.advance(const Duration(seconds: 2));
    await expectLater(outcome, throwsA(isA<TvTimeoutException>()));
  });

  test('one voice session at a time, also while the first is starting', () async {
    final first = remote.startVoice();
    await expectLater(remote.startVoice(), throwsStateError);
    await first;
    await expectLater(remote.startVoice(), throwsStateError);
  });

  test('the end of the remote session fails adding with why it ended', () async {
    final voice = await remote.startVoice();
    await remote.close();
    await expectLater(voice.add(Uint8List(1)), throwsA(isA<TvCancelledException>()));
  });

  test('without the voice feature there is no voice session', () async {
    await connect(features: const {TvFeature.key});
    await expectLater(remote.startVoice(), throwsA(isA<TvNotSupportedException>()));
  });

  group('edges', () {
    test('a session the TV opens just after the timeout is closed again', () async {
      fake.answerSearch = false;
      final outcome = remote.startVoice();
      await fake.received<KeyMessage>();
      clock.advance(const Duration(seconds: 2));
      await expectLater(outcome, throwsA(isA<TvTimeoutException>()));
      await fake.sendMessage(RemoteEnvelope.fromTv(recorded('voiceOpen', outgoing: false, file: 'voice.txt').bytes));
      final closes = await fake.received<VoiceCloseMessage>();
      expect(closes.single.voiceId, 1);
      expect(fake.fromClient.whereType<VoiceOpenMessage>(), isEmpty, reason: 'never acknowledged');
    });

    test('a start retried right after a timeout takes the open that comes late, and closes nothing', () async {
      fake.answerSearch = false;
      final first = remote.startVoice();
      await fake.received<KeyMessage>();
      clock.advance(const Duration(seconds: 2));
      await expectLater(first, throwsA(isA<TvTimeoutException>()));
      final second = remote.startVoice(pace: false);
      await fake.received<KeyMessage>(count: 2);
      // The TV's open, answering the first Search, arrives while the second start waits.
      await fake.sendMessage(RemoteEnvelope.fromTv(recorded('voiceOpen', outgoing: false, file: 'voice.txt').bytes));
      final voice = await second;
      expect(voice.isOpen, isTrue);
      await voice.add(Uint8List(chunk));
      await fake.received<VoiceAudioMessage>();
      expect(fake.fromClient.whereType<VoiceCloseMessage>(), isEmpty);
    });

    test('the close of an open nobody waited for is confirmed by the end right after the next open', () async {
      fake
        ..answerSearch = false
        ..answerVoiceClose = false;
      final first = remote.startVoice();
      await fake.received<KeyMessage>();
      clock.advance(const Duration(seconds: 2));
      await expectLater(first, throwsA(isA<TvTimeoutException>()));
      final ended = recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes;
      final open = recorded('voiceOpen', outgoing: false, file: 'voice.txt').bytes;
      await fake.sendMessage(RemoteEnvelope.fromTv(open));
      await fake.received<VoiceCloseMessage>();
      // The TV confirms that close only right after the next open, with the same id: that end is not the new one's.
      final starting = remote.startVoice(pace: false);
      await fake.received<KeyMessage>(count: 2);
      (await fake.connection.future).sendTogether([open, ended]);
      final voice = await starting;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(voice.isOpen, isTrue);
      await fake.sendMessage(RemoteEnvelope.fromTv(ended));
      clock.advance(TvVoiceSession.lateConfirmationWindow);
      await voice.done.timeout(const Duration(seconds: 2));
      expect(voice.endConfirmed, isTrue);
    });

    test('addStream sends a stream of odd-sized pieces as whole chunks, the last padded', () async {
      final voice = await remote.startVoice(pace: false);
      final pieces = [for (var i = 0; i < 7; i++) Uint8List(chunk ~/ 3 + i)];
      await voice.addStream(Stream.fromIterable(pieces));
      await voice.close();
      final total = pieces.fold(0, (sum, p) => sum + p.length);
      final sent = audio();
      expect(sent, hasLength((total / chunk).ceil()));
      expect(sent.every((a) => a.samples!.length == chunk), isTrue);
    });

    test('an empty add sends nothing; close with no audio at all sends only the close', () async {
      final voice = await remote.startVoice(pace: false);
      await voice.add(const []);
      await voice.close();
      expect(audio(), isEmpty);
      expect(fake.fromClient.whereType<VoiceCloseMessage>(), hasLength(1));
    });

    test('an add waiting for room ends when the session is cancelled, the TV ends it, or the remote ends', () async {
      for (final end in ['cancel', 'tv', 'remote']) {
        if (end != 'cancel') await connect();
        final voice = await remote.startVoice();
        final waiting = voice.add(Uint8List(TvVoiceSession.maxBufferedBytes + chunk * 2));
        await until(() => audio().isNotEmpty);
        switch (end) {
          case 'cancel':
            voice.cancel();
            await waiting.timeout(const Duration(seconds: 2));
          case 'tv':
            await fake.sendMessage(
              RemoteEnvelope.fromTv(recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes),
            );
            await waiting.timeout(const Duration(seconds: 2));
          case 'remote':
            final failed = expectLater(
              waiting.timeout(const Duration(seconds: 2)),
              throwsA(isA<TvCancelledException>()),
            );
            await remote.close();
            await failed;
        }
      }
    });

    test(
      'adding after close started, or after cancel, is refused; cancel and close after the end do nothing',
      () async {
        final voice = await remote.startVoice();
        await voice.add(Uint8List(chunk * 2));
        final closing = voice.close();
        await expectLater(voice.add(Uint8List(1)), throwsStateError);
        clock.advance(const Duration(seconds: 3));
        await closing;
        voice.cancel();
        await voice.close();
        expect(fake.fromClient.whereType<VoiceCloseMessage>(), hasLength(1));
      },
    );

    test('a late confirmation of an unconfirmed close does not end the next session', () async {
      fake
        ..answerVoiceClose = false
        ..confirmCloseOnNextOpen = true;
      final first = await remote.startVoice(pace: false);
      final closing = first.close();
      await fake.received<VoiceCloseMessage>();
      clock.advance(TvVoiceSession.endConfirmation);
      await closing;
      expect(first.endConfirmed, isFalse);
      final second = await remote.startVoice(pace: false);
      await fake.received<VoiceOpenMessage>(count: 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((second.isOpen, second.isDone), (true, false));
      await second.add(Uint8List(chunk));
      await fake.received<VoiceAudioMessage>();
    });

    test('an end that arrives in the same read as the open ends the new session', () async {
      fake.answerSearch = false;
      final starting = remote.startVoice(pace: false);
      await until(() => fake.fromClient.whereType<KeyMessage>().any((k) => k.code == TvKey.search.code));
      (await fake.connection.future).sendTogether([
        recorded('voiceOpen', outgoing: false, file: 'voice.txt').bytes,
        recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes,
      ]);
      final voice = await starting;
      await voice.done.timeout(const Duration(seconds: 2));
      expect(voice.endConfirmed, isTrue);
    });

    test('after an unconfirmed close, only the first end right after the open is taken as the late one', () async {
      fake
        ..answerVoiceClose = false
        ..confirmCloseOnNextOpen = true;
      final first = await remote.startVoice(pace: false);
      final closing = first.close();
      await fake.received<VoiceCloseMessage>();
      clock.advance(TvVoiceSession.endConfirmation);
      await closing;
      final second = await remote.startVoice(pace: false);
      await fake.received<VoiceOpenMessage>(count: 2);
      await fake.sendMessage(RemoteEnvelope.fromTv(recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes));
      await second.done.timeout(const Duration(seconds: 2));
      expect(second.endConfirmed, isTrue);
    });

    test("after a confirmed close, an end right after the open is the new session's", () async {
      final first = await remote.startVoice(pace: false);
      await first.close();
      expect(first.endConfirmed, isTrue);
      final second = await remote.startVoice(pace: false);
      await fake.sendMessage(RemoteEnvelope.fromTv(recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes));
      await second.done;
      expect(second.isOpen, isFalse);
    });
  });
}
