// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/bytes.dart.

/// Byte helpers shared across the library.
library;

import 'dart:math';
import 'dart:typed_data';

final Random _random = Random.secure();

/// [length] bytes from the system's secure random source.
Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

/// [bytes] as lowercase hex, two digits each.
String hexEncode(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
