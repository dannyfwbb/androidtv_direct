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
  TvTextField._(this._session, this.giveUpAfter, this._input)
    : kind = _session.field.kind,
      _sync = TextSync(byRange: _input._takesRanges) {
    _copyTracker();
    _sync.reset(_session.field.text, cursor: _selection.end);
  }

  static const TvCancelledException _lostFocus = TvCancelledException('The text field lost the focus');

  /// How long Move End waits for the TV's report of the cursor before keys go out anyway.
  static const Duration _moveEndWait = Duration(milliseconds: 300);

  final RemoteSession _session;
  final TextInput _input;
  final TextSync _sync;
  final StreamController<String> _changes = StreamController.broadcast();
  final StreamController<bool> _keyboardChanges = StreamController.broadcast();
  final List<Completer<String>> _waiting = [];
  Timer? _timer;
  bool _focused = true;
  TvSelection _selection = (start: 0, end: 0);
  bool _keyboardOpen = false;
  String? _afterMove;

  /// How long [setText] waits for an awaited report. Then an edit with a range goes again as keys (the TV does not
  /// take ranges), a deletion by Del keys is tried again from the TV's text (TVs may lose keys), and an insertion
  /// gives way to the TV's text (the field filtered or limited it).
  final Duration giveUpAfter;

  /// What the field takes: password, several lines, its action key.
  final TvTextFieldKind kind;

  /// Whether this field still has the focus.
  bool get isFocused => _focused && !_session.isClosed;

  /// The field's text, as the TV last reported it.
  String get text => _sync.tv;

  /// The selection, in UTF-16 code units (the cursor is `end`), as the TV last reported it; always within [text].
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
  /// Replaces what differs from [value] after their common beginning with edits that name the range they replace, so
  /// the cursor's place does not matter, one step at a time, each after the TV's report of the last. A TV that does
  /// not take such edits gets Del keys and inserts at the cursor instead, after moving the cursor to the end if the TV
  /// reports it elsewhere. Calls made meanwhile replace the wanted text and complete together. When the field takes
  /// something else (it filters or limits its input), completes with the TV's text as it is, which may differ from
  /// [value].
  ///
  /// Every failure comes through the returned future: [TvCancelledException] when the field lost the focus,
  /// [TvNotSupportedException] without [TvFeature.ime] and [TvFeature.key], and what ended the session.
  Future<String> setText(String value) async {
    _checkUsable();
    final done = Completer<String>();
    _waiting.add(done);
    if (_afterMove != null || (!_sync.byRange && _cursorAway)) {
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
    _sendEdit(_selection.end, _selection.end, value);
  }

  /// Sends one text edit: [text] in place of the range from [start] to [end] (an empty range inserts at the cursor).
  void _sendEdit(int start, int end, String text) {
    final field = _session.field;
    _session.send(
      TextEditMessage(
        keyboardRevision: field.keyboardRevision,
        fieldRevision: field.fieldRevision,
        changes: [
          TextChange(
            kind: TextChangeKind.insert,
            replacement: TextReplacement(start: start, end: end, text: text),
          ),
        ],
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
    final report = _sync.report(_session.field.text, cursor: _selection.end);
    if (_afterMove != null) return _afterCursorMoved();
    _apply(report);
  }

  void _onKeyboard() {
    final open = _session.field.keyboardOpen;
    if (open == _keyboardOpen) return;
    _keyboardOpen = open;
    _keyboardChanges.add(open);
  }

  /// Takes what the sync decided: a text to adopt, a step to send; completes the waiters once settled.
  void _apply(SyncOutcome result) {
    // Whether the TV takes ranges is the TV's, not the field's: later fields start with what this one found.
    if (!_sync.byRange) _input._takesRanges = false;
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
    switch (step) {
      case TextReplace(:final start, :final end, :final text):
        _sendEdit(start, end, text);
      case TextKeys(deletes: 0, :final insert):
        _sendEdit(_selection.end, _selection.end, insert);
      case TextKeys(:final deletes):
        for (var i = 0; i < deletes; i++) {
          sendKey(_session, TvKey.del.code, TvKeyAction.press);
        }
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
    if (_session.field.focused) _current = TvTextField._(_session, _giveUpAfter, this);
    _events = _session.fieldEvents.listen(_onEvent);
    unawaited(_session.done.then(_end));
  }

  final RemoteSession _session;
  final Duration _giveUpAfter;
  final StreamController<TvTextField?> _focus = StreamController.broadcast();
  late final StreamSubscription<FieldEvent> _events;
  TvTextField? _current;

  /// Whether the TV takes text edits with a range; `false` once a field found it does not.
  bool _takesRanges = true;

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
        _current = TvTextField._(_session, _giveUpAfter, this);
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
