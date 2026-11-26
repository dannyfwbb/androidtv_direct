// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:characters/characters.dart';

/// How a field takes a text edit.
enum FieldMode {
  /// Inserts the text at the cursor, as most fields do.
  insert,

  /// Replaces its whole text with the edit's, as some apps' fields do.
  replace,
}

/// A text field on the fake TV, behaving as the emulator's did: edits only with the current revisions (others are
/// dropped silently), a field report after every change, Del deletes the character before the cursor, Move End
/// moves the cursor without a report.
final class FakeField {
  /// A field with [text] and the cursor at [cursor] (default: the end).
  FakeField({
    this.text = '',
    int? cursor,
    this.mode = FieldMode.insert,
    this.maxLength,
    this.reject = '',
    this.loseDels = 0,
    this.reportCursorMoves = false,
  }) : cursor = cursor ?? text.length;

  /// The field's text.
  String text;

  /// The cursor, in UTF-16 code units.
  int cursor;

  /// How edits apply.
  final FieldMode mode;

  /// The longest text the field keeps, if limited.
  final int? maxLength;

  /// Characters the field drops from what is typed.
  final String reject;

  /// How many Del keys to lose, as a flooded TV does.
  int loseDels;

  /// Whether a cursor move is reported (with a new revision); the emulator did not report one.
  final bool reportCursorMoves;

  /// The keyboard revision edits must carry.
  final int keyboardRevision = 7;

  /// The field revision edits must carry; it grows with every change.
  int fieldRevision = 100;

  /// Edits that came with stale revisions.
  final List<TextEditMessage> dropped = [];

  /// The focus report for this field.
  FocusReport focusReport() => FocusReport(
    app: FocusedApp(
      keyboardRevision: keyboardRevision,
      inputType: 1,
      imeOptions: 3,
      packageName: 'com.example.tv',
      viewId: identityHashCode(this),
    ),
    textField: _state(),
  );

  /// The TV's answer to key [code], if any.
  RemoteEnvelope? onKey(int code) {
    if (code == TvKey.moveEnd.code) {
      cursor = text.length;
      return reportCursorMoves ? _changed() : null;
    }
    if (code != TvKey.del.code || cursor == 0) return null;
    if (loseDels > 0) {
      loseDels--;
      return null;
    }
    final before = text.substring(0, cursor).characters.skipLast(1).string;
    text = before + text.substring(cursor);
    cursor = before.length;
    return _changed();
  }

  /// The TV's answer to [edit], if it takes it.
  RemoteEnvelope? onEdit(TextEditMessage edit) {
    if (edit.keyboardRevision != keyboardRevision || edit.fieldRevision != fieldRevision) {
      dropped.add(edit);
      return null;
    }
    final typed = (edit.changes.single.replacement?.text ?? '').characters.where((c) => !reject.contains(c)).join();
    final next = mode == FieldMode.replace ? typed : text.substring(0, cursor) + typed + text.substring(cursor);
    final limited = maxLength == null ? next : next.characters.take(maxLength!).string;
    cursor = mode == FieldMode.replace ? limited.length : (cursor + typed.length).clamp(0, limited.length);
    text = limited;
    return _changed();
  }

  /// A change made on the TV itself (its own keyboard).
  FieldReport typeOnTv(String value) {
    text = value;
    cursor = value.length;
    return _changed();
  }

  FieldReport _changed() {
    fieldRevision++;
    return FieldReport(textField: _state());
  }

  TextFieldState _state() =>
      TextFieldState(fieldRevision: fieldRevision, text: text, selectionStart: cursor, selectionEnd: cursor);
}
