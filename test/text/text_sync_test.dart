// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/text/text_sync.dart';
import 'package:test/test.dart';

void main() {
  group('textDifference', () {
    test('deletes what follows the common beginning and types the rest', () {
      expect(textDifference('hello', 'help'), const TextKeys(deletes: 2, insert: 'p'));
      expect(textDifference('', 'abc'), const TextKeys(insert: 'abc'));
      expect(textDifference('abc', ''), const TextKeys(deletes: 3));
      expect(textDifference('same', 'same').isEmpty, isTrue);
    });

    test('counts characters as the user sees them', () {
      expect(textDifference('ok 👍🏽', 'ok '), const TextKeys(deletes: 1));
      expect(textDifference('мир', 'мира'), const TextKeys(insert: 'а'));
      expect(textDifference('é', 'e'), const TextKeys(deletes: 1, insert: 'e'));
    });
  });

  group('replacementFor', () {
    TextReplace? plan(String tv, String wanted, {bool cursorAtStart = false}) =>
        replacementFor(tv, wanted, cursorAtStart: cursorAtStart);

    test('deletes what follows the common beginning first, keeping the character before', () {
      expect(plan('hello', 'help'), const TextReplace(2, 5, 'l'));
      expect(plan('abc_world', 'abc'), const TextReplace(2, 9, 'c'));
      expect(plan('abc', 'abd'), const TextReplace(1, 3, 'b'));
      expect(plan('same', 'same'), isNull);
    });

    test('an empty field takes the text at the cursor', () {
      expect(plan('', 'abc'), const TextReplace(0, 0, 'abc'));
    });

    test('text added at the end goes with the character before: an empty range would go to the cursor', () {
      expect(plan('hel', 'help'), const TextReplace(2, 3, 'lp'));
      expect(plan('ok 👍🏽', 'ok 👍🏽!'), const TextReplace(3, 7, '👍🏽!'));
    });

    test('emptying the field is an empty edit, or with the cursor at the start a placeholder of another length', () {
      expect(plan('_world', ''), const TextReplace(0, 6, ''));
      expect(plan('_world', '', cursorAtStart: true), const TextReplace(0, 6, '_'));
      expect(plan('x', '', cursorAtStart: true), const TextReplace(0, 1, 'xx'));
      expect(plan('👍🏽', '', cursorAtStart: true), const TextReplace(0, 4, '👍🏽👍🏽'));
    });

    test('positions count UTF-16 code units, cuts fall between characters as the user sees them', () {
      expect(plan('éé', 'é'), const TextReplace(0, 4, 'é'));
      expect(plan('👨‍👩‍👧 x', '👨‍👩‍👧'), const TextReplace(0, 10, '👨‍👩‍👧'));
    });
  });

  group('TextSync by range', () {
    test('one step in flight; what is wanted meanwhile goes out after the report', () {
      final sync = TextSync()..reset('');
      expect(sync.want('ab'), const TextReplace(0, 0, 'ab'));
      expect(sync.want('abc'), isNull);
      expect(sync.report('ab'), (adopt: null, send: const TextReplace(1, 2, 'bc')));
      expect(sync.report('abc'), (adopt: null, send: null));
      expect(sync.settled, isTrue);
    });

    test('a replacement goes as a deletion, then the rest', () {
      final sync = TextSync()..reset('abc');
      expect(sync.want('abXd'), const TextReplace(1, 3, 'b'));
      expect(sync.report('ab'), (adopt: null, send: const TextReplace(1, 2, 'bXd')));
      expect(sync.report('abXd'), (adopt: null, send: null));
    });

    test('a field at its length limit cuts the addition and keeps its text: the TV text wins', () {
      final sync = TextSync()..reset('abc');
      expect(sync.want('abcd'), const TextReplace(2, 3, 'cd'));
      expect(sync.stalled(), (adopt: 'abc', send: null));
    });

    test('a report other than the one planned is the field changing the text: the TV text wins', () {
      final sync = TextSync()..reset('');
      expect(sync.want('abcdef'), const TextReplace(0, 0, 'abcdef'));
      expect(sync.report('abc'), (adopt: 'abc', send: null));
      expect((sync.wanted, sync.waiting), ('abc', false));
    });

    test('a stalled edit is a field that kept its text (a limit, a filter): the TV text wins, ranges stay', () {
      final sync = TextSync()..reset('hello');
      expect(sync.want('hello!'), const TextReplace(4, 5, 'o!'));
      expect(sync.stalled(), (adopt: 'hello', send: null));
      expect(sync.want('hello'), isNull);
      expect((sync.byRange, sync.waiting), (true, false));
    });

    test('a TV that inserts an edit with a range at the cursor gets keys, which repair the field', () {
      final sync = TextSync()..reset('hello');
      expect(sync.want('hel'), const TextReplace(2, 5, 'l'));
      expect(sync.report('hellol'), (adopt: null, send: const TextKeys(deletes: 3)));
      expect(sync.byRange, isFalse);
    });

    test('an emptying that stalls (the cursor was at the start) goes again once, with a placeholder first', () {
      final sync = TextSync()..reset('abc');
      expect(sync.want(''), const TextReplace(0, 3, ''));
      expect(sync.stalled(), (adopt: null, send: const TextReplace(0, 3, 'a')));
      expect(sync.report('a', cursor: 1), (adopt: null, send: const TextReplace(0, 1, '')));
      expect(sync.stalled(), (adopt: 'a', send: null), reason: 'only once');
    });

    test('a TV that always reports the cursor at the start gets one placeholder, then the emptying', () {
      final sync = TextSync()..reset('a', cursor: 0);
      expect(sync.want(''), const TextReplace(0, 1, 'aa'));
      expect(sync.report('aa', cursor: 0), (adopt: null, send: const TextReplace(0, 2, '')));
      expect(sync.report('', cursor: 0), (adopt: null, send: null));
      expect(sync.settled, isTrue);
    });

    test('a report while nothing is in flight is a change made on the TV', () {
      final sync = TextSync()..reset('a');
      expect(sync.report('ab'), (adopt: 'ab', send: null));
      expect(sync.wanted, 'ab');
    });
  });

  group('TextSync by keys', () {
    test('Del keys first, then the insert after the last deletion is reported', () {
      final sync = TextSync(byRange: false)..reset('hello');
      expect(sync.want('help'), const TextKeys(deletes: 2));
      expect(sync.report('hell'), (adopt: null, send: null));
      expect(sync.report('hel'), (adopt: null, send: const TextKeys(insert: 'p')));
    });

    test('long deletions go out in batches', () {
      final sync = TextSync(maxDeletes: 3, byRange: false)..reset('abcdefg');
      expect(sync.want('a'), const TextKeys(deletes: 3));
      expect(sync.report('abcd'), (adopt: null, send: const TextKeys(deletes: 3)));
      expect(sync.report('a'), (adopt: null, send: null));
      expect(sync.settled, isTrue);
    });

    test('an insert the field changed is the TV text at once', () {
      final sync = TextSync(byRange: false)..reset('');
      expect(sync.want('abc'), const TextKeys(insert: 'abc'));
      expect(sync.report('ab'), (adopt: 'ab', send: null));
    });

    test('a stalled insertion gives way to the TV text', () {
      final sync = TextSync(byRange: false)..reset('');
      sync.want('a!');
      expect(sync.stalled(), (adopt: '', send: null));
      expect((sync.wanted, sync.waiting), ('', false));
      expect(sync.stalled(), (adopt: null, send: null));
    });

    test('a stalled deletion is planned again from the TV text, a few times', () {
      final sync = TextSync(byRange: false)..reset('abcd');
      expect(sync.want(''), const TextKeys(deletes: 4));
      sync.report('a');
      expect(sync.stalled(), (adopt: null, send: const TextKeys(deletes: 1)));
      expect(sync.stalled(), (adopt: null, send: const TextKeys(deletes: 1)));
      expect(sync.stalled(), (adopt: null, send: const TextKeys(deletes: 1)));
      expect(sync.stalled(), (adopt: 'a', send: null));
    });
  });
}
