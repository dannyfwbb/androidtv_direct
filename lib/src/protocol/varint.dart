// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// The longest varint protobuf allows: 64 bits in groups of seven.
const int maxVarintLength = 10;

/// A varint read from a buffer: its value and how many bytes it took.
typedef VarintRead = ({int value, int length});

/// Appends [value] as a base-128 varint, low group first.
///
/// A negative value is written as its 64-bit two's complement, in ten bytes, as protobuf does; reading it back gives
/// the same value, so every value read encodes back to the same bytes.
void writeVarint(BytesBuilder out, int value) {
  var rest = value;
  while (rest & ~0x7f != 0) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>>= 7;
  }
  out.addByte(rest);
}

/// The varint that starts at [offset] in [bytes], read no further than [end].
///
/// Returns `null` when the buffer ends inside the varint, so a stream reader can wait for more bytes. Throws
/// [FormatException] for a varint longer than ten bytes or one that does not fit 64 bits.
VarintRead? tryReadVarint(Uint8List bytes, int offset, [int? end]) {
  final limit = end ?? bytes.length;
  var value = 0;
  for (var i = 0; i < maxVarintLength; i++) {
    if (offset + i >= limit) return null;
    final byte = bytes[offset + i];
    if (i == maxVarintLength - 1 && byte > 1) throw const FormatException('Varint does not fit 64 bits');
    value |= (byte & 0x7f) << (7 * i);
    if (byte < 0x80) return (value: value, length: i + 1);
  }
  throw const FormatException('Varint longer than ten bytes');
}

/// The varint that starts at [offset] in [bytes], which must hold all of it.
VarintRead readVarint(Uint8List bytes, int offset, [int? end]) =>
    tryReadVarint(bytes, offset, end) ?? (throw const FormatException('Truncated varint'));
