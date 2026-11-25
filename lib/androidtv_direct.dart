// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A remote control for Android TV and Google TV devices in pure Dart, over the TV's own remote protocol.
///
/// In development: this version holds the client's identity, what a TV's certificate says, the key table, the error
/// type, the clock and the tracing hook. Pairing and the remote session follow.
library;

export 'src/clock.dart' show TvClock, TvClockWaits;
export 'src/errors.dart';
export 'src/identity/client_identity.dart' show TvClientIdentity;
export 'src/identity/tv_identity.dart' show TvIdentity;
export 'src/protocol/key_codes.dart' show TvKey;
export 'src/trace.dart';
