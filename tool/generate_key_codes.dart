// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Regenerates `lib/src/protocol/key_codes.dart` from AOSP's `keycodes.h`.
///
/// ```
/// dart run tool/generate_key_codes.dart path/to/keycodes.h
/// ```
///
/// Get the header from AOSP's `frameworks/native` repository, `include/android/keycodes.h`.
library;

import 'dart:io';

import 'src/key_codes.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/generate_key_codes.dart path/to/keycodes.h');
    exitCode = 64;
    return;
  }
  final entries = parseKeyCodes(File(args.single).readAsStringSync());
  const target = 'lib/src/protocol/key_codes.dart';
  File(target).writeAsStringSync(generateKeyCodes(entries));
  final result = Process.runSync(Platform.resolvedExecutable, ['format', target]);
  if (result.exitCode != 0) throw StateError('dart format failed: ${result.stderr}');
  stdout.writeln('Wrote ${entries.length} key codes to $target');
}
