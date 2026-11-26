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
    TextReplace? plan(String tv, String wanted, [int? cursor]) =>
        replacementFor(tv, wanted, cursor: cursor ?? tv.length);

    test('replaces what follows the common beginning, to the end', () {
      expect(plan('hello', 'help'), const TextReplace(3, 5, 'p'));
      expect(plan('hello world', ''), const TextReplace(0, 11, ''));
      expect(plan('same', 'same'), isNull);
    });

    test('an empty field takes the text at the cursor', () {
      expect(plan('', 'abc'), const TextReplace(0, 0, 'abc'));
    });

    test('text added at the end replaces the last character too: an empty range would go to the cursor', () {
      expect(plan('ab', 'abc'), const TextReplace(1, 2, 'bc'));
      expect(plan('ok 👍🏽', 'ok 👍🏽!'), const TextReplace(3, 7, '👍🏽!'));
    });

    test('a change that keeps the length is split: the deletion goes first', () {
      expect(plan('abc', 'abd'), const TextReplace(2, 3, ''));
      expect(plan('hello_world', 'hello_there'), const TextReplace(6, 11, ''));
    });

    test('a deletion that starts at the cursor takes the character before along', () {
      expect(plan('abc_world', 'abc', 3), const TextReplace(2, 9, 'c'));
      expect(plan('abc', 'abd', 2), const TextReplace(1, 3, 'b'));
    });

    test('emptying the field with the cursor at its start puts a placeholder of another length first', () {
      expect(plan('_world', '', 0), const TextReplace(0, 6, '_'));
      expect(plan('x', '', 0), const TextReplace(0, 1, 'xx'));
      expect(plan('👍🏽', '', 0), const TextReplace(0, 4, '👍🏽👍🏽'));
    });

    test('positions count UTF-16 code units, cuts fall between characters as the user sees them', () {
      expect(plan('éé', 'é'), const TextReplace(2, 4, ''));
      expect(plan('👨‍👩‍👧 x', '👨‍👩‍👧'), const TextReplace(8, 10, ''));
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

    test('a replacement that keeps the length goes as a deletion, then the rest', () {
      final sync = TextSync()..reset('abc');
      expect(sync.want('abd'), const TextReplace(2, 3, ''));
      expect(sync.report('ab'), (adopt: null, send: const TextReplace(1, 2, 'bd')));
      expect(sync.report('abd'), (adopt: null, send: null));
    });

    test('a report other than the one planned is the field changing the text: the TV text wins', () {
      final sync = TextSync()..reset('');
      expect(sync.want('abcdef'), const TextReplace(0, 0, 'abcdef'));
      expect(sync.report('abc'), (adopt: 'abc', send: null));
      expect((sync.wanted, sync.waiting), ('abc', false));
    });

    test('an edit with a range that is not answered goes again as keys, and keys stay', () {
      final sync = TextSync()..reset('abcdef');
      expect(sync.want('ab'), const TextReplace(2, 6, ''));
      expect(sync.stalled(), (adopt: null, send: const TextKeys(deletes: 4)));
      expect(sync.byRange, isFalse);
      for (final text in ['abcde', 'abcd', 'abc']) {
        expect(sync.report(text), (adopt: null, send: null));
      }
      expect(sync.report('ab'), (adopt: null, send: null));
      expect(sync.want('a'), const TextKeys(deletes: 1));
    });

    test('a TV that inserts an edit with a range at the cursor gets keys, which repair the field', () {
      final sync = TextSync()..reset('hello');
      expect(sync.want('help'), const TextReplace(3, 5, 'p'));
      expect(sync.report('hellop'), (adopt: null, send: const TextKeys(deletes: 3)));
      expect(sync.byRange, isFalse);
    });

    test('an insertion into an empty field that is not answered gives way to the TV text', () {
      final sync = TextSync()..reset('');
      sync.want('a!');
      expect(sync.stalled(), (adopt: '', send: null));
      expect((sync.wanted, sync.waiting, sync.byRange), ('', false, true));
    });

    test('a report while nothing is in flight is a change made on the TV', () {
      final sync = TextSync()..reset('a');
      expect(sync.report('ab'), (adopt: 'ab', send: null));
      expect(sync.wanted, 'ab');
    });

    test('the cursor the TV reports shapes the next edit', () {
      final sync = TextSync()..reset('abc_world', cursor: 3);
      expect(sync.want('abc'), const TextReplace(2, 9, 'c'));
      expect(sync.report('abc', cursor: 3), (adopt: null, send: null));
      expect(sync.want(''), const TextReplace(0, 3, ''));
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
