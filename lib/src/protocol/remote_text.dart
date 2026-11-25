// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

part of 'remote_messages.dart';

/// TV → client: the app in front and, while one has the focus, the text field (field 20).
final class FocusReport extends RemoteEnvelope {
  /// Creates the message.
  FocusReport({this.app, this.textField, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'focusReport', unknownFields);

  /// Reads the message.
  factory FocusReport.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return FocusReport(
      app: fields.message(1, FocusedApp.decode),
      textField: fields.message(2, TextFieldState.decode),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 20;

  /// The app in front, and the focused field's editor settings.
  final FocusedApp? app;

  /// The focused field's content; `null` while no text field has the focus.
  final TextFieldState? textField;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalMessage(1, app)
    ..optionalMessage(2, textField);
}

/// The app in front and its focused field's editor settings, in [FocusReport.app].
final class FocusedApp extends ProtoMessage {
  /// Creates the description.
  FocusedApp({
    this.keyboardRevision,
    this.inputType,
    this.imeOptions,
    this.privateImeOptions,
    this.packageName,
    this.viewId,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(unknownFields);

  /// Reads the message.
  factory FocusedApp.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return FocusedApp(
      keyboardRevision: fields.integer(1),
      inputType: fields.integer(2),
      imeOptions: fields.integer(3),
      privateImeOptions: fields.string(4),
      packageName: fields.string(12),
      viewId: fields.integer(13),
      unknownFields: fields.unknown,
    );
  }

  /// The revision of the TV's keyboard a text edit must carry (field 1).
  final int? keyboardRevision;

  /// Android's `EditorInfo.inputType` of the field (field 2).
  final int? inputType;

  /// Android's `EditorInfo.imeOptions` of the field (field 3); the low byte is the action key.
  final int? imeOptions;

  /// Android's `EditorInfo.privateImeOptions` of the field (field 4).
  final String? privateImeOptions;

  /// The package of the app in front (field 12).
  final String? packageName;

  /// The focused view's resource id (field 13).
  final int? viewId;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, keyboardRevision)
    ..optionalVarint(2, inputType)
    ..optionalVarint(3, imeOptions)
    ..optionalString(4, privateImeOptions)
    ..optionalString(12, packageName)
    ..optionalVarint(13, viewId);
}

/// A text field's content and selection, in [FocusReport] and [FieldReport].
///
/// Positions count UTF-16 code units, as Dart's `String.length` does.
final class TextFieldState extends ProtoMessage {
  /// Creates the state.
  TextFieldState({
    this.fieldRevision,
    this.text,
    this.selectionStart,
    this.selectionEnd,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(unknownFields);

  /// Reads the message.
  factory TextFieldState.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return TextFieldState(
      fieldRevision: fields.integer(1),
      text: fields.string(2),
      selectionStart: fields.integer(3),
      selectionEnd: fields.integer(4),
      unknownFields: fields.unknown,
    );
  }

  /// The revision of the field's content a text edit must carry (field 1).
  final int? fieldRevision;

  /// The whole text of the field (field 2).
  final String? text;

  /// Where the selection starts (field 3).
  final int? selectionStart;

  /// Where the selection ends: the cursor (field 4).
  final int? selectionEnd;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, fieldRevision)
    ..optionalString(2, text)
    ..optionalVarint(3, selectionStart)
    ..optionalVarint(4, selectionEnd);
}

/// TV → client: the TV's on-screen keyboard opened or closed (field 21).
final class KeyboardReport extends RemoteEnvelope {
  /// Creates the message.
  KeyboardReport({this.keyboardRevision, this.fieldRevision, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'keyboardReport', unknownFields);

  /// Reads the message.
  factory KeyboardReport.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return KeyboardReport(
      keyboardRevision: fields.integer(1),
      fieldRevision: fields.integer(2),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 21;

  /// The keyboard's revision: not zero while it is open, zero once it closed (field 1).
  final int? keyboardRevision;

  /// The field's revision (field 2).
  final int? fieldRevision;

  /// Whether the keyboard is open.
  bool get keyboardOpen => (keyboardRevision ?? 0) != 0;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, keyboardRevision)
    ..optionalVarint(2, fieldRevision);
}

/// Values of [TextChange.kind].
abstract final class TextChangeKind {
  /// Insert the text at the cursor.
  static const int insert = 1;
}

/// Client → TV: change the focused field's text (field 21).
///
/// The TV applies it only when both revisions are the current ones, and drops it silently otherwise.
final class TextEditMessage extends RemoteEnvelope {
  /// Creates the message.
  TextEditMessage({
    this.keyboardRevision,
    this.fieldRevision,
    this.changes = const [],
    Iterable<ProtoField> unknownFields = const [],
  }) : super(fieldNumber, 'textEdit', unknownFields);

  /// Reads the message.
  factory TextEditMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return TextEditMessage(
      keyboardRevision: fields.integer(1),
      fieldRevision: fields.integer(2),
      changes: fields.repeated(3, TextChange.decode),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 21;

  /// The keyboard's revision from the last report (field 1).
  final int? keyboardRevision;

  /// The field's revision from the last report (field 2).
  final int? fieldRevision;

  /// The changes (field 3, repeated).
  final List<TextChange> changes;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, keyboardRevision)
    ..optionalVarint(2, fieldRevision)
    ..repeatedMessage(3, changes);
}

/// One change in a [TextEditMessage].
final class TextChange extends ProtoMessage {
  /// Creates the change.
  TextChange({this.kind, this.replacement, Iterable<ProtoField> unknownFields = const []}) : super(unknownFields);

  /// Reads the message.
  factory TextChange.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return TextChange(
      kind: fields.integer(1),
      replacement: fields.message(2, TextReplacement.decode),
      unknownFields: fields.unknown,
    );
  }

  /// What to do; see [TextChangeKind].
  final int? kind;

  /// The text and where it goes.
  final TextReplacement? replacement;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, kind)
    ..optionalMessage(2, replacement);
}

/// The text of a [TextChange] and the range it is meant for.
final class TextReplacement extends ProtoMessage {
  /// Creates the replacement.
  TextReplacement({this.start, this.end, this.text, Iterable<ProtoField> unknownFields = const []})
    : super(unknownFields);

  /// Reads the message.
  factory TextReplacement.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return TextReplacement(
      start: fields.integer(1),
      end: fields.integer(2),
      text: fields.string(3),
      unknownFields: fields.unknown,
    );
  }

  /// Start of the range, in UTF-16 code units (field 1).
  final int? start;

  /// End of the range, in UTF-16 code units (field 2).
  final int? end;

  /// The text (field 3).
  final String? text;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, start)
    ..optionalVarint(2, end)
    ..optionalString(3, text);
}

/// TV → client: the focused field changed, also by the TV's own remote (field 22).
final class FieldReport extends RemoteEnvelope {
  /// Creates the message.
  FieldReport({this.textField, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'fieldReport', unknownFields);

  /// Reads the message.
  factory FieldReport.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return FieldReport(textField: fields.message(2, TextFieldState.decode), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 22;

  /// The field's content after the change (field 2).
  final TextFieldState? textField;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalMessage(2, textField);
}
