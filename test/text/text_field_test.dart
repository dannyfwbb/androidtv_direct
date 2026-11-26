// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_field.dart';
import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  late FakeSession fake;
  late FakeClock clock;
  late TvRemote remote;

  Future<void> connect({Set<TvFeature> features = const {TvFeature.key, TvFeature.ime}}) async {
    fake = FakeSession();
    clock = FakeClock();
    final tv = await startFakeTv(onRemote: fake.serve);
    remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: features,
      clock: clock,
    );
    addTearDown(remote.close);
  }

  /// Focuses [field] on the fake TV and returns the client's view of it.
  Future<TvTextField> focus(FakeField field) async {
    await fake.focus(field);
    await until(() => remote.textField != null && remote.textField!.text == field.text);
    return remote.textField!;
  }

  setUp(connect);

  test('setText types into an empty field', () async {
    final tvField = FakeField();
    final field = await focus(tvField);
    expect(field.kind.action, TvFieldAction.search);
    expect(await field.setText('Привет, мир 👍🏽'), 'Привет, мир 👍🏽');
    expect(tvField.text, 'Привет, мир 👍🏽');
  });

  test('setText replaces what differs, deleting whole characters as the user sees them', () async {
    final tvField = FakeField(text: 'ok 👍🏽 fine');
    final field = await focus(tvField);
    expect(await field.setText('ok 👌'), 'ok 👌');
    final dels = fake.fromClient.whereType<KeyMessage>().where((k) => k.code == TvKey.del.code);
    expect(dels, hasLength(6), reason: '"👍🏽 fine" is six characters');
  });

  test('a cursor away from the end is moved there first', () async {
    final tvField = FakeField(text: 'hello', cursor: 2);
    final field = await focus(tvField);
    final result = field.setText('help');
    await until(() => fake.fromClient.whereType<KeyMessage>().isNotEmpty);
    expect(fake.fromClient.whereType<KeyMessage>().first.code, TvKey.moveEnd.code);
    // No report of the cursor (as on the emulator): the edit goes out after a short wait.
    clock.advance(const Duration(milliseconds: 300));
    expect(await result, 'help');
  });

  test('texts wanted while a step is in flight go out together after the report', () async {
    final tvField = FakeField();
    final field = await focus(tvField);
    final results = await Future.wait([field.setText('a'), field.setText('ab'), field.setText('abc')]);
    expect(results, ['abc', 'abc', 'abc']);
    expect(fake.fromClient.whereType<TextEditMessage>().map((e) => e.changes.single.replacement!.text), ['a', 'bc']);
    expect(tvField.dropped, isEmpty);
  });

  test('a field that replaces its text on every edit: the TV text wins, and a second call gets there', () async {
    final tvField = FakeField(mode: FieldMode.replace);
    final field = await focus(tvField);
    await field.setText('ab');
    final first = field.setText('abc');
    await until(() => field.text == 'c');
    clock.advance(const Duration(milliseconds: 1500));
    expect(await first, 'c', reason: 'the field replaced "ab" with "c"; setText gives what the TV has');
    expect(await field.setText('abc'), 'abc');
  });

  test('a field that filters or limits what is typed: the TV text wins after the give-up time', () async {
    final tvField = FakeField(reject: '!', maxLength: 5);
    final field = await focus(tvField);
    final adopted = <String>[];
    field.changes.listen(adopted.add);
    final result = field.setText('hi!!');
    await until(() => field.text == 'hi');
    clock.advance(const Duration(milliseconds: 1500));
    expect(await result, 'hi');
    expect(adopted, ['hi']);
  });

  test('Del keys the TV loses are sent again once the reports stall', () async {
    final tvField = FakeField(text: 'abcdef', loseDels: 2);
    final field = await focus(tvField);
    final result = field.setText('');
    await until(() => field.text == 'ab');
    clock.advance(const Duration(milliseconds: 1500));
    expect(await result, '');
  });

  test("the TV's keyboard opening and closing arrives on keyboardChanges", () async {
    final field = await focus(FakeField());
    final seen = <bool>[];
    field.keyboardChanges.listen(seen.add);
    await fake.sendMessage(KeyboardReport(keyboardRevision: 3, fieldRevision: 1));
    await fake.sendMessage(KeyboardReport(keyboardRevision: 0, fieldRevision: 1));
    await until(() => seen.length == 2);
    expect(seen, [true, false]);
    expect(field.keyboardOpen, isFalse);
  });

  test('changes made on the TV arrive as changes', () async {
    final tvField = FakeField();
    final field = await focus(tvField);
    final seen = <String>[];
    field.changes.listen(seen.add);
    await fake.sendMessage(tvField.typeOnTv('from the TV'));
    await until(() => seen.isNotEmpty);
    expect(seen, ['from the TV']);
    expect(field.text, 'from the TV');
  });

  test('losing the focus cancels a waiting setText; a new focus gives a new field', () async {
    final tvField = FakeField(reject: 'x');
    final field = await focus(tvField);
    final waiting = expectLater(field.setText('x'), throwsA(isA<TvCancelledException>()));
    await until(() => fake.fromClient.whereType<TextEditMessage>().isNotEmpty);
    final focusChanges = <TvTextField?>[];
    remote.textFieldChanges.listen(focusChanges.add);
    await fake.unfocus();
    await waiting;
    expect(field.isFocused, isFalse);
    expect(remote.textField, isNull);
    final second = await focus(FakeField(text: 'next'));
    expect(second, isNot(same(field)));
    expect(focusChanges, [null, second]);
    await expectLater(field.setText('y'), throwsA(isA<TvCancelledException>()));
  });

  test('insert sends one edit with the current revisions; submit presses Enter', () async {
    final tvField = FakeField(text: 'ab');
    final field = await focus(tvField);
    field
      ..insert('c')
      ..submit();
    await until(() => tvField.text == 'abc' && fake.fromClient.whereType<KeyMessage>().isNotEmpty);
    expect(fake.fromClient.whereType<KeyMessage>().single.code, TvKey.enter.code);
  });

  test('without the ime feature there is no text field, even if the TV reports one', () async {
    await connect(features: const {TvFeature.key});
    await fake.focus(FakeField(text: 'x'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(remote.textField, isNull);
  });

  test('without the key feature setText fails through its future and leaves the field usable', () async {
    await connect(features: const {TvFeature.ime});
    final field = await focus(FakeField(text: 'x'));
    await expectLater(field.setText('y'), throwsA(isA<TvNotSupportedException>()));
    expect(field.submit, throwsA(isA<TvNotSupportedException>()));
  });

  test('a field that limits its length: the TV text wins after the give-up time', () async {
    final tvField = FakeField(maxLength: 3);
    final field = await focus(tvField);
    final result = field.setText('abcdef');
    await until(() => field.text == 'abc');
    clock.advance(const Duration(milliseconds: 1500));
    expect(await result, 'abc');
  });

  test('more than 30 Del keys go out in batches, each after the last is reported', () async {
    final tvField = FakeField(text: 'x' * 70);
    final field = await focus(tvField);
    expect(await field.setText(''), '');
    expect(fake.fromClient.whereType<KeyMessage>().where((k) => k.code == TvKey.del.code), hasLength(70));
  });

  test('a deletion that keeps stalling gives way to the TV text after three tries', () async {
    final tvField = FakeField(text: 'abcd', loseDels: 100);
    final field = await focus(tvField);
    final result = field.setText('');
    for (var i = 0; i < 4; i++) {
      await until(() => clock.pendingTimers > 1);
      clock.advance(const Duration(milliseconds: 1500));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await result, 'abcd');
  });

  test('setText of the text the field already has completes without sending', () async {
    final field = await focus(FakeField(text: 'same'));
    expect(await field.setText('same'), 'same');
    expect(fake.fromClient.whereType<KeyMessage>(), isEmpty);
    expect(fake.fromClient.whereType<TextEditMessage>(), isEmpty);
  });

  test('a selected range or a cursor away from the end: Move End, its report, then the edit', () async {
    final tvField = FakeField(text: 'hello', cursor: 1, reportCursorMoves: true);
    final field = await focus(tvField);
    expect(await field.setText('help'), 'help');
    final keys = fake.fromClient.whereType<KeyMessage>().map((k) => k.code).toList();
    expect(keys.first, TvKey.moveEnd.code);
    expect(tvField.dropped, isEmpty, reason: 'the edit waited for the revision the cursor report brought');
  });

  test('the same field reported again keeps its object and a waiting setText', () async {
    final tvField = FakeField(reject: 'x');
    final field = await focus(tvField);
    final waiting = field.setText('x');
    await until(() => fake.fromClient.whereType<TextEditMessage>().isNotEmpty);
    await fake.sendMessage(tvField.focusReport());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(remote.textField, same(field));
    clock.advance(const Duration(milliseconds: 1500));
    expect(await waiting, '');
  });

  test('a stopped field keeps its own values', () async {
    final field = await focus(FakeField(text: 'first', cursor: 2));
    await fake.focus(FakeField(text: 'second field'));
    await until(() => remote.textField != field && remote.textField != null);
    expect((field.text, field.selection, field.isFocused), ('first', (start: 2, end: 2), false));
  });

  test('the end of the session fails a waiting setText with why it ended', () async {
    final tvField = FakeField(reject: 'x');
    final field = await focus(tvField);
    final waiting = expectLater(field.setText('x'), throwsA(isA<TvCancelledException>()));
    await until(() => fake.fromClient.whereType<TextEditMessage>().isNotEmpty);
    await remote.close();
    await waiting;
  });
}
