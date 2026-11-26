// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:androidtv_direct/src/clock.dart';
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

/// The next edit toward [wanted] from [tv], shaped so the TV applies it and reports it; `null` when they are the same.
///
/// What follows the common beginning is deleted first ([_deletion]); the rest is added in a later step. The two never
/// go in one edit: the TV reports a change only when the length changes, and a replacement a field cuts or filters
/// could come out at the old length but with another text, which the client would never hear of. Added text goes
/// with the character before it (an empty range would insert at the cursor, wherever that is), so a field that cuts
/// it keeps its old text at worst. An edit replaces its range wherever the cursor is, so the cursor the TV reports,
/// which it does not keep up to date, matters only for emptying the field ([cursorAtStart]).
TextReplace? replacementFor(String tv, String wanted, {bool cursorAtStart = false}) {
  if (tv == wanted) return null;
  final same = tv.characters.take(_commonCharacters(tv, wanted)).string.length;
  if (same < tv.length) return _deletion(tv, same, cursorAtStart: cursorAtStart);
  if (tv.isEmpty) return TextReplace(0, 0, wanted);
  final start = _beforeLast(tv, same);
  return TextReplace(start, tv.length, wanted.substring(start));
}

/// Deletes from [start] to the end with an edit the TV cannot ignore: it puts back the character before [start], so
/// its text is never empty. At the very start there is none: the field is emptied with an empty edit, unless
/// [cursorAtStart] says the TV would ignore that, and then it gets a placeholder of another length first.
TextReplace _deletion(String tv, int start, {required bool cursorAtStart}) {
  if (start > 0) {
    final from = _beforeLast(tv, start);
    return TextReplace(from, tv.length, tv.substring(from, start));
  }
  if (!cursorAtStart) return TextReplace(0, tv.length, '');
  final first = tv.characters.first;
  return TextReplace(0, tv.length, first.length == tv.length ? first + first : first);
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
/// Steps are edits with a range ([replacementFor]), each answered by one report. One that comes back otherwise than
/// planned, or not at all in time (the constructor's `wait`), means the field filtered or limited the text: the TV's text wins. A step
/// given up on may still arrive (a network slower than the wait): if it does while the next is in flight, that one
/// went with a stale revision, which the TV drops, and it is planned again. Emptying the field is the one step the
/// cursor's place can spoil (an empty edit at the cursor is ignored): when the TV reports the cursor at the start, or
/// the emptying stalls, it goes again with a placeholder first.
///
/// A TV that inserts an edit with a range at the cursor does not take ranges, and gets keys from then on ([byRange]
/// false): Del keys and inserts at the cursor, which assume the cursor at the end. Del keys go out at most
/// [maxDeletes] per step, since a TV flooded with a few hundred keys at once was seen to lose some, and are reported
/// one at a time. Keys carry no revision, so a batch is never sent twice while it may still land: a deletion always
/// changes the length, so the TV always reports it, and a batch with no report yet is waited for up to
/// [keysHorizon]; one whose reports stopped partway lost the keys after the last report, and the rest is planned
/// again from the TV's text.
///
/// [deadline] tells when [stalled] is due; [answerTime] how long the TV took to answer a step, for the session's
/// round-trip estimate.
final class TextSync {
  /// Creates the sync. [now] tells the time; [wait] how long to wait for an answer (the session's round trip, with
  /// its floor); [maxDeletes] caps the Del keys of one step, and [byRange] starts with edits with a range (the default)
  /// or with keys.
  TextSync({
    required Duration Function() now,
    required Duration Function() wait,
    this.maxDeletes = 30,
    this.keysHorizon = const Duration(seconds: 10),
    bool byRange = true,
  }) : _now = now,
       _wait = wait,
       _byRange = byRange;

  /// The most Del keys one step sends.
  final int maxDeletes;

  /// How long a batch of Del keys with no report yet is waited for before the TV's text wins: it may be on its way.
  final Duration keysHorizon;

  /// How often a deletion by Del keys whose reports stopped is planned again from the TV's text before the TV's text
  /// wins.
  static const int maxReplans = 3;

  final Duration Function() _now;
  final Duration Function() _wait;

  /// Whether steps are edits with a range. Turned off for good once the TV inserted one at the cursor.
  bool get byRange => _byRange;
  bool _byRange;

  String _tv = '';
  int _cursor = 0;
  String _wanted = '';
  _Flight? _flight;

  /// The last edit given up on: it may still arrive.
  ({String awaited, Duration sentAt})? _late;

  /// Whether the TV last reported the cursor at the start, or an emptying of the field stalled.
  bool _cursorAtStart = false;

  /// Whether the last step was a placeholder: the next emptying goes without one, whatever the cursor.
  bool _placeholder = false;
  bool _emptyingRetried = false;

  /// How often the deletion in flight was planned again after its keys were lost.
  int _replans = 0;

  /// How long the TV took to answer a step, if the last report answered one (late answers included); `null`
  /// otherwise.
  Duration? get answerTime => _answerTime;
  Duration? _answerTime;

  /// The text the client wants.
  @visibleForTesting
  String get wanted => _wanted;

  /// The field's text as the TV last reported it.
  String get tv => _tv;

  /// Whether a step is in flight.
  bool get waiting => _flight != null;

  /// When [stalled] is due, while a step is in flight: the wait counts from the step, or for Del keys from the last
  /// one reported.
  Duration? get deadline {
    final flight = _flight;
    if (flight == null) return null;
    if (flight.deletes > 0 && flight.keyReports == 0) return flight.sentAt + longer(_wait(), keysHorizon);
    return flight.progressAt + _wait();
  }

  /// Whether the TV's field holds the wanted text and nothing is in flight.
  @visibleForTesting
  bool get settled => _flight == null && _tv == _wanted;

  /// A field got the focus with [text] and the cursor at [cursor] (default: the end); nothing is in flight.
  void reset(String text, {int? cursor}) {
    _take(text, cursor);
    _wanted = text;
    _flight = null;
    _replans = 0;
  }

  /// The client wants [text]. Returns the step to send now, or `null` to wait for the TV.
  TextStep? want(String text) {
    _wanted = text;
    _emptyingRetried = false;
    return _flight == null ? _next() : null;
  }

  /// The TV reported its field as [text], with the cursor at [cursor] (default: the end).
  SyncOutcome report(String text, {int? cursor}) {
    _take(text, cursor);
    _answerTime = null;
    // After the next report, an edit given up on can no longer be told from a change made on the TV.
    final late = _late;
    _late = null;
    final arrivedLate = late != null && text == late.awaited;
    if (arrivedLate) _answerTime = _now() - late.sentAt;
    final flight = _flight;
    if (flight == null) return _changedOnTv();
    if (text == flight.awaited) {
      _answered(flight);
      _land();
      return (adopt: null, send: _next());
    }
    if (flight.deletes > 0) return _keyReport(flight, text);
    // The edit given up on arrived late. The edit in flight carried the field's revision from before it, and the TV
    // drops such an edit: plan again from the TV's text.
    if (arrivedLate) {
      _land();
      return (adopt: null, send: _next());
    }
    // One edit, one report. The TV inserted it at the cursor: it does not take ranges, and keys repair the field.
    if (text == flight.ifInserted) {
      _answered(flight);
      _land();
      _byRange = false;
      return (adopt: null, send: _next());
    }
    // The field took something else: it filters or limits its text.
    _land();
    return _changedOnTv();
  }

  /// A report while Del keys are in flight: one key more deleted is progress; anything else (the cursor reported,
  /// a change made on the TV) is not, and the keys may still land.
  SyncOutcome _keyReport(_Flight flight, String text) {
    if (!flight.isProgress(text)) return _nothing;
    if (flight.keyReports++ == 0) _answered(flight);
    flight.progressAt = _now();
    return _nothing;
  }

  /// The wait for the step in flight ran out ([deadline]). An emptying of the field goes again once, with a
  /// placeholder first (the cursor was at the start); Del keys whose reports stopped partway lost the rest, which is
  /// planned again from the TV's text, up to [maxReplans] times; otherwise the TV's text wins (the field filtered or
  /// limited the text, keeping its length, or the step is too late to wait for). Returns the text the client must
  /// take, if any, and the step to send, if any.
  SyncOutcome stalled() {
    final flight = _flight;
    if (flight == null) return _nothing;
    _flight = null;
    if (flight.step case TextReplace(start: 0, text: '') when !_emptyingRetried) {
      _emptyingRetried = true;
      _cursorAtStart = true;
      return (adopt: null, send: _next());
    }
    if (flight.deletes > 0 && flight.keyReports > 0 && _replans < maxReplans) {
      _replans++;
      return (adopt: null, send: _next());
    }
    if (flight.deletes == 0) _late = (awaited: flight.awaited, sentAt: flight.sentAt);
    _replans = 0;
    return _changedOnTv();
  }

  void _take(String text, int? cursor) {
    _tv = text;
    _cursor = cursor ?? text.length;
    _cursorAtStart = _cursor == 0 && text.isNotEmpty;
  }

  /// The step in flight came back as planned or otherwise: nothing is in flight now.
  void _land() {
    _flight = null;
    _replans = 0;
  }

  /// The report answers [flight], the first time: its time is the answer's.
  void _answered(_Flight flight) {
    if (flight.answered) return;
    flight.answered = true;
    _answerTime = _now() - flight.sentAt;
  }

  /// The TV's text is the client's now, if it was not already.
  SyncOutcome _changedOnTv() {
    if (_tv == _wanted) return _nothing;
    _wanted = _tv;
    return (adopt: _tv, send: null);
  }

  TextStep? _next() {
    final step = _byRange ? _rangeStep() : _keysStep();
    if (step == null) return null;
    _flight = _Flight(
      step,
      from: _tv,
      awaited: switch (step) {
        TextReplace(:final start, :final text) => _tv.substring(0, start) + text,
        TextKeys(:final deletes, :final insert) => _tv.characters.skipLast(deletes).string + insert,
      },
      ifInserted: switch (step) {
        TextReplace(:final start, :final end, :final text) when start < end =>
          _tv.substring(0, _cursor) + text + _tv.substring(_cursor),
        _ => null,
      },
      sentAt: _now(),
    );
    return step;
  }

  TextReplace? _rangeStep() {
    final step = replacementFor(_tv, _wanted, cursorAtStart: _cursorAtStart && !_placeholder);
    // A placeholder is the only step at the start whose text is not the wanted one.
    _placeholder = step != null && step.start == 0 && step.text.isNotEmpty && step.text != _wanted;
    return step;
  }

  TextKeys? _keysStep() {
    final step = textDifference(_tv, _wanted);
    if (step.isEmpty) return null;
    return step.deletes > 0 ? TextKeys(deletes: min(step.deletes, maxDeletes)) : step;
  }
}

/// A step sent to the TV, until a report answers it or the wait for one runs out.
final class _Flight {
  _Flight(this.step, {required this.from, required this.awaited, required this.ifInserted, required this.sentAt})
    : progressAt = sentAt;

  final TextStep step;

  /// The TV's text when the step went out.
  final String from;

  /// What the step makes of the field.
  final String awaited;

  /// What an edit with a range would make of the field if the TV inserted it at the cursor instead.
  final String? ifInserted;

  final Duration sentAt;

  /// When it last showed progress: sent, or one of its Del keys reported.
  Duration progressAt;

  /// The reports of its Del keys so far.
  int keyReports = 0;

  /// Whether a report answered it already (its time was measured).
  bool answered = false;

  int get deletes => switch (step) {
    TextKeys(:final deletes) => deletes,
    TextReplace() => 0,
  };

  /// Whether [text] is the field with some of its Del keys applied: [from] with 1 to [deletes] − 1 characters (as
  /// the user sees them) removed from the end.
  bool isProgress(String text) {
    final kept = text.characters.length;
    final removed = from.characters.length - kept;
    return removed > 0 && removed < deletes && from.characters.take(kept).string == text;
  }
}
