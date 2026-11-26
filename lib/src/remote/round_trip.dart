// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The time from a message to the TV's answer, estimated as TCP estimates its own (RFC 6298, section 2): a smoothed
/// time and its variation, from every measured answer.
///
/// Waits for an answer that may never come take [waitFor]: at least their own floor, longer on a slow network. They
/// do not back off after running out, as TCP does: silence is a normal answer here (a field that drops an edit sends
/// no report), and only an answer that came late, measured from what it answered, makes waits longer.
final class RoundTrip {
  Duration? _smoothed;
  Duration _variation = Duration.zero;

  /// The smoothed time, or `null` before any measurement.
  Duration? get smoothed => _smoothed;

  /// How long an answer may take before it counts as not coming: the smoothed time plus four times its variation;
  /// zero before any measurement.
  Duration get timeout => _smoothed == null ? Duration.zero : _smoothed! + _variation * 4;

  /// How long to wait for an answer, at least [floor].
  Duration waitFor(Duration floor) => timeout > floor ? timeout : floor;

  /// Takes the time one answer took.
  void add(Duration sample) {
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
