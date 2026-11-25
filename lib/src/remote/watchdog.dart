// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/clock.dart';

/// Calls its callback once when nothing happened for [limit]: [touch] marks activity.
///
/// One timer at a time, re-armed for the time that is left when it fires early, so touching costs nothing.
final class Watchdog {
  /// Starts watching now.
  Watchdog(this._clock, this.limit, this._onExpire) : _last = _clock.elapsed {
    _arm(limit);
  }

  final TvClock _clock;
  final void Function() _onExpire;
  Duration _last;
  Timer? _timer;

  /// How long silence may last.
  final Duration limit;

  /// Records activity now.
  void touch() => _last = _clock.elapsed;

  /// Stops watching.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm(Duration after) => _timer = _clock.timer(after, _check);

  void _check() {
    final idle = _clock.elapsed - _last;
    if (idle >= limit) {
      _timer = null;
      _onExpire();
    } else {
      _arm(limit - idle);
    }
  }
}
