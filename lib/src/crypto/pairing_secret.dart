// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The pairing secret, after AOSP's `PoloChallengeResponse` (`external/google-tv-pairing-protocol`, Copyright 2009
/// Google Inc., Apache-2.0), with the split of the code that version 2 of the protocol uses.
library;

import 'dart:typed_data';

import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:crypto/crypto.dart' as hashes;

final RegExp _code = RegExp(r'^[0-9a-fA-F]{6}$');

/// The three bytes of a code the TV shows, or `null` if [code] is not six hexadecimal characters (surrounding
/// whitespace and either case are fine).
Uint8List? parsePairingCode(String code) {
  final trimmed = code.trim();
  if (!_code.hasMatch(trimmed)) return null;
  return Uint8List.fromList([for (var i = 0; i < 6; i += 2) int.parse(trimmed.substring(i, i + 2), radix: 16)]);
}

/// The 32-byte secret for [code] between the [client]'s and the [tv]'s keys, or `null` if the code's first byte does
/// not check out against the keys: the code was mistyped (or someone relays the connection).
///
/// `SHA-256(client modulus ‖ client exponent ‖ TV modulus ‖ TV exponent ‖ code[1] ‖ code[2])`, each number as its
/// unsigned big-endian bytes without leading zeros; `code[0]` must equal the hash's first byte.
Uint8List? pairingSecret({required RsaPublicKey client, required RsaPublicKey tv, required Uint8List code}) {
  if (code.length != 3) throw ArgumentError.value(code, 'code', 'must be three bytes');
  final input = BytesBuilder(copy: false)
    ..add(Der.unsignedBytes(client.modulus))
    ..add(Der.unsignedBytes(client.exponent))
    ..add(Der.unsignedBytes(tv.modulus))
    ..add(Der.unsignedBytes(tv.exponent))
    ..add(code.sublist(1));
  final secret = Uint8List.fromList(hashes.sha256.convert(input.takeBytes()).bytes);
  return secret[0] == code[0] ? secret : null;
}
