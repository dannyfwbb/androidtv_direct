// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

/// One step toward the wanted text.
@immutable
sealed class TextStep {
  const TextStep();
}

/// One text edit that puts [text] in place of the field's text from [start] to [end], in UTF-16 code units. An empty
/// range inserts at the cursor, wherever it is.
final class TextReplace extends TextStep {
  /// Creates the edit.
  const TextReplace(this.start, this.end, this.text);

  /// Where the replaced text starts.
  final int start;

  /// Where it ends.
  final int end;

  /// What goes in its place.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is TextReplace && other.start == start && other.end == end && other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);

  @override
  String toString() => 'TextReplace($start, $end, "$text")';
}

/// [deletes] Del keys before the cursor (characters as the user sees them: an emoji with a skin tone is one), or
/// [insert] as one edit at the cursor. Never both: Del keys change the field's revision too, so the insert waits for
/// the report that follows them.
final class TextKeys extends TextStep {
  /// Creates the step.
  const TextKeys({this.deletes = 0, this.insert = ''});

  /// How many Del keys.
  final int deletes;

  /// The text to insert at the cursor.
  final String insert;

  /// Whether the step does nothing.
  bool get isEmpty => deletes == 0 && insert.isEmpty;

  @override
  bool operator ==(Object other) => other is TextKeys && other.deletes == deletes && other.insert == insert;

  @override
  int get hashCode => Object.hash(deletes, insert);

  @override
  String toString() => 'TextKeys(-$deletes, +"$insert")';
}

/// What turns [from] into [to] with keys: everything after their common beginning is deleted and typed again.
TextKeys textDifference(String from, String to) {
  final same = _commonCharacters(from, to);
  return TextKeys(deletes: from.characters.length - same, insert: to.characters.skip(same).string);
}

/// The edit that turns [tv] into [wanted] by replacing what follows their common beginning, shaped so the TV applies
/// it and reports it; `null` when they are the same. [cursor] is where the TV last reported the cursor.
///
/// On the emulator an edit replaces its range wherever the cursor is, with three exceptions the edit steers around:
/// an empty range inserts at the cursor (so text added at the end replaces the last character too), an empty
/// replacement that starts at the cursor is ignored (so it takes the character before along, or, at the very start,
/// puts a placeholder the next step removes), and a change that keeps the length is applied but not reported (so it
/// is split: the deletion first, the rest in the next step).
TextReplace? replacementFor(String tv, String wanted, {required int cursor}) {
  if (tv == wanted) return null;
  final same = tv.characters.take(_commonCharacters(tv, wanted)).string.length;
  var start = same;
  if (start == tv.length && start > 0) start = _beforeLast(tv, start);
  var text = wanted.substring(start);
  if (start + text.length == tv.length) text = '';
  if (text.isEmpty && start == cursor) {
    if (start > 0) {
      final kept = start;
      start = _beforeLast(tv, start);
      text = tv.substring(start, kept);
    } else {
      final first = tv.characters.first;
      text = first.length == tv.length ? first + first : first;
    }
  }
  return TextReplace(start, tv.length, text);
}

/// How many characters (as the user sees them) [a] and [b] begin with in common.
int _commonCharacters(String a, String b) {
  final first = a.characters.iterator;
  final second = b.characters.iterator;
  var same = 0;
  while (first.moveNext() && second.moveNext() && first.current == second.current) {
    same++;
  }
  return same;
}

/// Where the last character (as the user sees it) before [end] in [text] starts.
int _beforeLast(String text, int end) => text.substring(0, end).characters.skipLast(1).string.length;

/// What a report or a stall decided: a text the client should take (`adopt`, changed on the TV) and the next step to
/// send (`send`); either may be absent.
typedef SyncOutcome = ({String? adopt, TextStep? send});

const SyncOutcome _nothing = (adopt: null, send: null);

/// Keeps the client's text and the TV's field in step.
///
/// The TV takes an edit only with the field's current revision, which changes with every edit and arrives with the
/// TV's next report of the field; edits sent before that report are dropped. So one step is in flight at a time:
/// what the user types meanwhile waits and goes out as one step after the report. A report while nothing is in
/// flight is a change made on the TV, which the client takes.
///
/// Steps are edits with a range ([replacementFor]), each answered by one report; one that comes back otherwise than
/// planned means the field filtered or limited the text, and the TV's text wins. A TV that does not take ranges (it
/// does not answer such an edit, or inserts it at the cursor) gets keys from then on ([byRange] false): Del keys and
/// inserts at the cursor, which assume the cursor at the end of the field. Del keys go out at most [maxDeletes] per step: a TV flooded with a few hundred
/// keys at once was seen to lose some, and a stalled deletion is planned again from the TV's text.
final class TextSync {
  /// Creates the sync; [maxDeletes] caps the Del keys of one step, and [byRange] starts with edits with a range (the
  /// default) or with keys.
  TextSync({this.maxDeletes = 30, bool byRange = true}) : _byRange = byRange;

  /// The most Del keys one step sends.
  final int maxDeletes;

  /// How often a stalled deletion by Del keys is planned again from the TV's text before the TV's text wins.
  static const int maxReplans = 3;

  /// Whether steps are edits with a range. Turned off for good once one is not answered.
  bool get byRange => _byRange;
  bool _byRange;

  String _tv = '';
  int _cursor = 0;
  String _wanted = '';
  TextStep? _inFlight;
  String? _awaited;

  /// What an edit in flight would make of the field if the TV inserted it at the cursor instead.
  String? _ifInserted;
  int _replans = 0;

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

  /// A field got the focus with [text] and the cursor at [cursor] (default: the end); nothing is in flight.
  void reset(String text, {int? cursor}) {
    _tv = text;
    _cursor = cursor ?? text.length;
    _wanted = text;
    _inFlight = null;
    _awaited = null;
    _replans = 0;
  }

  /// The client wants [text]. Returns the step to send now, or `null` to wait for the TV.
  TextStep? want(String text) {
    _wanted = text;
    return _awaited == null ? _next() : null;
  }

  /// The TV reported its field as [text], with the cursor at [cursor] (default: the end).
  SyncOutcome report(String text, {int? cursor}) {
    _tv = text;
    _cursor = cursor ?? text.length;
    final awaited = _awaited;
    if (awaited == null) return _changedOnTv();
    if (text == awaited) {
      _settle();
      return (adopt: null, send: _next());
    }
    // Del keys are reported one at a time: wait for the last one.
    if (_inFlight is TextKeys) return _nothing;
    // One edit, one report. The TV inserted it at the cursor: it does not take ranges, and keys repair the field.
    final ignoredRange = text == _ifInserted;
    _settle();
    if (ignoredRange) {
      _byRange = false;
      return (adopt: null, send: _next());
    }
    // The field took something else: it filters or limits its text.
    return _changedOnTv();
  }

  /// The awaited report did not come in time. An edit with a range goes again as keys (the TV does not take ranges);
  /// a deletion by Del keys is planned again from the TV's text (a TV may lose keys), up to [maxReplans] times;
  /// otherwise the TV's text wins (the field filters or limits its input). Returns the text the client must take, if
  /// any, and the step to send, if any.
  SyncOutcome stalled() {
    final step = _inFlight;
    _inFlight = null;
    _awaited = null;
    _ifInserted = null;
    if (step is TextReplace && step.start < step.end) {
      _byRange = false;
      return (adopt: null, send: _next());
    }
    if (step is TextKeys && step.deletes > 0 && _replans < maxReplans) {
      _replans++;
      return (adopt: null, send: _next());
    }
    return _changedOnTv();
  }

  void _settle() {
    _inFlight = null;
    _awaited = null;
    _ifInserted = null;
    _replans = 0;
  }

  /// The TV's text is the client's now, if it was not already.
  SyncOutcome _changedOnTv() {
    if (_tv == _wanted) return _nothing;
    _wanted = _tv;
    return (adopt: _tv, send: null);
  }

  TextStep? _next() {
    final step = _byRange ? replacementFor(_tv, _wanted, cursor: _cursor) : _keysStep();
    _inFlight = step;
    _awaited = switch (step) {
      null => null,
      TextReplace(:final start, :final text) => _tv.substring(0, start) + text,
      TextKeys(:final deletes, :final insert) => _tv.characters.skipLast(deletes).string + insert,
    };
    _ifInserted = switch (step) {
      TextReplace(:final start, :final end, :final text) when start < end =>
        _tv.substring(0, _cursor) + text + _tv.substring(_cursor),
      _ => null,
    };
    return step;
  }

  TextKeys? _keysStep() {
    final step = textDifference(_tv, _wanted);
    if (step.isEmpty) return null;
    return step.deletes > 0 ? TextKeys(deletes: min(step.deletes, maxDeletes)) : step;
  }
}
