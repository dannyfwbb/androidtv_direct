// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'hex.dart';

/// Calls [decode] with [count] inputs, half random bytes and half [seeds] with a few bytes changed, and fails on any
/// exception other than [FormatException].
///
/// With [encode], also checks that encoding is stable: whatever decodes, encodes to bytes that decode and encode to
/// the same bytes again.
void fuzz<T>(
  T Function(Uint8List bytes) decode, {
  required List<Uint8List> seeds,
  Uint8List Function(T message)? encode,
  int count = 100000,
  int seed = 0,
}) {
  final random = Random(seed);
  for (var i = 0; i < count; i++) {
    final input = i.isEven || seeds.isEmpty
        ? _randomBytes(random)
        : _mutate(random, seeds[random.nextInt(seeds.length)]);
    final T message;
    try {
      message = decode(input);
    } on FormatException {
      continue;
    }
    if (encode != null) _checkStable(input, encode(message), (bytes) => encode(decode(bytes)));
  }
}

void _checkStable(Uint8List input, Uint8List once, Uint8List Function(Uint8List bytes) again) {
  final twice = again(once);
  if (hex(once) != hex(twice)) fail('Unstable encoding of ${hex(input)}: ${hex(once)}, then ${hex(twice)}');
}

Uint8List _randomBytes(Random random) =>
    Uint8List.fromList(List.generate(random.nextInt(64), (_) => random.nextInt(256)));

Uint8List _mutate(Random random, Uint8List seed) {
  final bytes = Uint8List.fromList(seed);
  if (bytes.isEmpty) return bytes;
  for (var n = 1 + random.nextInt(3); n > 0; n--) {
    bytes[random.nextInt(bytes.length)] = random.nextInt(256);
  }
  return random.nextBool() ? bytes : Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length));
}
