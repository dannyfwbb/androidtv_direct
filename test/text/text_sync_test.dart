// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/text/text_sync.dart';
import 'package:test/test.dart';

void main() {
  group('textDifference', () {
    test('deletes what follows the common beginning and types the rest', () {
      expect(textDifference('hello', 'help'), const TextStep(deletes: 2, insert: 'p'));
      expect(textDifference('', 'abc'), const TextStep(insert: 'abc'));
      expect(textDifference('abc', ''), const TextStep(deletes: 3));
      expect(textDifference('same', 'same').isEmpty, isTrue);
    });

    test('counts characters as the user sees them', () {
      expect(textDifference('ok 👍🏽', 'ok '), const TextStep(deletes: 1));
      expect(textDifference('мир', 'мира'), const TextStep(insert: 'а'));
      expect(textDifference('é', 'e'), const TextStep(deletes: 1, insert: 'e'));
    });
  });

  group('TextSync', () {
    test('one step in flight; what is wanted meanwhile goes out after the report', () {
      final sync = TextSync()..reset('');
      expect(sync.want('ab'), const TextStep(insert: 'ab'));
      expect(sync.want('abc'), isNull);
      expect(sync.report('ab'), (adopt: null, send: const TextStep(insert: 'c')));
      expect(sync.report('abc'), (adopt: null, send: null));
      expect(sync.settled, isTrue);
    });

    test('Del keys first, then the insert after the last deletion is reported', () {
      final sync = TextSync()..reset('hello');
      expect(sync.want('help'), const TextStep(deletes: 2));
      expect(sync.report('hell'), (adopt: null, send: null));
      expect(sync.report('hel'), (adopt: null, send: const TextStep(insert: 'p')));
    });

    test('long deletions go out in batches', () {
      final sync = TextSync(maxDeletes: 3)..reset('abcdefg');
      expect(sync.want('a'), const TextStep(deletes: 3));
      expect(sync.report('abcd'), (adopt: null, send: const TextStep(deletes: 3)));
      expect(sync.report('a'), (adopt: null, send: null));
      expect(sync.settled, isTrue);
    });

    test('a report while nothing is in flight is a change made on the TV', () {
      final sync = TextSync()..reset('a');
      expect(sync.report('ab'), (adopt: 'ab', send: null));
      expect(sync.wanted, 'ab');
    });

    test('a stalled insertion gives way to the TV text', () {
      final sync = TextSync()..reset('');
      sync.want('a!');
      expect(sync.stalled(), (adopt: '', send: null));
      expect((sync.wanted, sync.waiting), ('', false));
      expect(sync.stalled(), (adopt: null, send: null));
    });

    test('a stalled deletion is planned again from the TV text, a few times', () {
      final sync = TextSync()..reset('abcd');
      expect(sync.want(''), const TextStep(deletes: 4));
      sync.report('a');
      expect(sync.stalled(), (adopt: null, send: const TextStep(deletes: 1)));
      expect(sync.stalled(), (adopt: null, send: const TextStep(deletes: 1)));
      expect(sync.stalled(), (adopt: null, send: const TextStep(deletes: 1)));
      expect(sync.stalled(), (adopt: 'a', send: null));
    });
  });
}
