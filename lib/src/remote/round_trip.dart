// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/clock.dart';

/// The time from a message to the TV's answer, estimated as TCP estimates its own (RFC 6298, section 2): a smoothed
/// time and its variation, from every measured answer.
///
/// Waits for an answer that may never come take [waitFor]: at least their own floor, longer on a slow network. They
/// do not back off after running out, as TCP does: silence is a normal answer here (a field that drops an edit sends
/// no report), and only an answer that came late, measured from what it answered, makes waits longer.
final class RoundTrip {
  /// The longest [timeout], and the longest a measured answer counts as (RFC 6298 2.5 allows a ceiling). One answer
  /// measured across a pause (an app in the background, a debugger) would otherwise make every wait minutes long, and
  /// a network whose answers take longer is of no use for a remote anyway.
  static const Duration ceiling = Duration(seconds: 10);

  Duration? _smoothed;
  Duration _variation = Duration.zero;

  /// The smoothed time, or `null` before any measurement.
  Duration? get smoothed => _smoothed;

  /// How long an answer may take before it counts as not coming: the smoothed time plus four times its variation, at
  /// most [ceiling]; zero before any measurement.
  Duration get timeout => _smoothed == null ? Duration.zero : shorter(_smoothed! + _variation * 4, ceiling);

  /// How long to wait for an answer: [timeout], and at least [floor].
  Duration waitFor(Duration floor) => longer(timeout, floor);

  /// Takes the time one answer took; at most [ceiling] of it counts.
  void add(Duration answer) {
    final sample = shorter(answer, ceiling);
    final smoothed = _smoothed;
    if (smoothed == null) {
      _smoothed = sample;
      _variation = sample ~/ 2;
      return;
    }
    // α = 1/8, β = 1/4 (RFC 6298 2.3).
    _variation = _variation * 0.75 + (smoothed - sample).abs() * 0.25;
    _smoothed = smoothed * 0.875 + sample * 0.125;
  }
}
