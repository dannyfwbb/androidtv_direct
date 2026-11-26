// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// The action key a text field asks for: what "Enter" means in it (Android's `EditorInfo.IME_ACTION_…`).
enum TvFieldAction {
  /// No particular action, or one this package does not name.
  none,

  /// Go to the entered address.
  go,

  /// Search for the entered text.
  search,

  /// Send the entered text.
  send,

  /// Move to the next field.
  next,

  /// Done: close the keyboard.
  done,

  /// Move to the previous field.
  previous,
}

/// What kind of text a field takes, from Android's `EditorInfo` that the TV reports.
@immutable
final class TvTextFieldKind {
  /// Creates the kind.
  const TvTextFieldKind({
    this.password = false,
    this.multiLine = false,
    this.action = TvFieldAction.none,
    this.inputType = 0,
    this.imeOptions = 0,
  });

  /// Reads the kind from `EditorInfo.inputType` and `EditorInfo.imeOptions`.
  factory TvTextFieldKind.fromEditorInfo({int? inputType, int? imeOptions}) {
    final type = inputType ?? 0;
    return TvTextFieldKind(
      password: _isPassword(type),
      multiLine: type & _classMask == _classText && type & _multiLine != 0,
      action: _actionOf(imeOptions ?? 0),
      inputType: type,
      imeOptions: imeOptions ?? 0,
    );
  }

  /// Whether the field hides what is typed (text or number passwords).
  final bool password;

  /// Whether the field takes several lines.
  final bool multiLine;

  /// The field's action key.
  final TvFieldAction action;

  /// Android's `EditorInfo.inputType` as the TV reported it, for details the other fields do not give.
  final int inputType;

  /// Android's `EditorInfo.imeOptions` as the TV reported it.
  final int imeOptions;

  static const int _classMask = 0xf;
  static const int _classText = 1;
  static const int _classNumber = 2;
  static const int _variationMask = 0xff0;
  static const int _multiLine = 0x20000;

  // TYPE_TEXT_VARIATION_PASSWORD, _VISIBLE_PASSWORD, _WEB_PASSWORD; TYPE_NUMBER_VARIATION_PASSWORD.
  static const Set<int> _textPasswords = {0x80, 0x90, 0xe0};
  static const int _numberPassword = 0x10;

  static bool _isPassword(int inputType) {
    final variation = inputType & _variationMask;
    return switch (inputType & _classMask) {
      _classText => _textPasswords.contains(variation),
      _classNumber => variation == _numberPassword,
      _ => false,
    };
  }

  // IME_ACTION_GO = 2 … IME_ACTION_PREVIOUS = 7, in the low byte of imeOptions.
  static TvFieldAction _actionOf(int imeOptions) => switch (imeOptions & 0xff) {
    2 => TvFieldAction.go,
    3 => TvFieldAction.search,
    4 => TvFieldAction.send,
    5 => TvFieldAction.next,
    6 => TvFieldAction.done,
    7 => TvFieldAction.previous,
    _ => TvFieldAction.none,
  };

  @override
  bool operator ==(Object other) =>
      other is TvTextFieldKind && other.inputType == inputType && other.imeOptions == imeOptions;

  @override
  int get hashCode => Object.hash(inputType, imeOptions);

  @override
  String toString() =>
      'TvTextFieldKind(${[if (password) 'password', if (multiLine) 'multi-line', action.name].join(', ')})';
}
