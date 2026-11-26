// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

/// One step toward the wanted text: [deletes] Del keys at the cursor (characters as the user sees them: an emoji
/// with a skin tone is one), or [insert] as one text edit. Never both: Del keys change the field's revision too, so
/// the insert waits for the report that follows them.
@immutable
final class TextStep {
  /// Creates the step.
  const TextStep({this.deletes = 0, this.insert = ''});

  /// How many Del keys.
  final int deletes;

  /// The text to insert at the cursor.
  final String insert;

  /// Whether the step does nothing.
  bool get isEmpty => deletes == 0 && insert.isEmpty;

  @override
  bool operator ==(Object other) => other is TextStep && other.deletes == deletes && other.insert == insert;

  @override
  int get hashCode => Object.hash(deletes, insert);

  @override
  String toString() => 'TextStep(-$deletes, +"$insert")';
}

/// What turns [from] into [to]: everything after their common beginning is deleted and typed again.
TextStep textDifference(String from, String to) {
  final a = from.characters.toList();
  final b = to.characters.toList();
  var same = 0;
  while (same < a.length && same < b.length && a[same] == b[same]) {
    same++;
  }
  return TextStep(deletes: a.length - same, insert: to.characters.skip(same).string);
}

/// What a report or a stall decided: a text the client should take (`adopt`, changed on the TV) and the next step to
/// send (`send`); either may be absent.
typedef SyncOutcome = ({String? adopt, TextStep? send});

const SyncOutcome _nothing = (adopt: null, send: null);

/// Keeps the client's text and the TV's field in step.
///
/// The TV takes an edit only with the field's current revision, which changes with every edit and arrives with the
/// TV's next report of the field; edits sent before that report are dropped. So one step is in flight at a time:
/// what the user types meanwhile waits and goes out as one step after the report. A report while nothing is in
/// flight is a change made on the TV, which the client takes. When the awaited report never comes, [stalled] plans a
/// deletion again (a key may have been lost) or makes the TV's text the client's (the field filters or limits its
/// text), so the two agree again.
///
/// Del keys go out at most [maxDeletes] per step: a TV flooded with a few hundred keys at once was seen to lose some.
///
/// Assumes the cursor is at the end of the field: Del keys delete before it and inserts land at it.
final class TextSync {
  /// Creates the sync; [maxDeletes] caps the Del keys of one step.
  TextSync({this.maxDeletes = 30});

  /// The most Del keys one step sends.
  final int maxDeletes;

  String _tv = '';
  String _wanted = '';
  String? _awaited;
  bool _deleting = false;
  int _replans = 0;

  /// How often a stalled deletion is planned again from the TV's text before the TV's text wins.
  static const int maxReplans = 3;

  /// The text the client wants.
  @visibleForTesting
  String get wanted => _wanted;

  /// The field's text as the TV last reported it.
  String get tv => _tv;

  /// Whether a step is in flight.
  bool get waiting => _awaited != null;

  /// Whether the TV's field holds the wanted text and nothing is in flight.
  @visibleForTesting
  bool get settled => _awaited == null && _tv == _wanted;

  /// A field got the focus with [text]; nothing is in flight.
  void reset(String text) {
    _tv = text;
    _wanted = text;
    _awaited = null;
    _deleting = false;
    _replans = 0;
  }

  /// The client wants [text]. Returns the step to send now, or `null` to wait for the TV.
  TextStep? want(String text) {
    _wanted = text;
    return _awaited == null ? _next() : null;
  }

  TextStep? _next() {
    final step = textDifference(_tv, _wanted);
    _deleting = step.deletes > 0;
    if (step.isEmpty) return null;
    if (step.deletes > 0) {
      final deletes = min(step.deletes, maxDeletes);
      _awaited = _tv.characters.skipLast(deletes).string;
      return TextStep(deletes: deletes);
    }
    _awaited = _tv + step.insert;
    return step;
  }

  /// The TV reported its field as [text].
  SyncOutcome report(String text) {
    _tv = text;
    final awaited = _awaited;
    if (awaited != null) {
      // Del keys are reported one at a time: wait for the last one.
      if (text != awaited) return _nothing;
      _awaited = null;
      _replans = 0;
      return (adopt: null, send: _next());
    }
    if (text == _wanted) return _nothing;
    _wanted = text;
    return (adopt: text, send: null);
  }

  /// The awaited report did not come in time. A deletion is planned again from the TV's text (a TV may lose keys),
  /// up to [maxReplans] times; otherwise the TV's text wins (the field filters or limits its input). Returns the text
  /// the client must take, if any, and the step to send, if any.
  SyncOutcome stalled() {
    _awaited = null;
    if (_deleting && _replans < maxReplans) {
      _replans++;
      return (adopt: null, send: _next());
    }
    if (_tv == _wanted) return _nothing;
    _wanted = _tv;
    return (adopt: _tv, send: null);
  }
}
