// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_field.dart';
import '../support/fake_remote.dart';
import '../support/fake_session.dart';
import '../support/wait.dart';

void main() {
  late FakeSession fake;
  late FakeClock clock;
  late TvRemote remote;

  Future<void> connect({Set<TvFeature> features = const {TvFeature.key, TvFeature.ime}}) async {
    final connected = await FakeRemote.connect(features: features);
    (fake, clock, remote) = (connected.session, connected.clock, connected.remote);
  }

  /// Focuses [field] on the fake TV and returns the client's view of it.
  Future<TvTextField> focus(FakeField field) async {
    await fake.focus(field);
    await until(() => remote.textField != null && remote.textField!.text == field.text);
    return remote.textField!;
  }

  /// Lets the session find out that the TV does not take ranges: a field ignores one, keys follow.
  Future<void> learnKeysOnly() async {
    final field = await focus(FakeField(text: 'x', honoursRanges: false));
    final cleared = field.setText('');
    await fake.received<TextEditMessage>();
    clock.advance(const Duration(milliseconds: 1500));
    expect(await cleared, '');
  }

  setUp(connect);

  test('setText types into an empty field', () async {
    final tvField = FakeField();
    final field = await focus(tvField);
    expect(field.kind.action, TvFieldAction.search);
    expect(await field.setText('Привет, мир 👍🏽'), 'Привет, мир 👍🏽');
    expect(tvField.text, 'Привет, мир 👍🏽');
  });

  test('setText deletes what differs with one edit naming the range, then adds the rest', () async {
    final tvField = FakeField(text: 'ok 👍🏽 fine');
    final field = await focus(tvField);
    expect(await field.setText('ok 👌'), 'ok 👌');
    expect(fake.fromClient.whereType<KeyMessage>(), isEmpty, reason: 'no Del keys');
    final edits = fake.fromClient.whereType<TextEditMessage>().map((e) => e.changes.single.replacement!);
    expect(edits.map((r) => (r.start, r.end, r.text)), [(2, 12, ' '), (2, 3, ' 👌')]);
  });

  test('a replacement that keeps the length goes in two edits, so the TV reports both', () async {
    final field = await focus(FakeField(text: 'hello_world'));
    expect(await field.setText('hello_there'), 'hello_there');
    final edits = fake.fromClient.whereType<TextEditMessage>().map((e) => e.changes.single.replacement!);
    expect(edits.map((r) => (r.start, r.end, r.text)), [(5, 11, '_'), (5, 6, '_there')]);
    expect(await field.setText('hello_there!'), 'hello_there!');
  });

  test('a TV that inserts edits at the cursor gets Del keys, whole characters as the user sees them', () async {
    final tvField = FakeField(text: 'ok 👍🏽 fine', honoursRanges: false);
    final field = await focus(tvField);
    expect(await field.setText('ok 👌'), 'ok 👌');
    final dels = fake.fromClient.whereType<KeyMessage>().where((k) => k.code == TvKey.del.code);
    expect(dels, hasLength(7), reason: '"👍🏽 fine👌" is seven characters: the misplaced insert goes too');
  });

  test('a TV that inserts edits at the cursor is found out by a deletion too', () async {
    final tvField = FakeField(text: 'abc', honoursRanges: false);
    final field = await focus(tvField);
    expect(await field.setText('a'), 'a');
    expect(fake.fromClient.whereType<KeyMessage>().where((k) => k.code == TvKey.del.code), hasLength(3));
  });

  test('a long text is emptied with one edit', () async {
    final field = await focus(FakeField(text: 'x' * 5000));
    expect(await field.setText(''), '');
    expect(fake.fromClient.whereType<TextEditMessage>(), hasLength(1));
  });

  test('a cursor away from the end does not matter to edits with a range', () async {
    for (final cursor in [0, 2, 3, 5]) {
      final field = await focus(FakeField(text: 'hello', cursor: cursor));
      expect(await field.setText('help'), 'help', reason: 'cursor at $cursor');
      expect(await field.setText(''), '', reason: 'cursor at $cursor');
    }
    expect(fake.fromClient.whereType<KeyMessage>(), isEmpty, reason: 'no Move End, no Del');
  });

  test('once one field found the TV ignores ranges, later fields start with keys', () async {
    await learnKeysOnly();
    final edits = fake.fromClient.whereType<TextEditMessage>().length;
    final field = await focus(FakeField(text: 'abc', honoursRanges: false));
    expect(await field.setText('a'), 'a');
    expect(fake.fromClient.whereType<TextEditMessage>(), hasLength(edits), reason: 'only the first field tried ranges');
  });

  test('with keys, a cursor away from the end is moved there first', () async {
    await learnKeysOnly();
    final keysBefore = fake.fromClient.whereType<KeyMessage>().length;
    final field = await focus(FakeField(text: 'hello', cursor: 2, honoursRanges: false));
    final result = field.setText('help');
    await fake.received<KeyMessage>(count: keysBefore + 1);
    expect(fake.fromClient.whereType<KeyMessage>().elementAt(keysBefore).code, TvKey.moveEnd.code);
    // No report of the cursor (as on the emulator): the edit goes out after a short wait.
    clock.advance(const Duration(milliseconds: 300));
    expect(await result, 'help');
  });

  test('texts wanted while a step is in flight go out together after the report', () async {
    final tvField = FakeField();
    final field = await focus(tvField);
    final results = await Future.wait([field.setText('a'), field.setText('ab'), field.setText('abc')]);
    expect(results, ['abc', 'abc', 'abc']);
    expect(fake.fromClient.whereType<TextEditMessage>().map((e) => e.changes.single.replacement!.text), ['a', 'abc']);
    expect(tvField.dropped, isEmpty);
  });

  test('a field that replaces its text on every edit: the TV text wins, and a second call gets there', () async {
    final tvField = FakeField(mode: FieldMode.replace);
    final field = await focus(tvField);
    await field.setText('ab');
    expect(await field.setText('abcd'), 'bcd', reason: 'the field replaced "ab" with the edit\'s "bcd"');
    expect(await field.setText('abcd'), 'abcd', reason: 'the whole text replaces the whole field');
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
    final tvField = FakeField(text: 'abcdef', loseDels: 2, honoursRanges: false);
    final field = await focus(tvField);
    final result = field.setText('');
    await fake.received<TextEditMessage>();
    clock.advance(const Duration(milliseconds: 1500));
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
    await fake.received<TextEditMessage>();
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
    final tvField = FakeField(text: 'x' * 70, honoursRanges: false);
    final field = await focus(tvField);
    final result = field.setText('');
    await fake.received<TextEditMessage>();
    clock.advance(const Duration(milliseconds: 1500));
    expect(await result, '');
    // The placeholder the emptying retried with went in at the cursor too: one more to delete.
    expect(fake.fromClient.whereType<KeyMessage>().where((k) => k.code == TvKey.del.code), hasLength(71));
  });

  test('a deletion that keeps stalling gives way to the TV text after three tries', () async {
    final tvField = FakeField(text: 'abcd', loseDels: 100, honoursRanges: false);
    final field = await focus(tvField);
    var done = false;
    final result = field.setText('').whenComplete(() => done = true);
    for (var i = 0; i < 10 && !done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      clock.advance(const Duration(milliseconds: 1500));
    }
    expect(await result, 'abcda', reason: 'the placeholder went in at the cursor; every Del key was lost');
  });

  test('setText of the text the field already has completes without sending', () async {
    final field = await focus(FakeField(text: 'same'));
    expect(await field.setText('same'), 'same');
    expect(fake.fromClient.whereType<KeyMessage>(), isEmpty);
    expect(fake.fromClient.whereType<TextEditMessage>(), isEmpty);
  });

  test('with keys, a second setText while a step is in flight waits for it, without moving the cursor', () async {
    await learnKeysOnly();
    final field = await focus(FakeField(text: 'hello', cursor: 2, honoursRanges: false));
    final first = field.setText('help');
    await until(() => clock.pendingTimers > 0);
    clock.advance(const Duration(milliseconds: 300));
    await fake.received<KeyMessage>(count: fake.fromClient.whereType<KeyMessage>().length + 1);
    final second = field.setText('he');
    expect(await Future.wait([first, second]).timeout(const Duration(seconds: 5)), ['he', 'he']);
  });

  test('with keys, a cursor away from the end: Move End, its report, then the edit', () async {
    await learnKeysOnly();
    final keysBefore = fake.fromClient.whereType<KeyMessage>().length;
    final tvField = FakeField(text: 'hello', cursor: 1, reportCursorMoves: true, honoursRanges: false);
    final field = await focus(tvField);
    expect(await field.setText('help'), 'help');
    final keys = fake.fromClient.whereType<KeyMessage>().skip(keysBefore).map((k) => k.code).toList();
    expect(keys.first, TvKey.moveEnd.code);
    expect(tvField.dropped, isEmpty, reason: 'the edit waited for the revision the cursor report brought');
  });

  test('the same field reported again keeps its object and a waiting setText', () async {
    final tvField = FakeField(reject: 'x');
    final field = await focus(tvField);
    final waiting = field.setText('x');
    await fake.received<TextEditMessage>();
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

  test('a step that cannot go out from a timer fails the waiting setText instead of escaping', () async {
    // Lost Del keys stall the deletion, and the give-up timer sends them again: here after the session ended but
    // before the field heard of it.
    final field = await focus(FakeField(text: 'abcdef', loseDels: 2, honoursRanges: false));
    final cleared = field.setText('');
    await fake.received<TextEditMessage>();
    clock.advance(const Duration(milliseconds: 1500));
    await until(() => field.text == 'ab');
    final closing = remote.close();
    clock.advance(const Duration(milliseconds: 1500));
    await expectLater(cleared, throwsA(isA<TvCancelledException>()));
    await closing;
  });

  test('the end of the session fails a waiting setText with why it ended', () async {
    final tvField = FakeField(reject: 'x');
    final field = await focus(tvField);
    final waiting = expectLater(field.setText('x'), throwsA(isA<TvCancelledException>()));
    await fake.received<TextEditMessage>();
    await remote.close();
    await waiting;
  });
}
