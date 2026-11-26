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
  _Tv(
    this.random, {
    required this.loseDel,
    required this.late,
    this.reject = const {},
    this.maxLength,
    this.honoursRanges = true,
  });

  final Random random;
  final double loseDel;
  final double late;
  final Set<String> reject;
  final int? maxLength;
  final bool honoursRanges;
  String text = '';

  /// Changes the TV made without reporting them: a filter or a limit that left the length as it was.
  int silentChanges = 0;

  /// Reports the client has not seen yet, in order.
  final List<({String text, int cursor})> _reports = [];

  /// Whether the connection holds reports back for now.
  bool _held = false;

  /// The reports the client can read now.
  List<({String text, int cursor})> get reports => _held ? const [] : _reports;

  /// The next report, in order.
  ({String text, int cursor}) take() => _reports.removeAt(0);

  int cursor = 0;

  void apply(TextStep? step) {
    switch (step) {
      case null:
        return;
      case TextKeys(:final deletes, :final insert):
        for (var i = 0; i < deletes; i++) {
          if (text.isEmpty || random.nextDouble() < loseDel) continue;
          _report(text.characters.skipLast(1).string);
        }
        if (insert.isNotEmpty && !_stale) _insert(text.length, text.length, insert);
      // An edit carries the revision of the last report the client read: one sent before it read the newest is
      // dropped, as the TV drops an edit with a stale revision.
      case TextReplace() when _stale:
        return;
      case TextReplace(text: final replacement) when !honoursRanges:
        _insert(cursor, cursor, replacement);
      case TextReplace(:final start, :final end, text: final replacement):
        if (start < end && replacement.isEmpty && start == cursor) return;
        final (from, to) = start < end ? (start, min(end, text.length)) : (cursor, cursor);
        _insert(from, to, replacement);
    }
  }

  void _insert(int from, int to, String typed) {
    final kept = typed.characters.where((c) => !reject.contains(c)).join();
    final next = text.substring(0, from) + kept + text.substring(to);
    final limit = maxLength;
    final limited = limit == null ? next : next.characters.take(limit).string;
    // A change that keeps the length is applied but not reported, as on the emulator.
    if (limited.length == text.length) {
      if (limited != text) silentChanges++;
      text = limited;
      return;
    }
    _report(limited, cursor: min(from + kept.length, limited.length));
  }

  void typeHere() => _report(text + 'xyz'[random.nextInt(3)]);

  void _report(String value, {int? cursor}) {
    text = value;
    this.cursor = cursor ?? value.length;
    _reports.add((text: value, cursor: this.cursor));
    if (random.nextDouble() < late) _held = true;
  }

  void releaseLate() => _held = false;

  /// Whether the client has not read every report yet: an edit it sends now carries a stale revision.
  bool get _stale => _reports.isNotEmpty;
}

const List<String> _alphabet = ['a', 'b', 'c', 'й', '👍🏽', 'é', ' '];

String _randomText(Random random) =>
    List.generate(random.nextInt(12), (_) => _alphabet[random.nextInt(_alphabet.length)]).join();

/// Runs one session: random wants, the TV's faults, then everything delivered. Returns how many changes the TV made
/// without reporting them (a filter or a limit keeping the length), after which the client cannot know its text.
int _run(
  int seed, {
  double loseDel = 0,
  double late = 0,
  Set<String> reject = const {},
  int? maxLength,
  bool honoursRanges = true,
}) {
  final random = Random(seed);
  final tv = _Tv(
    random,
    loseDel: loseDel,
    late: late,
    reject: reject,
    maxLength: maxLength,
    honoursRanges: honoursRanges,
  );
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
      final report = tv.take();
      outcome(sync.report(report.text, cursor: report.cursor));
    } else if (roll < 0.5) {
      tv.releaseLate();
    } else if (sync.waiting) {
      outcome(sync.stalled());
    } else if (wants == 0) {
      tv.releaseLate();
      if (tv.reports.isEmpty) break;
    }
  }
  // A change the TV did not report cannot be known until it reports again; no step may cause one.
  if (tv.silentChanges > 0) return tv.silentChanges;
  expect(sync.tv, tv.text, reason: 'seed $seed: the client knows what the TV shows');
  expect(sync.settled, isTrue, reason: 'seed $seed: wanted ${sync.wanted}, TV ${tv.text}');
  return 0;
}

void main() {
  test('a well-behaved TV ends with the text last wanted, or the one typed on it', () {
    for (var seed = 0; seed < 2000; seed++) {
      expect(_run(seed), 0, reason: 'seed $seed: nothing filters, so every change is reported');
    }
  });

  test('lost Del keys, late reports, filtered characters and a length limit: the two still agree', () {
    for (var seed = 0; seed < 2000; seed++) {
      expect(
        _run(seed, loseDel: 0.1, late: 0.1, reject: const {'й'}, maxLength: 1 + seed % 8),
        0,
        reason: 'seed $seed',
      );
    }
  });

  test('a TV that ignores ranges and loses every Del key: the client gives up and takes its text', () {
    for (var seed = 0; seed < 500; seed++) {
      _run(seed, honoursRanges: false, loseDel: 1);
    }
  });
}
