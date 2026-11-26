// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/frame.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/hex.dart';

void main() {
  test('a frame is the body after its length as a varint', () {
    expect(hex(encodeFrame(unhex('4a020801'))), '044a020801');
    expect(hex(encodeFrame(Uint8List(200)).sublist(0, 2)), 'c801');
    expect(hex(encodeFrame(const [])), '00');
  });

  test('splitting the recorded stream at every position gives the same frames', () {
    // Every message but the 20 KiB voice chunks, which the byte-by-byte test below covers: splitting a stream at every
    // position costs the square of its length.
    final bodies = [
      for (final file in recordingFiles)
        for (final m in recordedMessages(file))
          if (m.bytes.length < 1024) m.bytes,
    ];
    final stream = Uint8List.fromList([for (final body in bodies) ...encodeFrame(body)]);
    for (var split = 0; split <= stream.length; split++) {
      final reader = FrameReader();
      final frames = [...reader.add(stream.sublist(0, split)), ...reader.add(stream.sublist(split))];
      expect(frames.map(hex), bodies.map(hex), reason: 'split at $split');
      expect(reader.pendingLength, 0);
    }
  });

  test('byte by byte, a large frame comes out whole and once', () {
    final body = Uint8List.fromList(List.generate(20480, (i) => i));
    final reader = FrameReader();
    final frames = <Uint8List>[];
    for (final byte in encodeFrame(body)) {
      frames.addAll(reader.add([byte]));
    }
    expect(frames, hasLength(1));
    expect(frames.single, body);
  });

  test('frames do not share memory with the reader', () {
    final reader = FrameReader();
    final first = reader.add(encodeFrame([1, 2, 3])).single;
    reader.add(encodeFrame([4, 5, 6]));
    expect(first, [1, 2, 3]);
  });

  test('a length over the cap fails as soon as it is read, before any body', () {
    final reader = FrameReader(maxFrameLength: 1000);
    expect(reader.add(encodeFrame(Uint8List(1000))), hasLength(1));
    expect(() => reader.add(unhex('e907')), throwsFormatException);
    expect(() => FrameReader().add(unhex('ffffffff0f')), throwsFormatException);
  });

  test('a length prefix longer than ten bytes fails', () {
    expect(() => FrameReader().add(unhex('8080808080808080808080')), throwsFormatException);
  });

  test('one large chunk is not buffered past the cap', () {
    final reader = FrameReader(maxFrameLength: 32);
    final chunk = [...encodeFrame(Uint8List(32)), ...encodeFrame(Uint8List(5)), 0x7f, ...List.filled(100, 0)];
    expect(() => reader.add(chunk), throwsFormatException);
    expect(reader.capacity, lessThanOrEqualTo(64));
  });

  test('random bytes give frames or a format error, and never buffer past the cap', () {
    final random = Random(2);
    const cap = 32;
    for (var i = 0; i < 100000; i++) {
      final reader = FrameReader(maxFrameLength: cap);
      try {
        for (var chunk = 0; chunk < 4; chunk++) {
          reader.add(List.generate(random.nextInt(256), (_) => random.nextInt(256)));
        }
      } on FormatException {
        // Expected for most inputs.
      }
      expect(reader.pendingLength, lessThanOrEqualTo(cap + 10));
      expect(reader.capacity, lessThanOrEqualTo(64));
    }
  });
}
