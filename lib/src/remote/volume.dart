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
  /// it is. [stepTimeout] limits the wait for each report and [timeout] the whole change.
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
      await _step(current, toward: level, timeout: shorter(left, stepTimeout));
    }
  }

  /// Presses one volume key toward [toward] and waits for the report of the level it moved to. The report cannot
  /// arrive before the wait starts: it comes from a later read of the socket.
  ///
  /// Only a new level counts: volume up while muted is reported twice (the unmute at the same level, then the new
  /// level), and taking the first for the step would leave every later report one press behind, until a press at
  /// either end of the range is never answered.
  Future<void> _step(TvVolume before, {required int toward, required Duration timeout}) {
    final key = toward > before.level ? TvKey.volumeUp : TvKey.volumeDown;
    sendKey(_session, key.code, TvKeyAction.press);
    return _session.next<TvState>(
      _session.changes,
      (state) => state.volume?.level != before.level,
      timeout: timeout,
      onTimeout: () => TvTimeoutException('The TV did not report a volume change within $timeout'),
    );
  }
}
