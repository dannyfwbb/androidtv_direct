// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fake_field.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';

/// A network slower than the waits: answers arrive later than `textGiveUp`, `stepTimeout` or a voice timeout, but they
/// arrive, and the session must wait for them instead of giving up, on the real clock.
void main() {
  test('setText reaches every text when each report takes longer than textGiveUp', () async {
    final fake = FakeSession()..latency = const Duration(milliseconds: 250);
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.ime},
      textGiveUp: const Duration(milliseconds: 100),
    );
    addTearDown(remote.close);
    await fake.focus(FakeField());
    final field = await remote.textFieldChanges.firstWhere((field) => field != null);
    final texts = ['Hello', 'Hello world', 'Help', '', 'Привет 👍🏽', 'x' * 40, 'Living room'];
    for (final text in texts) {
      expect(await field!.setText(text), text);
    }
    expect(remote.textField, same(field));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a report delayed far beyond the measured round trip: the text wanted next still arrives', () async {
    final fake = FakeSession()..latency = const Duration(milliseconds: 10);
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.ime},
      textGiveUp: const Duration(milliseconds: 100),
    );
    addTearDown(remote.close);
    final tvField = FakeField();
    await fake.focus(tvField);
    final field = (await remote.textFieldChanges.firstWhere((field) => field != null))!;
    for (final text in ['Hi', 'Hello', 'Hi']) {
      expect(await field.setText(text), text);
    }
    final connection = await fake.connection.future;
    connection.latency = const Duration(milliseconds: 150);
    // Given up on: the TV applied it, but its report is still on the way.
    expect(await field.setText('Hello world'), 'Hi');
    connection.latency = const Duration(milliseconds: 10);
    // Sent with the revision from before 'Hello world', so the TV drops it; the late report comes while it waits.
    expect(await field.setText('Hello world!'), 'Hello world!');
    expect(tvField.text, 'Hello world!');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('keys, with the cursor away from the end, when the cursor report takes longer than the Move End wait', () async {
    final fake = FakeSession()..latency = const Duration(milliseconds: 400);
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.ime},
      textGiveUp: const Duration(milliseconds: 100),
    );
    addTearDown(remote.close);
    // A field that inserts edits at the cursor teaches the session that this TV takes keys.
    await fake.focus(FakeField(text: 'x', honoursRanges: false));
    final first = (await remote.textFieldChanges.firstWhere((field) => field != null))!;
    await first.setText('');
    final tvField = FakeField(text: 'abcd', cursor: 0, honoursRanges: false, reportCursorMoves: true);
    await fake.focus(tvField);
    final field = (await remote.textFieldChanges.firstWhere((field) => field != null && field.text == 'abcd'))!;
    final changes = <String>[];
    field.changes.listen(changes.add);
    expect(await field.setText('abcdX'), 'abcdX');
    expect(tvField.text, 'abcdX');
    expect(tvField.dropped, isEmpty, reason: 'no edit went with a revision from before the cursor moved');
    expect(changes, isEmpty, reason: 'the report of the cursor is not a change made on the TV');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('setVolume reaches its level when each report takes longer than stepTimeout', () async {
    final fake = FakeSession()..latency = const Duration(milliseconds: 250);
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
    );
    addTearDown(remote.close);
    await remote.setVolume(5, stepTimeout: const Duration(milliseconds: 100));
    expect(remote.state.volume!.level, 5);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a voice session opens and its end is confirmed when the answers take longer than the timeouts', () async {
    final fake = FakeSession()..latency = const Duration(milliseconds: 250);
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.voice},
    );
    addTearDown(remote.close);
    final voice = await remote.startVoice(timeout: const Duration(milliseconds: 100), pace: false);
    await voice.add(List.filled(TvVoiceSession.chunkBytes, 0));
    await voice.close();
    expect(voice.endConfirmed, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
