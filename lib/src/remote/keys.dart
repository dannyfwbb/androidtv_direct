// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/session.dart';

/// What happens to a key.
enum TvKeyAction {
  /// Key down: the TV repeats the key, as for a held button, until [up].
  down(KeyAction.press),

  /// Key up.
  up(KeyAction.release),

  /// Down and up: one press.
  press(KeyAction.short);

  const TvKeyAction(this.value);

  /// The value on the wire.
  final KeyAction value;
}

/// The lowest key code the package sends (0 is "unknown key").
const int minKeyCode = 1;

/// The highest key code the package sends. AOSP's codes end at 337; the margin leaves room for codes newer than the
/// table.
const int maxKeyCode = 999;

/// Sends key [code] with [action] in [session], after checking the code and the `key` feature.
///
/// TVs seen so far ignore codes they do not know, so the check only catches values that cannot be key codes.
void sendKey(RemoteSession session, int code, TvKeyAction action) {
  RangeError.checkValueInInterval(code, minKeyCode, maxKeyCode, 'code');
  session
    ..require(TvFeature.key)
    ..send(KeyMessage(code: code, action: action.value));
}

/// A key held down with `TvRemote.hold`: the TV repeats it until [release].
final class TvKeyHold {
  TvKeyHold._(this._holds, this.code);

  final KeyHolds _holds;
  bool _released = false;

  /// The key code held.
  final int code;

  /// Whether the key was released.
  bool get isReleased => _released;

  /// Releases the key. Does nothing the second time, or once the session has ended (the TV stops repeating then).
  void release() {
    if (_released) return;
    _released = true;
    _holds._release(this);
  }
}

/// The keys a session holds down, so that closing it can release them.
final class KeyHolds {
  /// Holds for [_session].
  KeyHolds(this._session);

  final RemoteSession _session;
  final Set<TvKeyHold> _held = {};

  /// Sends key [code] down and tracks it until released.
  TvKeyHold start(int code) {
    sendKey(_session, code, TvKeyAction.down);
    final hold = TvKeyHold._(this, code);
    _held.add(hold);
    return hold;
  }

  /// Releases every held key; a failure to send does not stop the others.
  void releaseAll() {
    for (final hold in [..._held]) {
      try {
        hold.release();
      } on Exception {
        // The session is ending anyway.
      }
    }
  }

  void _release(TvKeyHold hold) {
    _held.remove(hold);
    if (!_session.isClosed) sendKey(_session, hold.code, TvKeyAction.up);
  }
}
