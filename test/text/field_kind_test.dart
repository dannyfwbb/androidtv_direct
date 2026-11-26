// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

void main() {
  TvTextFieldKind kind(int inputType, [int imeOptions = 0]) =>
      TvTextFieldKind.fromEditorInfo(inputType: inputType, imeOptions: imeOptions);

  test('passwords: text, visible, web and number variations', () {
    for (final type in [0x81, 0x91, 0xe1, 0x12]) {
      expect(kind(type).password, isTrue, reason: type.toRadixString(16));
    }
    for (final type in [0x1, 0x21, 0x2, 0x3]) {
      expect(kind(type).password, isFalse, reason: type.toRadixString(16));
    }
  });

  test('multi-line text', () {
    expect(kind(0x20001).multiLine, isTrue);
    expect(kind(0x20002).multiLine, isFalse);
  });

  test('the action key from the low byte of imeOptions', () {
    expect(kind(1, 0x1C000006).action, TvFieldAction.done, reason: 'the emulator name field');
    expect(kind(1, 3).action, TvFieldAction.search);
    expect(kind(1, 0).action, TvFieldAction.none);
    expect(TvTextFieldKind.fromEditorInfo().password, isFalse);
  });
}
