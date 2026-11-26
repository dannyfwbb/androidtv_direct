// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/text/field_tracker.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

RemoteEnvelope tv(String name) => RemoteEnvelope.fromTv(recorded(name, outgoing: false, file: 'text.txt').bytes);

void main() {
  test('the recorded focus, keyboard and field reports', () {
    final tracker = FieldTracker();
    expect(tracker.apply(tv('focusReport.2')), isNull);
    expect(tracker.apply(tv('focusReport.3')), FieldEvent.focused);
    expect((tracker.keyboardRevision, tracker.fieldRevision, tracker.text), (198, 284, ''));
    expect(tracker.apply(tv('keyboardReport')), FieldEvent.keyboard);
    expect(tracker.keyboardOpen, isTrue);
    expect((tracker.keyboardRevision, tracker.fieldRevision), (198, 284), reason: "the focus report's revisions win");
    expect(tracker.apply(tv('fieldReport')), FieldEvent.content);
    expect((tracker.text, tracker.selectionEnd, tracker.fieldRevision), ('ab', 2, 287));
    expect(tracker.apply(tv('keyboardReport.2')), FieldEvent.keyboard);
    expect(tracker.keyboardOpen, isFalse);
    expect(tracker.apply(tv('focusReport.4')), FieldEvent.unfocused);
    expect(tracker.focused, isFalse);
  });

  test("the keyboard report's revisions fill in what the focus report left out", () {
    final tracker = FieldTracker()
      ..apply(
        FocusReport(
          app: FocusedApp(packageName: 'x'),
          textField: TextFieldState(text: ''),
        ),
      )
      ..apply(KeyboardReport(keyboardRevision: 4, fieldRevision: 9));
    expect((tracker.keyboardRevision, tracker.fieldRevision), (4, 9));
  });
}
