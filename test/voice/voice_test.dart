// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/hex.dart';
import '../support/wait.dart';

const int chunk = TvVoiceSession.chunkBytes;

void main() {
  late FakeSession fake;
  late FakeClock clock;
  late TvRemote remote;

  Future<void> connect({Set<TvFeature> features = const {TvFeature.key, TvFeature.voice}}) async {
    fake = FakeSession();
    clock = FakeClock();
    final tv = await startFakeTv(onRemote: fake.serve);
    remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: features,
      clock: clock,
    );
    addTearDown(remote.close);
  }

  List<VoiceAudioMessage> audio() => fake.fromClient.whereType<VoiceAudioMessage>().toList();

  setUp(connect);

  test('Search opens the session; the acknowledgement is the recorded one', () async {
    final voice = await remote.startVoice();
    expect(voice.voiceId, 1);
    expect(fake.fromClient.whereType<KeyMessage>().single.code, TvKey.search.code);
    await until(() => fake.fromClient.whereType<VoiceOpenMessage>().isNotEmpty);
    expect(
      hex(fake.fromClient.whereType<VoiceOpenMessage>().single.encodeEnvelope()),
      hex(recorded('voiceOpen', outgoing: true, file: 'voice.txt').bytes),
    );
  });

  test('without pacing, whole chunks go out at once; close pads the last and ends with the recorded close', () async {
    final voice = await remote.startVoice(pace: false);
    await voice.add(Uint8List(chunk * 2 + 100));
    await until(() => audio().length == 2);
    await voice.close();
    await until(() => fake.fromClient.whereType<VoiceCloseMessage>().isNotEmpty);
    expect(audio().map((a) => a.samples!.length), [chunk, chunk, chunk]);
    expect(
      hex(fake.fromClient.whereType<VoiceCloseMessage>().single.encodeEnvelope()),
      hex(recorded('voiceClose', outgoing: true, file: 'voice.txt').bytes),
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

  test('cancel ends the session without the audio left', () async {
    final voice = await remote.startVoice();
    await voice.add(Uint8List(chunk * 3));
    voice.cancel();
    await until(() => fake.fromClient.whereType<VoiceCloseMessage>().isNotEmpty);
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
    await until(() => fake.fromClient.whereType<VoiceCloseMessage>().isNotEmpty);
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
    await until(() => fake.fromClient.whereType<VoiceOpenMessage>().isNotEmpty);
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
    await until(() => fake.fromClient.whereType<KeyMessage>().isNotEmpty);
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
}
