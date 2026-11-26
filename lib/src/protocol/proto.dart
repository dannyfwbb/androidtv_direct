// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The subset of the protobuf wire format the TV uses, written from the protobuf encoding specification.
///
/// Messages are read into a flat list of [ProtoField]s and written with a [ProtoWriter]. There is no schema here: the
/// message classes in `pairing_messages.dart` and `remote_messages.dart` say what each field means.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/varint.dart';

/// How a field's value is laid out on the wire.
enum WireType {
  /// A varint.
  varint(0),

  /// Eight bytes, little-endian.
  fixed64(1),

  /// A varint length, then that many bytes: strings, bytes and nested messages.
  lengthDelimited(2),

  /// Four bytes, little-endian.
  fixed32(5);

  const WireType(this.id);

  /// The three bits that encode it in a field key.
  final int id;
}

/// One field of a protobuf message as it was on the wire.
final class ProtoField {
  /// A varint field.
  ProtoField.varint(this.number, int value) : wireType = WireType.varint, _payload = _Varint(value) {
    _checkNumber(number);
  }

  /// A length-delimited field.
  ProtoField.bytes(this.number, List<int> value)
    : wireType = WireType.lengthDelimited,
      _payload = _Bytes(Uint8List.fromList(value)) {
    _checkNumber(number);
  }

  ProtoField._(this.number, this.wireType, this._payload);

  /// The field number.
  final int number;

  /// How the value is encoded.
  final WireType wireType;

  final _Payload _payload;

  /// The value of a varint field.
  int get asInt => switch (_payload) {
    _Varint(:final value) => value,
    _Bytes() => throw _mismatch('a varint'),
  };

  /// The value of a length-delimited field. Do not modify it.
  Uint8List get asBytes => switch (_payload) {
    _Bytes(:final bytes) when wireType == WireType.lengthDelimited => bytes,
    _ => throw _mismatch('length-delimited'),
  };

  /// The value of a length-delimited field as UTF-8 text.
  String get asString => utf8.decode(asBytes);

  /// Writes the value as it was read: a varint, a length and bytes, or fixed bytes.
  void _writeValue(BytesBuilder out) {
    switch (_payload) {
      case _Varint(:final value):
        writeVarint(out, value);
      case _Bytes(:final bytes):
        if (wireType == WireType.lengthDelimited) writeVarint(out, bytes.length);
        out.add(bytes);
    }
  }

  FormatException _mismatch(String expected) =>
      FormatException('Field $number is ${wireType.name}, expected $expected');

  @override
  String toString() => switch (_payload) {
    _Varint(:final value) => '$number: $value',
    _Bytes(:final bytes) => '$number: ${wireType.name} (${bytes.length} bytes)',
  };

  static bool _validNumber(int number) => number >= 1 && number <= _maxFieldNumber;

  static void _checkNumber(int number) {
    if (!_validNumber(number)) throw RangeError.range(number, 1, _maxFieldNumber, 'number');
  }
}

const int _maxFieldNumber = (1 << 29) - 1;

/// What a field holds: a varint's value, or the bytes of every other wire type.
sealed class _Payload {
  const _Payload();
}

final class _Varint extends _Payload {
  const _Varint(this.value);

  final int value;
}

final class _Bytes extends _Payload {
  const _Bytes(this.bytes);

  final Uint8List bytes;
}

/// Reads the fields of one protobuf message.
///
/// Reading is flat: nested messages stay bytes until a message class decodes them, and the classes nest only as deep
/// as their fixed types, so there is no recursion to cap. (The one echoed message, a refusal's, is decoded on demand.)
abstract final class ProtoReader {
  /// Every field in [bytes], in wire order.
  ///
  /// Throws [FormatException] for anything that is not a well-formed message: a truncated field, a length past the
  /// end, field number zero, groups (wire types 3 and 4, which this protocol never uses) or an unknown wire type.
  static List<ProtoField> read(Uint8List bytes) {
    final fields = <ProtoField>[];
    var offset = 0;
    while (offset < bytes.length) {
      final key = readVarint(bytes, offset);
      offset += key.length;
      final number = key.value >> 3;
      if (!ProtoField._validNumber(number)) throw FormatException('Invalid field number $number');
      final (field, next) = _readValue(bytes, offset, number, key.value & 7);
      fields.add(field);
      offset = next;
    }
    return fields;
  }

  static (ProtoField, int) _readValue(Uint8List bytes, int offset, int number, int type) {
    switch (type) {
      case 0:
        final value = readVarint(bytes, offset);
        return (ProtoField._(number, WireType.varint, _Varint(value.value)), offset + value.length);
      case 1:
        return _fixed(bytes, offset, number, WireType.fixed64, 8);
      case 2:
        final length = readVarint(bytes, offset);
        final start = offset + length.length;
        if (length.value < 0 || length.value > bytes.length - start) {
          throw FormatException('Field $number is longer than the message');
        }
        return _slice(bytes, start, number, WireType.lengthDelimited, length.value);
      case 5:
        return _fixed(bytes, offset, number, WireType.fixed32, 4);
      default:
        throw FormatException('Field $number has unsupported wire type $type');
    }
  }

  static (ProtoField, int) _fixed(Uint8List bytes, int offset, int number, WireType type, int width) {
    if (bytes.length - offset < width) throw FormatException('Field $number is truncated');
    return _slice(bytes, offset, number, type, width);
  }

  static (ProtoField, int) _slice(Uint8List bytes, int start, int number, WireType type, int length) {
    final value = Uint8List.sublistView(bytes, start, start + length);
    return (ProtoField._(number, type, _Bytes(value)), start + length);
  }
}

/// The fields of one message, read by number.
///
/// A message class asks for each field it models; [unknown] then gives the rest, in wire order. Each getter returns
/// the last value of its field, as protobuf does for scalars, and checks the wire type of every occurrence, so a
/// malformed earlier copy is still a [FormatException].
final class ProtoFields {
  /// Reads [bytes]. Throws [FormatException] if they are not a well-formed message.
  ProtoFields.read(Uint8List bytes) : _fields = ProtoReader.read(bytes);

  final List<ProtoField> _fields;
  final Set<int> _taken = {};

  /// Field [number] as a varint.
  int? integer(int number) => _last(number, (field) => field.asInt);

  /// Field [number] as UTF-8 text.
  String? string(int number) => _last(number, (field) => field.asString);

  /// Field [number] as bytes.
  Uint8List? bytes(int number) => _last(number, (field) => field.asBytes);

  /// Field [number] as a nested message.
  T? message<T extends Object>(int number, T Function(Uint8List bytes) decode) =>
      _last(number, (field) => decode(field.asBytes));

  /// Every occurrence of field [number], each a nested message.
  List<T> repeated<T>(int number, T Function(Uint8List bytes) decode) {
    _taken.add(number);
    return [
      for (final field in _fields)
        if (field.number == number) decode(field.asBytes),
    ];
  }

  /// The fields no getter asked for, for [ProtoMessage.unknownFields].
  List<ProtoField> get unknown => [
    for (final field in _fields)
      if (!_taken.contains(field.number)) field,
  ];

  T? _last<T extends Object>(int number, T Function(ProtoField field) read) {
    _taken.add(number);
    T? value;
    for (final field in _fields) {
      if (field.number == number) value = read(field);
    }
    return value;
  }
}

/// Builds one protobuf message.
///
/// Fields come out in ascending field number, whatever order they were added in, as every message recorded from the
/// TV has them; fields with the same number keep the order they were added in. The `optional…` methods skip `null`,
/// so a message class writes exactly the fields it read.
final class ProtoWriter {
  final List<({int number, int order, Uint8List bytes})> _fields = [];

  /// Adds a varint field.
  void varint(int number, int value) => _add(number, WireType.varint, (out) => writeVarint(out, value));

  /// Adds a length-delimited field.
  void bytes(int number, List<int> value) => _add(number, WireType.lengthDelimited, (out) {
    writeVarint(out, value.length);
    out.add(value);
  });

  /// Adds a UTF-8 string field.
  void string(int number, String value) => bytes(number, utf8.encode(value));

  /// Adds a nested message.
  void message(int number, ProtoMessage value) => bytes(number, value.encode());

  /// Adds every message in [values] as field [number], in order.
  void repeatedMessage(int number, Iterable<ProtoMessage> values) {
    for (final value in values) {
      message(number, value);
    }
  }

  /// Adds a varint field unless [value] is `null`.
  void optionalVarint(int number, int? value) {
    if (value != null) varint(number, value);
  }

  /// Adds a length-delimited field unless [value] is `null`.
  void optionalBytes(int number, List<int>? value) {
    if (value != null) bytes(number, value);
  }

  /// Adds a string field unless [value] is `null`.
  void optionalString(int number, String? value) {
    if (value != null) string(number, value);
  }

  /// Adds a nested message unless [value] is `null`.
  void optionalMessage(int number, ProtoMessage? value) {
    if (value != null) message(number, value);
  }

  /// Adds fields exactly as they were read.
  void raw(Iterable<ProtoField> fields) {
    for (final field in fields) {
      _add(field.number, field.wireType, field._writeValue);
    }
  }

  /// The encoded message: fields by number, fields with the same number in the order they were added.
  Uint8List toBytes() {
    final sorted = [..._fields]
      ..sort((a, b) => a.number != b.number ? a.number.compareTo(b.number) : a.order.compareTo(b.order));
    final out = BytesBuilder(copy: false);
    for (final field in sorted) {
      out.add(field.bytes);
    }
    return out.takeBytes();
  }

  void _add(int number, WireType type, void Function(BytesBuilder out) value) {
    ProtoField._checkNumber(number);
    final out = BytesBuilder(copy: false);
    writeVarint(out, number << 3 | type.id);
    value(out);
    _fields.add((number: number, order: _fields.length, bytes: out.takeBytes()));
  }
}

/// Whether a wire value that may be absent is set: present and not zero.
extension WireFlag on int? {
  /// Whether this is present and not zero.
  bool get isSet => (this ?? 0) != 0;
}

/// A message that can be written to the wire.
///
/// Every message keeps the fields it did not recognise in [unknownFields] and writes them back, so decoding and
/// encoding a message gives the same bytes, also when the TV adds fields, as long as the message has its fields in
/// ascending order and each modelled scalar once, as every message recorded from TVs has. Otherwise the encoding is
/// the normalised one (fields sorted, the last value of a repeated scalar), and encoding it again is stable.
abstract base class ProtoMessage {
  /// Creates a message that carries [unknownFields].
  ProtoMessage(Iterable<ProtoField> unknownFields) : unknownFields = List.unmodifiable(unknownFields);

  /// Fields this package does not model, as they were read.
  final List<ProtoField> unknownFields;

  /// Writes the fields this class models.
  void writeFields(ProtoWriter writer);

  /// The message in wire format.
  Uint8List encode() {
    final writer = ProtoWriter();
    writeFields(writer);
    writer.raw(unknownFields);
    return writer.toBytes();
  }
}
