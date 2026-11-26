// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'support/fake_clock.dart';
import 'support/fake_field.dart';
import 'support/fake_session.dart';
import 'support/fake_tv.dart';
import 'support/fixtures.dart';
import 'support/wait.dart';

void main() {
  test('at the messages level no trace carries typed text, links or audio, also when the TV refuses a link', () async {
    const typed = 'secret-typed-text';
    const link = 'secretlink.example';
    final events = <TvTraceEvent>[];
    final fake = FakeSession();
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.ime, TvFeature.voice},
      clock: FakeClock(),
      tracer: TvTracer(events.add),
    );
    addTearDown(remote.close);
    await fake.focus(FakeField());
    await until(() => remote.textField != null);
    expect(await remote.textField!.setText(typed), typed);
    final voice = await remote.startVoice(pace: false);
    await voice.add(Uint8List.fromList(utf8.encode(typed * 2000)));
    await voice.close();
    remote.openLink(link);
    await remote.done;

    for (final event in events) {
      final text = event is TvMessageTrace ? '${event.kind} ${event.length}' : event.toString();
      expect(text, isNot(contains(typed)), reason: '$event');
      expect(text, isNot(contains('secretlink')), reason: '$event');
      if (event is TvMessageTrace) expect(event.raw, isNull);
    }
  });
}
