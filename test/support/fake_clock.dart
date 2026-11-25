// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/clock.dart';

/// An [TvClock] that moves only when told to.
///
/// Timers fire synchronously inside [advance], in deadline order, each with [elapsed] set to its own deadline. Sockets
/// and microtasks keep running in real time, which is what deadline and watchdog tests need.
final class FakeClock implements TvClock {
  Duration _elapsed = Duration.zero;
  final List<_FakeTimer> _timers = [];
  int _sequence = 0;

  @override
  Duration get elapsed => _elapsed;

  /// Timers that have not fired or been cancelled.
  int get pendingTimers => _timers.length;

  @override
  Timer timer(Duration duration, void Function() callback) {
    final timer = _FakeTimer(this, _elapsed + (duration.isNegative ? Duration.zero : duration), _sequence++, callback);
    _timers.add(timer);
    return timer;
  }

  /// Moves time forward by [duration], firing every timer that comes due.
  void advance(Duration duration) {
    if (duration.isNegative) throw ArgumentError.value(duration, 'duration', 'must not be negative');
    final target = _elapsed + duration;
    while (true) {
      final due = _timers.where((t) => t.deadline <= target).toList()..sort();
      if (due.isEmpty) break;
      final next = due.first;
      _timers.remove(next);
      _elapsed = next.deadline;
      next._fire();
    }
    _elapsed = target;
  }
}

final class _FakeTimer implements Timer, Comparable<_FakeTimer> {
  _FakeTimer(this._clock, this.deadline, this._sequence, this._callback);

  final FakeClock _clock;
  final Duration deadline;
  final int _sequence;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  void _fire() {
    _active = false;
    _callback();
  }

  @override
  int compareTo(_FakeTimer other) {
    final byDeadline = deadline.compareTo(other.deadline);
    return byDeadline != 0 ? byDeadline : _sequence.compareTo(other._sequence);
  }
}
