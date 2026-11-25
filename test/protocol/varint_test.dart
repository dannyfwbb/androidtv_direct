// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/varint.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

String encode(int value) {
  final out = BytesBuilder();
  writeVarint(out, value);
  return hex(out.takeBytes());
}

void main() {
  test('writes base-128 groups, low group first', () {
    expect(encode(0), '00');
    expect(encode(1), '01');
    expect(encode(127), '7f');
    expect(encode(128), '8001');
    expect(encode(615), 'e704');
    expect(encode(1394860), 'ac9155');
    expect(encode(0x7fffffffffffffff), 'ffffffffffffffff7f');
  });

  test('writes negative values as 64-bit two\'s complement and reads them back', () {
    expect(encode(-1), 'ffffffffffffffffff01');
    expect(readVarint(unhex('ffffffffffffffffff01'), 0).value, -1);
  });

  test('reads what it writes, at an offset', () {
    for (final value in [0, 1, 127, 128, 300, 615, 2131362240, 0x7fffffffffffffff]) {
      final bytes = Uint8List.fromList([0xaa, ...unhex(encode(value))]);
      expect(readVarint(bytes, 1), (value: value, length: bytes.length - 1));
    }
  });

  test('a varint cut short is incomplete, not an error', () {
    expect(tryReadVarint(unhex('8080'), 0), isNull);
    expect(tryReadVarint(unhex('e704'), 0, 1), isNull);
    expect(() => readVarint(unhex('80'), 0), throwsFormatException);
  });

  test('reads ten-byte varints up to 64 bits and refuses longer ones', () {
    expect(readVarint(unhex('ffffffffffffffffff01'), 0).length, 10);
    expect(() => readVarint(unhex('ffffffffffffffffff02'), 0), throwsFormatException);
    expect(() => readVarint(unhex('ffffffffffffffffff8001'), 0), throwsFormatException);
  });
}
