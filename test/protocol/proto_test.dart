// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

void main() {
  group('ProtoReader', () {
    test('reads every wire type the protocol may use', () {
      // 1: varint 150; 2: "hi"; 3: fixed64; 4: fixed32 (checked with protoc --decode_raw).
      final fields = ProtoReader.read(unhex('089601120268691901020304050607082d01020304'));
      expect(fields.map((f) => (f.number, f.wireType)), [
        (1, WireType.varint),
        (2, WireType.lengthDelimited),
        (3, WireType.fixed64),
        (5, WireType.fixed32),
      ]);
      expect(fields[0].asInt, 150);
      expect(fields[1].asString, 'hi');
      expect(hex((ProtoWriter()..raw(fields)).toBytes()), '089601120268691901020304050607082d01020304');
    });

    test('refuses groups, unknown wire types and field number zero', () {
      expect(() => ProtoReader.read(unhex('0b0c')), throwsFormatException);
      expect(() => ProtoReader.read(unhex('0e00')), throwsFormatException);
      expect(() => ProtoReader.read(unhex('0001')), throwsFormatException);
    });

    test('refuses lengths and fixed values past the end', () {
      expect(() => ProtoReader.read(unhex('0a05616263')), throwsFormatException);
      expect(() => ProtoReader.read(unhex('0a8080808010')), throwsFormatException);
      expect(() => ProtoReader.read(unhex('0d0102')), throwsFormatException);
      expect(() => ProtoReader.read(unhex('08')), throwsFormatException);
    });

    test('a field of the wrong wire type is a format error', () {
      final field = ProtoReader.read(unhex('0801')).single;
      expect(() => field.asBytes, throwsFormatException);
      expect(() => field.asString, throwsFormatException);
      expect(() => ProtoReader.read(unhex('0a00')).single.asInt, throwsFormatException);
    });

    test('invalid UTF-8 in a string is a format error', () {
      expect(() => ProtoReader.read(unhex('0a01ff')).single.asString, throwsFormatException);
    });

    test('random bytes give fields or a format error, nothing else', () {
      final random = Random(1);
      for (var i = 0; i < 100000; i++) {
        final bytes = Uint8List.fromList(List.generate(random.nextInt(48), (_) => random.nextInt(256)));
        try {
          ProtoReader.read(bytes);
        } on FormatException {
          // Expected for most inputs.
        }
      }
    });
  });

  group('ProtoFields', () {
    test('gives the last value of each field and the fields nobody asked for', () {
      final fields = ProtoFields.read(unhex('08011802080a220161'));
      expect(fields.integer(1), 10);
      expect(fields.string(4), 'a');
      expect(fields.integer(9), isNull);
      expect(fields.unknown.map((f) => f.number), [3]);
    });

    test('checks the wire type of every occurrence, not only the last', () {
      expect(() => ProtoFields.read(unhex('0a000801')).integer(1), throwsFormatException);
    });

    test('repeated messages come in wire order', () {
      final fields = ProtoFields.read(unhex('0a016112020801 0a0162'.replaceAll(' ', '')));
      expect(fields.repeated(1, String.fromCharCodes), ['a', 'b']);
      expect(fields.unknown.single.number, 2);
    });
  });

  group('ProtoWriter', () {
    test('writes fields in ascending number, keeping the order of repeated ones', () {
      final writer = ProtoWriter()
        ..string(3, 'c')
        ..varint(1, 1)
        ..bytes(2, [0xaa])
        ..varint(1, 2);
      expect(hex(writer.toBytes()), '080108021201aa1a0163');
    });

    test('optional methods skip null and write explicit zeros', () {
      final writer = ProtoWriter()
        ..optionalVarint(1, null)
        ..optionalVarint(2, 0)
        ..optionalString(4, null)
        ..optionalString(5, '');
      expect(hex(writer.toBytes()), '10002a00');
    });

    test('refuses invalid field numbers', () {
      expect(() => ProtoWriter().varint(0, 1), throwsRangeError);
      expect(() => ProtoWriter().varint(1 << 29, 1), throwsRangeError);
    });
  });
}
