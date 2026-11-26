// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/text/field_kind.dart';
import 'package:androidtv_direct/src/text/field_tracker.dart';
import 'package:androidtv_direct/src/text/text_sync.dart';

/// A selection in a text field, in UTF-16 code units; the cursor is `end` (`start` equals it when nothing is
/// selected).
typedef TvSelection = ({int start, int end});

/// The text field that has the focus on the TV, while it has it.
///
/// [text] is what the TV last reported. [setText] brings the TV's field to a text; [changes] tells about texts the
/// field took other than the one asked for. A new focus gives a new [TvTextField]; this one then stops ([isFocused]
/// false, its values frozen), and a [setText] still waiting fails with [TvCancelledException].
final class TvTextField {
  TvTextField._(this._session, this.giveUpAfter) : kind = _session.field.kind {
    _sync.reset(_session.field.text);
    _copyTracker();
  }

  static const TvCancelledException _lostFocus = TvCancelledException('The text field lost the focus');

  /// How long Move End waits for the TV's report of the cursor before the edit goes out anyway.
  static const Duration _moveEndWait = Duration(milliseconds: 300);

  final RemoteSession _session;
  final TextSync _sync = TextSync();
  final StreamController<String> _changes = StreamController.broadcast();
  final StreamController<bool> _keyboardChanges = StreamController.broadcast();
  final List<Completer<String>> _waiting = [];
  Timer? _timer;
  bool _focused = true;
  TvSelection _selection = (start: 0, end: 0);
  bool _keyboardOpen = false;
  String? _afterMove;

  /// How long [setText] waits for an awaited report. Then a deletion is tried again from the TV's text (TVs may lose
  /// keys), and an insertion gives way to the TV's text (the field filtered or limited it).
  final Duration giveUpAfter;

  /// What the field takes: password, several lines, its action key.
  final TvTextFieldKind kind;

  /// Whether this field still has the focus.
  bool get isFocused => _focused && !_session.isClosed;

  /// The field's text, as the TV last reported it.
  String get text => _sync.tv;

  /// The selection, in UTF-16 code units (the cursor is `end`), as the TV last reported it.
  TvSelection get selection => _selection;

  /// Whether the TV's own on-screen keyboard is open.
  bool get keyboardOpen => _keyboardOpen;

  /// [keyboardOpen] each time it changes. Closes when the field stops.
  Stream<bool> get keyboardChanges => _keyboardChanges.stream;

  /// Texts the field took other than through [setText] reaching its text: edits made on the TV (its remote or its
  /// keyboard; one per typed character), the reports after [insert], and the TV's text when [setText] gave way to it.
  Stream<String> get changes => _changes.stream;

  /// Brings the TV's field to [value], and completes with the field's text once the TV reported it.
  ///
  /// Moves the cursor to the end if the TV reports it elsewhere (in a multi-line field, to the end of its line),
  /// deletes what differs from [value] at the end with Del keys and inserts the rest, one step at a time, each after
  /// the TV's report of the last. Calls made meanwhile replace the wanted text and complete together. When an
  /// insertion's report does not come within [giveUpAfter] (the field filters or limits its input), completes with the
  /// TV's text as it is, which may differ from [value].
  ///
  /// Every failure comes through the returned future: [TvCancelledException] when the field lost the focus,
  /// [TvNotSupportedException] without [TvFeature.ime] and [TvFeature.key], and what ended the session.
  Future<String> setText(String value) async {
    _checkUsable();
    final done = Completer<String>();
    _waiting.add(done);
    if (_afterMove != null || _cursorAway) {
      _moveCursorToEnd(value);
    } else {
      _apply((adopt: null, send: _sync.want(value)));
    }
    return done.future;
  }

  /// Inserts [value] at the cursor with one text edit, without waiting for the TV. The low-level form of [setText];
  /// the TV's report of the result arrives on [changes]. Throws as [setText] does, synchronously.
  void insert(String value) {
    _checkUsable();
    final field = _session.field;
    final replacement = TextReplacement(start: value.length, end: value.length, text: value);
    _session.send(
      TextEditMessage(
        keyboardRevision: field.keyboardRevision,
        fieldRevision: field.fieldRevision,
        changes: [TextChange(kind: TextChangeKind.insert, replacement: replacement)],
      ),
    );
  }

  /// Presses Enter: the field's action key ([TvTextFieldKind.action]). Throws as [setText] does, synchronously.
  void submit() {
    _checkUsable();
    sendKey(_session, TvKey.enter.code, TvKeyAction.press);
  }

  void _checkUsable() {
    _session
      ..require(TvFeature.ime)
      ..require(TvFeature.key);
    if (!_focused) throw _lostFocus;
  }

  bool get _cursorAway => _selection.start != _selection.end || _selection.end != text.length;

  void _moveCursorToEnd(String value) {
    final first = _afterMove == null;
    _afterMove = value;
    if (!first) return;
    sendKey(_session, TvKey.moveEnd.code, TvKeyAction.press);
    _restartTimer(_moveEndWait, _afterCursorMoved);
  }

  void _afterCursorMoved() {
    final value = _afterMove;
    if (value == null) return;
    _afterMove = null;
    _apply((adopt: null, send: _sync.want(value)));
  }

  void _onContent() {
    _copyTracker();
    if (_afterMove != null) {
      _sync.report(_session.field.text);
      return _afterCursorMoved();
    }
    _apply(_sync.report(_session.field.text));
  }

  void _onKeyboard() {
    final open = _session.field.keyboardOpen;
    if (open == _keyboardOpen) return;
    _keyboardOpen = open;
    _keyboardChanges.add(open);
  }

  /// Takes what the sync decided: a text to adopt, a step to send; completes the waiters once settled.
  void _apply(SyncOutcome result) {
    if (result.adopt != null) _changes.add(result.adopt!);
    final step = result.send;
    if (step != null) {
      _sendStep(step);
      _restartTimer(giveUpAfter, () => _apply(_sync.stalled()));
    }
    if (_sync.waiting) return;
    _timer?.cancel();
    for (final waiter in _waiting) {
      waiter.complete(_sync.tv);
    }
    _waiting.clear();
  }

  void _sendStep(TextStep step) {
    if (step.deletes == 0) return insert(step.insert);
    for (var i = 0; i < step.deletes; i++) {
      sendKey(_session, TvKey.del.code, TvKeyAction.press);
    }
  }

  void _restartTimer(Duration after, void Function() callback) {
    _timer?.cancel();
    _timer = _session.clock.timer(after, callback);
  }

  void _copyTracker() {
    final field = _session.field;
    _selection = (start: field.selectionStart, end: field.selectionEnd);
    _keyboardOpen = field.keyboardOpen;
  }

  /// The field lost the focus, or the session ended with [reason].
  void _stop([Object reason = _lostFocus]) {
    if (!_focused) return;
    _focused = false;
    _timer?.cancel();
    for (final waiter in _waiting) {
      waiter.completeError(reason);
    }
    _waiting.clear();
    unawaited(_changes.close());
    unawaited(_keyboardChanges.close());
  }
}

/// Follows the focus: makes a [TvTextField] for every field that gets it and stops the previous one.
final class TextInput {
  /// Follows [_session]'s field reports; every field gives up after [_giveUpAfter].
  TextInput(this._session, this._giveUpAfter) {
    if (_session.field.focused) _current = TvTextField._(_session, _giveUpAfter);
    _events = _session.fieldEvents.listen(_onEvent);
    unawaited(_session.done.then(_end));
  }

  final RemoteSession _session;
  final Duration _giveUpAfter;
  final StreamController<TvTextField?> _focus = StreamController.broadcast();
  late final StreamSubscription<FieldEvent> _events;
  TvTextField? _current;

  /// The focused field, or `null`.
  TvTextField? get current => _current;

  /// The focused field each time the focus changes; `null` when no field has it.
  Stream<TvTextField?> get focus => _focus.stream;

  void _end(TvRemoteException? reason) {
    _current?._stop(reason ?? const TvCancelledException('The session was closed'));
    unawaited(_focus.close());
    unawaited(_events.cancel());
  }

  void _onEvent(FieldEvent event) {
    switch (event) {
      case FieldEvent.focused:
        _current?._stop();
        _current = TvTextField._(_session, _giveUpAfter);
        _focus.add(_current);
      case FieldEvent.unfocused:
        _current?._stop();
        _current = null;
        _focus.add(null);
      case FieldEvent.content:
        _current?._onContent();
      case FieldEvent.keyboard:
        _current?._onKeyboard();
    }
  }
}
