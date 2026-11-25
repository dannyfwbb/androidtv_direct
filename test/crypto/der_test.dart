// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

void main() {
  test('object identifiers', () {
    expect(hex(Der.objectIdentifier('1.2.840.113549.1.1.1')), '06092a864886f70d010101');
    expect(hex(Der.objectIdentifier('2.5.29.19')), '0603551d13');
    final parsed = DerElement.parse(Der.objectIdentifier('1.2.840.113549.1.1.11'));
    expect(parsed.objectIdentifier, '1.2.840.113549.1.1.11');
  });

  test('OIDs with large first and later arcs', () {
    for (final oid in ['2.999.3', '2.100.1', '1.39.4', '0.0', '1.2.4294967295']) {
      expect(DerElement.parse(Der.objectIdentifier(oid)).objectIdentifier, oid);
    }
    expect(hex(Der.objectIdentifier('2.999.3')), '0603883703');
    expect(() => Der.objectIdentifier('1.40'), throwsArgumentError);
    expect(() => Der.objectIdentifier('3.1'), throwsArgumentError);
    expect(() => DerElement.parse([0x06, 0x02, 0x2a, 0x86]).objectIdentifier, throwsFormatException);
  });

  test('integers are minimal two’s complement', () {
    expect(hex(Der.integer(BigInt.zero)), '020100');
    expect(hex(Der.integer(BigInt.from(127))), '02017f');
    expect(hex(Der.integer(BigInt.from(128))), '02020080');
    expect(hex(Der.integer(BigInt.from(65537))), '0203010001');
    final big = BigInt.parse('ff' * 40, radix: 16);
    expect(DerElement.parse(Der.integer(big)).integer, big);
  });

  test('lengths of 128 bytes and more use the long form', () {
    final content = List.filled(300, 7);
    final encoded = Der.octetString(content);
    expect(hex(encoded.sublist(0, 4)), '0482012c');
    expect(DerElement.parse(encoded).octets, content);
  });

  test('times switch from UTCTime to GeneralizedTime in 2050', () {
    expect(String.fromCharCodes(Der.time(DateTime.utc(2036, 1, 2, 3, 4, 5)).skip(2)), '360102030405Z');
    expect(Der.time(DateTime.utc(2049, 12, 31))[0], Der.tagUtcTime);
    final late = Der.time(DateTime.utc(2050, 1, 1));
    expect(late[0], Der.tagGeneralizedTime);
    expect(String.fromCharCodes(late.skip(2)), '20500101000000Z');
  });

  test('years before 1950 are refused', () {
    expect(() => Der.time(DateTime.utc(1949, 12, 31)), throwsArgumentError);
    expect(Der.time(DateTime.utc(1950))[0], Der.tagUtcTime);
  });

  test('unsigned bytes pad to a length and refuse to truncate', () {
    expect(Der.unsignedBytes(BigInt.from(0x0102), length: 4), [0, 0, 1, 2]);
    expect(() => Der.unsignedBytes(BigInt.from(0x010203), length: 2), throwsArgumentError);
  });

  test('sequences parse back into children', () {
    final encoded = Der.sequence([
      Der.smallInteger(1),
      Der.nullValue(),
      Der.bitString([1, 2]),
    ]);
    final children = DerElement.parse(encoded).sequence;
    expect(children, hasLength(3));
    expect(children[0].integer, BigInt.one);
    expect(children[1].tag, Der.tagNull);
    expect(children[2].bits, [1, 2]);
  });

  test('malformed input is a FormatException', () {
    expect(() => DerElement.parse([0x30, 0x05, 0x02]), throwsFormatException);
    expect(() => DerElement.parse([0x02, 0x01, 0x01, 0x00]), throwsFormatException);
    expect(() => DerElement.parse([0x02, 0x01, 0x80]).integer, throwsFormatException);
    expect(() => DerElement.parse([0x04, 0x00]).integer, throwsFormatException);
  });

  test('elements keep their whole encoding', () {
    final inner = Der.sequence([Der.smallInteger(5)]);
    final outer = DerElement.parse(Der.sequence([Der.nullValue(), inner]));
    expect(hex(outer.sequence[1].encoded), hex(inner));
  });

  test('string elements read as text', () {
    expect(DerElement.parse(Der.utf8String('Привет')).text, 'Привет');
    expect(DerElement.parse(Der.printableString('TV 1')).text, 'TV 1');
    expect(DerElement.parse([0x16, 0x02, 0x61, 0x62]).text, 'ab');
    expect(() => DerElement.parse(Der.smallInteger(1)).text, throwsFormatException);
  });
}
