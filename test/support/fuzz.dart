// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:test/test.dart';

/// Calls [decode] with [count] inputs, half random bytes and half [seeds] with a few bytes changed, and fails on any
/// exception other than [FormatException].
///
/// `FUZZ_SCALE` in the environment multiplies [count] and `FUZZ_SEED` shifts [seed], for long runs.
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
  final environment = Platform.environment;
  final random = Random(seed + int.parse(environment['FUZZ_SEED'] ?? '0'));
  final total = count * int.parse(environment['FUZZ_SCALE'] ?? '1');
  for (var i = 0; i < total; i++) {
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
  if (hexEncode(once) != hexEncode(twice)) {
    fail('Unstable encoding of ${hexEncode(input)}: ${hexEncode(once)}, then ${hexEncode(twice)}');
  }
}

Uint8List _randomBytes(Random random) =>
    Uint8List.fromList(List.generate(random.nextInt(64), (_) => random.nextInt(256)));

/// A copy of [seed] with one to three changes: bytes replaced, inserted, removed or repeated, a varint-like length set
/// to an edge value, or the end cut off.
Uint8List _mutate(Random random, Uint8List seed) {
  var bytes = List.of(seed);
  for (var n = 1 + random.nextInt(3); n > 0; n--) {
    bytes = _change(random, bytes);
  }
  return Uint8List.fromList(bytes);
}

List<int> _change(Random random, List<int> bytes) {
  final at = bytes.isEmpty ? 0 : random.nextInt(bytes.length);
  switch (random.nextInt(6)) {
    case 0 when bytes.isNotEmpty:
      bytes[at] = random.nextInt(256);
    case 1:
      bytes.insertAll(at, List.generate(1 + random.nextInt(4), (_) => random.nextInt(256)));
    case 2 when bytes.isNotEmpty:
      bytes.removeRange(at, min(bytes.length, at + 1 + random.nextInt(4)));
    case 3 when bytes.isNotEmpty:
      final end = min(bytes.length, at + 1 + random.nextInt(8));
      bytes.insertAll(end, bytes.sublist(at, end));
    case 4 when bytes.isNotEmpty:
      bytes[at] = const [0x00, 0x01, 0x7f, 0x80, 0xff][random.nextInt(5)];
    case _:
      return bytes.sublist(0, bytes.isEmpty ? 0 : random.nextInt(bytes.length));
  }
  return bytes;
}
