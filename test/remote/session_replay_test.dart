// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/pairing_messages.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/hex.dart';

/// The package's own recording of a pairing and a session with the Android TV Remote Service.
final List<RecordedMessage> session = recordedMessages('session.txt');

void main() {
  test('every recorded message decodes to its kind and encodes to the same bytes', () {
    for (final m in session) {
      final kind = m.name.split('.').first;
      final Object message;
      if (m.port == 6467) {
        message = PairingMessage.decode(m.bytes);
        expect((message as PairingMessage).kind, kind);
        expect(hex(message.encode()), hex(m.bytes), reason: m.name);
      } else {
        message = m.outgoing ? RemoteEnvelope.fromClient(m.bytes) : RemoteEnvelope.fromTv(m.bytes);
        expect((message as RemoteEnvelope).kind, kind, reason: m.name);
        expect(hex(message.encodeEnvelope()), hex(m.bytes), reason: m.name);
      }
    }
  });

  test("the session answers the TV's recorded start and ping with the recorded bytes", () async {
    final start = [
      for (final m in session)
        if (m.port == 6466) m,
    ].takeWhile((m) => m.name != 'key').toList();
    final tv = await startFakeTv(
      onRemote: (c) => c.run([
        for (final m in start) m.outgoing ? FakeTvExpect.bytes(m.bytes) : FakeTvSend(m.bytes),
        const FakeTvExpect('nothing more', _never, timeout: Duration(milliseconds: 200)),
      ]),
    );
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: {...TvFeature.defaults, TvFeature.ime},
    );
    await remote.done;
    expect(tv.errors, ['step ${start.length + 1}: expected nothing more, got nothing']);
  });
}

bool _never(List<int> _) => false;
