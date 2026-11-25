// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';

/// Brings the TV's volume to [level] with volume keys, one at a time, each after the TV reported the last.
///
/// The emulator ignored a level sent directly, so this is the way to set one. Mute is left as it is. [stepTimeout]
/// limits the wait for each report and [timeout] the whole change. A newer call stops an older one, which then throws
/// [TvCancelledException].
Future<void> setVolume(
  RemoteSession session,
  int level, {
  required Duration stepTimeout,
  required Duration timeout,
}) async {
  session
    ..require(TvFeature.key)
    ..require(TvFeature.volume);
  final start = session.state.volume;
  if (start == null) throw const TvNotSupportedException('The TV has not reported its volume', feature: 'volume');
  if (level < 0 || level > start.maximum) throw RangeError.range(level, 0, start.maximum, 'level');
  final call = ++session.volumeCalls;
  final deadline = session.clock.elapsed + timeout;
  while (session.state.volume!.level != level) {
    if (call != session.volumeCalls) throw const TvCancelledException('A newer setVolume took over');
    final left = deadline - session.clock.elapsed;
    if (left <= Duration.zero) throw TvTimeoutException('The volume did not reach $level within $timeout');
    await _step(session, toward: level, timeout: left < stepTimeout ? left : stepTimeout);
  }
}

/// Presses one volume key toward [toward] and waits for the next volume report, or the end of the session.
Future<void> _step(RemoteSession session, {required int toward, required Duration timeout}) async {
  final before = session.state.volume!;
  final reported = Completer<void>();
  final subscription = session.changes.listen((state) {
    if (state.volume != before && !reported.isCompleted) reported.complete();
  });
  final timer = session.clock.timer(timeout, () {
    if (!reported.isCompleted) {
      reported.completeError(TvTimeoutException('The TV did not report a volume change within $timeout'));
    }
  });
  try {
    sendKey(session, (toward > before.level ? TvKey.volumeUp : TvKey.volumeDown).code, TvKeyAction.press);
    await Future.any([reported.future, session.done]);
  } finally {
    timer.cancel();
    await subscription.cancel();
  }
  session.throwIfEnded();
}
