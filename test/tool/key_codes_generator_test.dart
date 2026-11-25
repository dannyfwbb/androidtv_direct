// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:test/test.dart';

import '../../tool/src/key_codes.dart';

void main() {
  group('dartName', () {
    test('turns AOSP names into lowerCamelCase', () {
      expect(dartName('DPAD_CENTER'), 'dpadCenter');
      expect(dartName('TV_INPUT_HDMI_1'), 'tvInputHdmi1');
      expect(dartName('F24'), 'f24');
      expect(dartName('HOME'), 'home');
    });

    test('names digits, keys 11 and 12 and reserved words by fixed rules', () {
      expect([for (var i = 0; i < 10; i++) dartName('$i')], [for (var i = 0; i < 10; i++) 'digit$i']);
      expect(dartName('11'), 'key11');
      expect(dartName('12'), 'key12');
      expect(dartName('3D_MODE'), 'mode3d');
      expect(dartName('BREAK'), 'breakKey');
      expect(dartName('NEW'), 'newKey');
    });

    test('fails for a name no rule covers', () {
      expect(() => dartName('13'), throwsFormatException);
      expect(() => dartName('4K_MODE'), throwsFormatException);
      expect(() => dartName('SWITCH'), throwsFormatException);
      expect(() => dartName('VALUES'), throwsFormatException);
    });
  });

  test('parses entries with the first line of the comment above them', () {
    const header = '''
enum {
    /** Unknown key code. */
    AKEYCODE_UNKNOWN         = 0,
    /** Soft Left key.
     * Usually situated below the display on phones. */
    AKEYCODE_SOFT_LEFT       = 1,
    /** '[' key. */
    AKEYCODE_LEFT_BRACKET    = 71,
    /** Open Emoji picker */
    AKEYCODE_EMOJI_PICKER = 317,
    AKEYCODE_NO_COMMENT = 400,
};
''';
    expect(parseKeyCodes(header), [
      (name: 'UNKNOWN', code: 0, comment: 'Unknown key code.'),
      (name: 'SOFT_LEFT', code: 1, comment: 'Soft Left key.'),
      (name: 'LEFT_BRACKET', code: 71, comment: r"'\[' key."),
      (name: 'EMOJI_PICKER', code: 317, comment: 'Open Emoji picker.'),
      (name: 'NO_COMMENT', code: 400, comment: 'No description in AOSP.'),
    ]);
  });

  test('generates an enum with codes and a lookup', () {
    final source = generateKeyCodes([
      (name: '0', code: 7, comment: "'0' key."),
      (name: 'HOME', code: 3, comment: 'Home.'),
    ]);
    expect(source, contains("  /// '0' key.\n  digit0(7),\n\n  /// Home.\n  home(3);\n"));
    expect(source, contains('static TvKey? fromCode(int code)'));
    expect(source, contains('The Android Open Source Project'));
  });
}
