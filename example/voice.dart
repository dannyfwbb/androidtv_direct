// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Sends a recording to the TV's voice search, paced in real time as a microphone would deliver it.
//
//   dart run example/voice.dart <host> <speech.wav>
//
// The recording is a WAV file of 16-bit PCM, mono, 8 kHz (for example `sox speech.mp3 -r 8000 -c 1 -b 16 speech.wav`).
// If the TV ends the voice session before the end of the file (it heard enough), the rest is dropped. Needs a TV paired
// by androidtv_direct_example.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';

import 'paired.dart';

Future<void> main(List<String> args) async {
  final [host, path] = args;
  final Uint8List audio;
  try {
    audio = _pcmOf(File(path).readAsBytesSync());
  } on FormatException catch (e) {
    stderr.writeln('${e.message}. Convert it with: sox $path -r 8000 -c 1 -b 16 speech.wav');
    exit(1);
  }
  final remote = await connectPaired(host, features: {TvFeature.voice});
  try {
    final voice = await remote.startVoice();
    await voice.add(audio);
    await voice.close();
    print('Sent ${audio.length ~/ TvVoiceSession.bytesPerSecond} s of audio; the TV answers on its screen.');
  } finally {
    await remote.close();
  }
}

/// The samples of a WAV file, which must hold 16-bit PCM, mono, at 8 kHz.
Uint8List _pcmOf(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  String tag(int at) => String.fromCharCodes(wav, at, at + 4);
  if (wav.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('Not a WAV file');
  ({int format, int channels, int rate, int bits})? format;
  // The file is a list of chunks: a four-letter tag, a little-endian length, the body (padded to an even length).
  for (var at = 12; at + 8 <= wav.length; at += 8 + _even(data.getUint32(at + 4, Endian.little))) {
    final length = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    switch (tag(at)) {
      case 'fmt ' when length >= 16:
        format = (
          format: data.getUint16(body, Endian.little),
          channels: data.getUint16(body + 2, Endian.little),
          rate: data.getUint32(body + 4, Endian.little),
          bits: data.getUint16(body + 14, Endian.little),
        );
      case 'data':
        if (format != (format: 1, channels: 1, rate: 8000, bits: 16)) {
          throw FormatException('Needs 16-bit PCM, mono, 8 kHz; this file has $format');
        }
        return Uint8List.sublistView(wav, body, (body + length).clamp(body, wav.length));
    }
  }
  throw const FormatException('The WAV file has no audio');
}

int _even(int length) => length + length % 2;
