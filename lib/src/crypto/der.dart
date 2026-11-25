// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/crypto/der.dart.

import 'dart:convert';
import 'dart:typed_data';

/// The small subset of ASN.1 DER this library writes and reads: what RSA keys (PKCS#1, PKCS#8, SubjectPublicKeyInfo)
/// and a self-signed X.509 certificate need. Not a general ASN.1 library.
abstract final class Der {
  /// BOOLEAN.
  static const int tagBoolean = 0x01;

  /// INTEGER.
  static const int tagInteger = 0x02;

  /// BIT STRING.
  static const int tagBitString = 0x03;

  /// OCTET STRING.
  static const int tagOctetString = 0x04;

  /// NULL.
  static const int tagNull = 0x05;

  /// OBJECT IDENTIFIER.
  static const int tagObjectIdentifier = 0x06;

  /// UTF8String.
  static const int tagUtf8String = 0x0c;

  /// PrintableString.
  static const int tagPrintableString = 0x13;

  /// UTCTime.
  static const int tagUtcTime = 0x17;

  /// GeneralizedTime.
  static const int tagGeneralizedTime = 0x18;

  /// SEQUENCE (constructed).
  static const int tagSequence = 0x30;

  /// SET (constructed).
  static const int tagSet = 0x31;

  /// A tag-length-value element with [tag] and [content].
  static Uint8List element(int tag, List<int> content) {
    final length = _length(content.length);
    return Uint8List(1 + length.length + content.length)
      ..[0] = tag
      ..setRange(1, 1 + length.length, length)
      ..setRange(1 + length.length, 1 + length.length + content.length, content);
  }

  /// SEQUENCE of already encoded [items].
  static Uint8List sequence(List<List<int>> items) => element(tagSequence, [for (final item in items) ...item]);

  /// SET of already encoded [items] (one item in all uses here, so no sorting is needed).
  static Uint8List set(List<List<int>> items) => element(tagSet, [for (final item in items) ...item]);

  /// INTEGER (two's complement, minimal length).
  static Uint8List integer(BigInt value) => element(tagInteger, signedBytes(value));

  /// INTEGER from a small int.
  static Uint8List smallInteger(int value) => integer(BigInt.from(value));

  /// BOOLEAN.
  static Uint8List boolean(bool value) => element(tagBoolean, [value ? 0xff : 0x00]);

  /// NULL.
  static Uint8List nullValue() => element(tagNull, const []);

  /// OBJECT IDENTIFIER from dotted text such as `1.2.840.113549.1.1.1`.
  static Uint8List objectIdentifier(String dotted) {
    final arcs = dotted.split('.').map(int.parse).toList();
    if (arcs.length < 2 || arcs.any((arc) => arc < 0) || arcs[0] > 2 || (arcs[0] < 2 && arcs[1] >= 40)) {
      throw ArgumentError.value(dotted, 'dotted', 'not a valid OID');
    }
    final out = <int>[..._base128(arcs[0] * 40 + arcs[1]), for (final arc in arcs.skip(2)) ..._base128(arc)];
    return element(tagObjectIdentifier, out);
  }

  static List<int> _base128(int value) {
    final groups = <int>[value & 0x7f];
    for (var rest = value >> 7; rest > 0; rest >>= 7) {
      groups.add((rest & 0x7f) | 0x80);
    }
    return groups.reversed.toList();
  }

  /// BIT STRING with no unused bits.
  static Uint8List bitString(List<int> bytes) => element(tagBitString, [0, ...bytes]);

  /// OCTET STRING.
  static Uint8List octetString(List<int> bytes) => element(tagOctetString, bytes);

  /// PrintableString (ASCII letters, digits, space and `'()+,-./:=?`).
  static Uint8List printableString(String text) => element(tagPrintableString, ascii.encode(text));

  /// UTF8String.
  static Uint8List utf8String(String text) => element(tagUtf8String, utf8.encode(text));

  /// A certificate validity time: UTCTime for 1950 through 2049, GeneralizedTime from 2050 on, as RFC 5280 4.1.2.5
  /// requires. Seconds precision, UTC. Earlier years cannot be encoded unambiguously and are refused.
  static Uint8List time(DateTime time) {
    final t = time.toUtc();
    if (t.year < 1950) throw ArgumentError.value(time, 'time', 'years before 1950');
    String two(int v) => v.toString().padLeft(2, '0');
    final rest = '${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    return t.year < 2050
        ? element(tagUtcTime, ascii.encode('${two(t.year % 100)}$rest'))
        : element(tagGeneralizedTime, ascii.encode('${t.year.toString().padLeft(4, '0')}$rest'));
  }

  /// A context-specific constructed tag `[number]` around [content].
  static Uint8List explicit(int number, List<int> content) => element(0xa0 | number, content);

  /// The minimal two's complement big-endian bytes of [value].
  static Uint8List signedBytes(BigInt value) {
    if (value == BigInt.zero) return Uint8List.fromList([0]);
    if (value.isNegative) throw ArgumentError.value(value, 'value', 'negative values are unused');
    final magnitude = unsignedBytes(value);
    return magnitude[0] & 0x80 != 0 ? Uint8List.fromList([0, ...magnitude]) : magnitude;
  }

  /// The big-endian bytes of a non-negative [value], without sign padding, left-padded with zeros to [length] when
  /// given.
  static Uint8List unsignedBytes(BigInt value, {int? length}) {
    if (value.isNegative) throw ArgumentError.value(value, 'value');
    final count = value == BigInt.zero ? 1 : (value.bitLength + 7) ~/ 8;
    final bytes = Uint8List(count);
    var rest = value;
    for (var i = count - 1; i >= 0; i--) {
      bytes[i] = (rest & _byteMask).toInt();
      rest >>= 8;
    }
    if (length == null || length == bytes.length) return bytes;
    if (bytes.length > length) throw ArgumentError('Value needs ${bytes.length} bytes, more than $length');
    return Uint8List(length)..setRange(length - bytes.length, length, bytes);
  }

  static final BigInt _byteMask = BigInt.from(0xff);

  /// The non-negative integer of big-endian [bytes].
  static BigInt unsignedValue(List<int> bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  static List<int> _length(int length) {
    if (length < 0x80) return [length];
    final bytes = [for (var rest = length; rest > 0; rest >>= 8) rest & 0xff].reversed;
    return [0x80 | bytes.length, ...bytes];
  }
}

/// One decoded DER element.
///
/// Reading is lenient where it does not matter for the keys read here: a length or an INTEGER in a non-minimal form is
/// accepted. What would change a value (truncation, trailing bytes, negative integers) is refused.
final class DerElement {
  DerElement._(this.tag, this.content, this.encoded);

  /// Decodes exactly one element spanning all of [bytes].
  factory DerElement.parse(List<int> bytes) {
    final reader = _DerReader(Uint8List.fromList(bytes));
    final element = reader.next();
    if (!reader.atEnd) throw const FormatException('Trailing bytes after a DER element');
    return element;
  }

  /// The tag byte.
  final int tag;

  /// The content octets.
  final Uint8List content;

  /// The whole element as it was encoded: tag, length and content.
  final Uint8List encoded;

  /// The elements inside a SEQUENCE or SET.
  List<DerElement> get children {
    if (tag & 0x20 == 0) throw FormatException('Tag 0x${tag.toRadixString(16)} is primitive');
    final reader = _DerReader(content);
    return [for (; !reader.atEnd;) reader.next()];
  }

  /// The children of a SEQUENCE; throws if this is not one.
  List<DerElement> get sequence {
    _expect(Der.tagSequence, 'SEQUENCE');
    return children;
  }

  /// The value of an INTEGER; throws for negative values, which no field read here may hold.
  BigInt get integer {
    _expect(Der.tagInteger, 'INTEGER');
    if (content.isEmpty) throw const FormatException('Empty INTEGER');
    if (content[0] & 0x80 != 0) throw const FormatException('Negative INTEGER');
    return Der.unsignedValue(content);
  }

  /// The bytes of an OCTET STRING.
  Uint8List get octets {
    _expect(Der.tagOctetString, 'OCTET STRING');
    return content;
  }

  /// The bytes of a BIT STRING with no unused bits.
  Uint8List get bits {
    _expect(Der.tagBitString, 'BIT STRING');
    if (content.isEmpty || content[0] != 0) throw const FormatException('BIT STRING with unused bits');
    return Uint8List.sublistView(content, 1);
  }

  /// The text of a string element: UTF8String, PrintableString, IA5String or TeletexString (read as Latin-1, as
  /// certificates in practice use it).
  String get text => switch (tag) {
    Der.tagUtf8String => utf8.decode(content),
    Der.tagPrintableString || _tagIa5String || _tagTeletexString => latin1.decode(content),
    _ => throw FormatException('Tag 0x${tag.toRadixString(16)} is not a string'),
  };

  static const int _tagTeletexString = 0x14;
  static const int _tagIa5String = 0x16;

  /// The dotted text of an OBJECT IDENTIFIER.
  String get objectIdentifier {
    _expect(Der.tagObjectIdentifier, 'OBJECT IDENTIFIER');
    if (content.isEmpty || content.last & 0x80 != 0) throw const FormatException('Truncated OBJECT IDENTIFIER');
    final subidentifiers = <int>[];
    var value = 0;
    for (final byte in content) {
      value = (value << 7) | (byte & 0x7f);
      if (byte & 0x80 == 0) {
        subidentifiers.add(value);
        value = 0;
      }
    }
    final first = subidentifiers.first;
    final arc0 = first < 80 ? first ~/ 40 : 2;
    return [arc0, first - arc0 * 40, ...subidentifiers.skip(1)].join('.');
  }

  void _expect(int expected, String name) {
    if (tag != expected) throw FormatException('Expected $name, found tag 0x${tag.toRadixString(16)}');
  }
}

final class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get atEnd => _offset >= _bytes.length;

  DerElement next() {
    final start = _offset;
    final tag = _byte();
    if (tag & 0x1f == 0x1f) throw const FormatException('High tag numbers are not supported');
    var length = _byte();
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) throw const FormatException('Unsupported DER length');
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _byte();
      }
    }
    if (_offset + length > _bytes.length) throw const FormatException('DER element runs past the end');
    final content = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return DerElement._(tag, content, Uint8List.sublistView(_bytes, start, _offset));
  }

  int _byte() {
    if (atEnd) throw const FormatException('Truncated DER');
    return _bytes[_offset++];
  }
}
