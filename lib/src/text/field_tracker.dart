// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/text/field_kind.dart';

/// What a report changed about the focused field.
enum FieldEvent {
  /// A text field got the focus (also when one field follows another).
  focused,

  /// No text field has the focus any more.
  unfocused,

  /// The focused field's text or selection changed.
  content,

  /// The TV's on-screen keyboard opened or closed.
  keyboard,
}

/// The focused text field as the TV's reports describe it, kept from the start of the session.
///
/// Text edits must carry two revisions. The focus report's are the ones the TV checks; a keyboard report's fill in
/// only what the focus report left out, and a field report's field revision is always the newest.
final class FieldTracker {
  /// Whether a text field has the focus.
  bool focused = false;

  /// The field's text.
  String text = '';

  /// Where the selection starts, in UTF-16 code units.
  int selectionStart = 0;

  /// Where the selection ends (the cursor), in UTF-16 code units.
  int selectionEnd = 0;

  /// What the field takes.
  TvTextFieldKind kind = const TvTextFieldKind();

  /// Whether the TV's own keyboard is open.
  bool keyboardOpen = false;

  /// The keyboard revision a text edit must carry.
  int keyboardRevision = 0;

  /// The field revision a text edit must carry.
  int fieldRevision = 0;

  bool _keyboardFromFocus = false;
  bool _fieldFromFocus = false;
  ({String? package, int? id})? _view;

  /// Applies [message]; returns what changed, or `null`.
  FieldEvent? apply(RemoteEnvelope message) => switch (message) {
    FocusReport() => _focus(message),
    KeyboardReport() => _keyboard(message),
    FieldReport(:final textField?) => _content(textField),
    _ => null,
  };

  FieldEvent? _focus(FocusReport report) {
    final field = report.textField;
    if (field == null) {
      if (!focused) return null;
      focused = false;
      return FieldEvent.unfocused;
    }
    final app = report.app;
    final view = (package: app?.packageName, id: app?.viewId);
    final sameView = focused && view.id != null && view == _view;
    focused = true;
    _view = view;
    _takeRevisions(app, field);
    kind = TvTextFieldKind.fromEditorInfo(inputType: app?.inputType, imeOptions: app?.imeOptions);
    _setContent(field);
    // The same view reported again (an app restarting input) is a content update, not a new focus.
    return sameView ? FieldEvent.content : FieldEvent.focused;
  }

  /// The focus report's revisions are the ones the TV checks; a keyboard report's stay only where it has none.
  void _takeRevisions(FocusedApp? app, TextFieldState field) {
    _keyboardFromFocus = app?.keyboardRevision.isSet ?? false;
    _fieldFromFocus = field.fieldRevision.isSet;
    if (_keyboardFromFocus) keyboardRevision = app!.keyboardRevision!;
    if (_fieldFromFocus) fieldRevision = field.fieldRevision!;
  }

  FieldEvent? _keyboard(KeyboardReport report) {
    keyboardOpen = report.keyboardOpen;
    if (!_keyboardFromFocus) keyboardRevision = report.keyboardRevision ?? keyboardRevision;
    if (!_fieldFromFocus) fieldRevision = report.fieldRevision ?? fieldRevision;
    return focused ? FieldEvent.keyboard : null;
  }

  FieldEvent? _content(TextFieldState field) {
    fieldRevision = field.fieldRevision ?? fieldRevision;
    _fieldFromFocus = true;
    _setContent(field);
    return focused ? FieldEvent.content : null;
  }

  /// Takes [field]'s text and selection; a position outside the text (a TV may write -1 for none) is clamped to it.
  void _setContent(TextFieldState field) {
    text = field.text ?? '';
    selectionStart = (field.selectionStart ?? 0).clamp(0, text.length);
    selectionEnd = (field.selectionEnd ?? 0).clamp(0, text.length);
  }
}
