// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/remote/state.dart';

/// Sets the TV's volume with volume keys, one at a time, each after the TV reported the last. A newer call stops an
/// older one, which then throws [TvCancelledException].
final class VolumeControl {
  /// Controls the volume of [_session].
  VolumeControl(this._session);

  final RemoteSession _session;
  int _calls = 0;

  /// Brings the volume to [level]. The emulator ignored a level sent directly, so keys are the way. Mute is left as
  /// it is. [stepTimeout] is the least wait for each report (longer when the TV's answers take longer, see
  /// [RemoteSession.roundTrip]), within what is left of [timeout], which limits the whole change.
  Future<void> set(int level, {required Duration stepTimeout, required Duration timeout}) async {
    _session
      ..require(TvFeature.key)
      ..require(TvFeature.volume);
    final start = _session.state.volume;
    if (start == null) {
      throw const TvNotSupportedException('The TV has not reported its volume', feature: TvFeature.volume);
    }
    RangeError.checkValueInInterval(level, 0, start.maximum, 'level');
    final call = ++_calls;
    final deadline = _session.clock.elapsed + timeout;
    for (var current = start; current.level != level; current = _session.state.volume!) {
      if (call != _calls) throw const TvCancelledException('A newer setVolume took over');
      final left = deadline - _session.clock.elapsed;
      if (left <= Duration.zero) throw TvTimeoutException('The volume did not reach $level within $timeout');
      await _step(current, toward: level, timeout: shorter(left, _session.roundTrip.waitFor(stepTimeout)));
    }
  }

  /// Presses one volume key toward [toward] and waits for a new level. A press with no answer in time (a TV that lost
  /// it, or one whose press while muted only unmutes) is no failure: the loop presses again from the level the TV
  /// reports, and a press that was only late is evened out by the next step; [set]'s timeout bounds it all.
  ///
  /// Only a new level counts: volume up while muted is reported twice (the unmute at the same level, then the new
  /// level), and taking the first for the step would leave every later report one press behind.
  Future<void> _step(TvVolume before, {required int toward, required Duration timeout}) async {
    final key = toward > before.level ? TvKey.volumeUp : TvKey.volumeDown;
    sendKey(_session, key.code, TvKeyAction.press);
    final sentAt = _session.clock.elapsed;
    try {
      await _session.until(
        () => _session.state.volume?.level != before.level,
        timeout: timeout,
        onTimeout: () => TvTimeoutException('The TV did not report a volume change within $timeout'),
      );
      _session.roundTrip.add(_session.clock.elapsed - sentAt);
    } on TvTimeoutException {
      // Pressed again by the loop.
    }
  }
}
