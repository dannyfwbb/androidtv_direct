// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'test_tv.dart';

/// Two seconds of a 440 Hz tone, 16-bit little-endian PCM, mono, 8 kHz.
Uint8List tone() {
  final samples = ByteData(2 * 16000);
  for (var i = 0; i < 16000; i++) {
    samples.setInt16(i * 2, (8000 * sin(2 * pi * 440 * i / 8000)).round(), Endian.little);
  }
  return samples.buffer.asUint8List();
}

void main() {
  group('voice', skip: TestTv.skip, () {
    test('Search opens a session; audio and close go through; the TV ends it', () async {
      final (identity, fingerprint) = await TestTv.pairFresh();
      final remote = await TvRemote.connect(
        TestTv.host!,
        identity: identity,
        fingerprint: fingerprint,
        features: {...TvFeature.defaults, TvFeature.voice},
      );
      addTearDown(() async {
        await remote.close();
        await TestTv.shell(['input', 'keyevent', 'KEYCODE_HOME']);
      });
      final voice = await remote.startVoice(pace: false);
      await voice.add(tone());
      await voice.close();
      await voice.done.timeout(const Duration(seconds: 5));
      expect(remote.isClosed, isFalse);
    });
  });
}
