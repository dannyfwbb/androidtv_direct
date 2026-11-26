// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:androidtv_direct/src/text/text_sync.dart';
import 'package:characters/characters.dart';
import 'package:test/test.dart';

/// A TV field as the emulator's behaves, with faults: Del keys reported one at a time and sometimes lost, characters
/// it filters out, a length limit, reports that come late (in order: they share one connection), and edits made on
/// the TV itself.
final class _Tv {
  _Tv(this.random, {required this.loseDel, required this.late, this.reject = const {}, this.maxLength});

  final Random random;
  final double loseDel;
  final double late;
  final Set<String> reject;
  final int? maxLength;
  String text = '';

  /// Reports the client has not seen yet, in order.
  final List<String> _reports = [];

  /// Whether the connection holds reports back for now.
  bool _held = false;

  /// The reports the client can read now.
  List<String> get reports => _held ? const [] : _reports;

  /// The next report, in order.
  String take() => _reports.removeAt(0);

  void apply(TextStep? step) {
    if (step == null) return;
    for (var i = 0; i < step.deletes; i++) {
      if (text.isEmpty || random.nextDouble() < loseDel) continue;
      _report(text.characters.skipLast(1).string);
    }
    if (step.insert.isEmpty) return;
    final typed = step.insert.characters.where((c) => !reject.contains(c)).join();
    final next = text + typed;
    final limit = maxLength;
    final kept = limit == null ? next : next.characters.take(limit).string;
    // A field that took nothing may stay silent.
    if (kept == text && random.nextBool()) return;
    _report(kept);
  }

  void typeHere() => _report(text + 'xyz'[random.nextInt(3)]);

  void _report(String value) {
    text = value;
    _reports.add(value);
    if (random.nextDouble() < late) _held = true;
  }

  void releaseLate() => _held = false;
}

const List<String> _alphabet = ['a', 'b', 'c', 'й', '👍🏽', 'é', ' '];

String _randomText(Random random) =>
    List.generate(random.nextInt(12), (_) => _alphabet[random.nextInt(_alphabet.length)]).join();

/// Runs one session: random wants, the TV's faults, then everything delivered. Returns the steps taken.
int _run(int seed, {double loseDel = 0, double late = 0, Set<String> reject = const {}, int? maxLength}) {
  final random = Random(seed);
  final tv = _Tv(random, loseDel: loseDel, late: late, reject: reject, maxLength: maxLength);
  final sync = TextSync(maxDeletes: 1 + random.nextInt(5))..reset('');
  var wants = 5 + random.nextInt(20);
  var steps = 0;

  void outcome(SyncOutcome result) => tv.apply(result.send);

  while (true) {
    if (++steps > 10000) fail('seed $seed: no end after $steps steps');
    final roll = random.nextDouble();
    if (wants > 0 && roll < 0.3) {
      wants--;
      tv.apply(sync.want(_randomText(random)));
    } else if (wants > 0 && roll < 0.33) {
      tv.typeHere();
    } else if (tv.reports.isNotEmpty) {
      outcome(sync.report(tv.take()));
    } else if (roll < 0.5) {
      tv.releaseLate();
    } else if (sync.waiting) {
      outcome(sync.stalled());
    } else if (wants == 0) {
      tv.releaseLate();
      if (tv.reports.isEmpty) break;
    }
  }
  expect(sync.tv, tv.text, reason: 'seed $seed: the client knows what the TV shows');
  expect(sync.settled, isTrue, reason: 'seed $seed: wanted ${sync.wanted}, TV ${tv.text}');
  return steps;
}

void main() {
  test('a well-behaved TV ends with the text last wanted, or the one typed on it', () {
    for (var seed = 0; seed < 2000; seed++) {
      _run(seed);
    }
  });

  test('lost Del keys, late reports, filtered characters and a length limit: the two still agree', () {
    for (var seed = 0; seed < 2000; seed++) {
      _run(seed, loseDel: 0.1, late: 0.1, reject: const {'й'}, maxLength: 1 + seed % 8);
    }
  });

  test('a TV that loses every Del key: the client gives up and takes its text', () {
    for (var seed = 0; seed < 500; seed++) {
      _run(seed, loseDel: 1);
    }
  });
}
