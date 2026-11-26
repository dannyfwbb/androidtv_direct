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

  FocusReport focusOn(String package, int? view, {String text = '', int? start, int? end}) => FocusReport(
    app: FocusedApp(packageName: package, viewId: view),
    textField: TextFieldState(text: text, selectionStart: start, selectionEnd: end),
  );

  test('a selection outside the text is clamped to it, also -1', () {
    final tracker = FieldTracker()..apply(focusOn('x', 1, text: 'abc', start: -1, end: 99));
    expect((tracker.selectionStart, tracker.selectionEnd), (0, 3));
    tracker.apply(FieldReport(textField: TextFieldState(text: 'a', selectionStart: 3, selectionEnd: 3)));
    expect((tracker.selectionStart, tracker.selectionEnd), (1, 1));
  });

  test('the same view focused again is a content change; another view, or one without an id, a new focus', () {
    final tracker = FieldTracker();
    expect(tracker.apply(focusOn('x', 1)), FieldEvent.focused);
    expect(tracker.apply(focusOn('x', 1, text: 'a')), FieldEvent.content);
    expect(tracker.apply(focusOn('x', 2)), FieldEvent.focused);
    expect(tracker.apply(focusOn('y', 2)), FieldEvent.focused);
    expect(tracker.apply(focusOn('y', null)), FieldEvent.focused);
    expect(tracker.apply(focusOn('y', null)), FieldEvent.focused, reason: 'without an id the view cannot be the same');
  });

  test('reports without a focused field change nothing visible', () {
    final tracker = FieldTracker();
    expect(tracker.apply(FocusReport(app: FocusedApp(packageName: 'x'))), isNull);
    expect(tracker.apply(KeyboardReport(keyboardRevision: 1)), isNull);
    expect(tracker.apply(FieldReport(textField: TextFieldState(text: 'zz'))), isNull);
    expect(tracker.apply(FieldReport()), isNull, reason: 'a field report without its field');
    expect(tracker.apply(PingMessage(id: 1)), isNull);
  });
}
