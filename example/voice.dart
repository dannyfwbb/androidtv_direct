// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Sends a recording to the TV's voice search, paced in real time as a microphone would deliver it.
//
//   dart run example/voice.dart <host> <audio.raw>
//
// Reads `identity.pem` and `tv-<host>.fingerprint`, which androidtv_direct_example.dart writes after pairing. If the
// TV ends the voice session before the end of the file (it heard enough), the rest is dropped.
// The audio is raw 16-bit little-endian PCM, mono, 8 kHz (for example `sox speech.wav -r 8000 -c 1 -b 16 -e signed
// -L speech.raw`).

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

Future<void> main(List<String> args) async {
  final [host, audio] = args;
  final identity = TvClientIdentity.fromPem(File('identity.pem').readAsStringSync());
  final fingerprint = File('tv-$host.fingerprint').readAsStringSync().trim();
  final remote = await TvRemote.connect(
    host,
    identity: identity,
    fingerprint: fingerprint,
    features: {...TvFeature.defaults, TvFeature.voice},
  );
  final voice = await remote.startVoice();
  await voice.addStream(File(audio).openRead());
  await voice.close();
  print('Sent ${File(audio).lengthSync()} bytes; the TV answers on its screen.');
  await remote.close();
}
