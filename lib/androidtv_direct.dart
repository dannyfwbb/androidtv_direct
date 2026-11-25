// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A remote control for Android TV and Google TV devices in pure Dart, over the TV's own remote protocol.
///
/// In development: this version holds the key table, the error type, the clock and the tracing hook. Pairing and the
/// remote session follow.
library;

export 'src/clock.dart' show TvClock, TvClockWaits;
export 'src/errors.dart';
export 'src/protocol/key_codes.dart' show TvKey;
export 'src/trace.dart';
