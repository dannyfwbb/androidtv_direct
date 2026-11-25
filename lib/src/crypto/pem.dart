// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/crypto/pem.dart.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// One block of a PEM file.
final class PemBlock {
  /// Creates a block.
  const PemBlock(this.label, this.der);

  /// The label between `BEGIN` and the dashes, such as `PRIVATE KEY`.
  final String label;

  /// The decoded content.
  final Uint8List der;
}

/// Reads and writes PEM (RFC 7468).
abstract final class Pem {
  static final RegExp _block = RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----');

  /// Every block in [text], in order. Text outside blocks is ignored.
  static List<PemBlock> decode(String text) => [
    for (final match in _block.allMatches(text))
      PemBlock(match.group(1)!, base64.decode(match.group(2)!.replaceAll(RegExp(r'\s'), ''))),
  ];

  /// [der] as a PEM block with [label], lines of 64 characters, ending with a newline.
  static String encode(String label, List<int> der) {
    final body = base64.encode(der);
    final lines = [for (var i = 0; i < body.length; i += 64) body.substring(i, min(i + 64, body.length))];
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }
}
