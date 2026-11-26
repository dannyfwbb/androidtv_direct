// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/voice/chunk_queue.dart';

/// Presses Search and waits for the TV to open a voice session (at least [timeout], longer as long as the TV's answers
/// have been taking), then acknowledges it.
///
/// With [afterUnconfirmed] (the last session's close was never confirmed), the first end the TV sends within
/// [TvVoiceSession.staleEndWindow] of the open is taken as that confirmation, arriving late, and not as the end of the
/// new session: the emulator sends one so when Search comes soon after such a close, and both sessions share an id.
///
/// A session the TV opens just after [timeout] is closed again, so its voice search does not stay open. Throws
/// [TvNotSupportedException] without [TvFeature.voice] and [TvFeature.key], [TvTimeoutException] when the TV does not
/// open one in time, and what ended the session.
Future<TvVoiceSession> startVoiceSession(
  RemoteSession session, {
  required Duration timeout,
  required bool pace,
  bool afterUnconfirmed = false,
}) {
  session
    ..require(TvFeature.voice)
    ..require(TvFeature.key);
  return _VoiceStart(session, pace: pace, afterUnconfirmed: afterUnconfirmed).run(timeout);
}

/// Search pressed, the TV's open awaited. A part of the session, so the voice session it makes at the open follows
/// the messages right after it (an end can come in the same read).
final class _VoiceStart extends SessionPart {
  _VoiceStart(this._session, {required this.pace, required this.afterUnconfirmed});

  final RemoteSession _session;
  final bool pace;
  final bool afterUnconfirmed;
  final Completer<TvVoiceSession> _opened = Completer();

  /// Whether the wait is over: an open now comes too late and is closed again.
  bool _late = false;

  /// When Search went out: the open answers it.
  late final Duration _pressedAt;

  /// Waits at least [timeout] for the open; longer as long as the TV's answers have been taking.
  Future<TvVoiceSession> run(Duration timeout) async {
    _session.attach(this);
    sendKey(_session, TvKey.search.code, TvKeyAction.press);
    _pressedAt = _session.clock.elapsed;
    final wait = _session.roundTrip.waitFor(timeout);
    try {
      return await _session.clock.deadline(
        _opened.future,
        wait,
        () => TvTimeoutException('The TV did not open a voice session within $wait'),
      );
    } on TvTimeoutException {
      _late = true;
      _session.clock.timer(wait, () => _session.detach(this));
      rethrow;
    }
  }

  @override
  void onMessage(RemoteEnvelope message) {
    if (message is! VoiceOpenMessage) return;
    _session.detach(this);
    // Late or not, the open answers Search, which went out once.
    _session.roundTrip.add(_session.clock.elapsed - _pressedAt);
    final voiceId = message.voiceId ?? 0;
    if (_late) return _session.send(VoiceCloseMessage(voiceId: voiceId));
    _session.send(VoiceOpenMessage(voiceId: voiceId));
    final staleEndsUntil = afterUnconfirmed ? _session.clock.elapsed + TvVoiceSession.staleEndWindow : Duration.zero;
    _opened.complete(TvVoiceSession._(_session, voiceId, pace: pace, staleEndsUntil: staleEndsUntil));
  }

  @override
  void onEnd(TvRemoteException reason) {
    if (!_late) _opened.completeError(reason);
  }
}

enum _State {
  /// Audio is taken.
  open,

  /// [TvVoiceSession.close] is sending what is left.
  closing,

  /// This side ended the session.
  closed,

  /// The TV ended the session first.
  endedByTv,

  /// The remote session ended.
  failed,
}

/// A voice session: audio from the app's microphone, sent to the TV's voice search.
///
/// The audio is 16-bit little-endian PCM, mono, 8 kHz. It goes out in chunks of 20 480 bytes (1.28 s), as TVs take
/// it; with pacing (the default) one chunk per 1.28 s, as a microphone delivers audio. [close] sends what is left (the
/// last chunk padded with silence) and ends the session; [cancel] ends it at once. The TV may end it first (its voice
/// search finished or gave up): audio added after that is dropped, and [close] does nothing.
///
/// It is a part of the remote session ([SessionPart]): the TV's end and the end of the remote session reach it as they
/// happen, so nothing is sent for it after either.
final class TvVoiceSession extends SessionPart {
  TvVoiceSession._(this._session, this.voiceId, {required bool pace, required Duration staleEndsUntil})
    : _pace = pace,
      _staleEndsUntil = staleEndsUntil {
    _session.attach(this);
  }

  /// The bytes of one chunk.
  static const int chunkBytes = 20480;

  /// Bytes of audio per second: 8000 samples of 2 bytes.
  static const int bytesPerSecond = 16000;

  /// How much audio [add] buffers before it waits for chunks to go out: ten seconds.
  static const int maxBufferedBytes = 10 * bytesPerSecond;

  /// How long [close] waits at least for the TV to confirm the end before [done] completes anyway; longer as long as
  /// the TV's answers have been taking.
  static const Duration endConfirmation = Duration(seconds: 1);

  /// How long after the open an end is taken as a late confirmation of the session before, when that one's close was
  /// not confirmed. Late confirmations came 5 to 12 ms after the open; a recognition ends after audio, much later.
  static const Duration staleEndWindow = Duration(milliseconds: 250);

  static const Duration _chunkDuration = Duration(microseconds: chunkBytes * 1000000 ~/ bytesPerSecond);

  final RemoteSession _session;
  final bool _pace;
  final ChunkQueue _audio = ChunkQueue(chunkBytes);
  final Completer<void> _done = Completer();
  final Duration _staleEndsUntil;
  bool _staleEndSeen = false;
  _State _state = _State.open;
  Object? _error;
  Timer? _paceTimer;
  Timer? _confirmTimer;
  Completer<void>? _room;

  /// The TV's id of this session.
  final int voiceId;

  /// Whether audio can still be added.
  bool get isOpen => _state == _State.open;

  /// Whether [done] has completed: the TV can take a new voice session.
  bool get isDone => _done.isCompleted;

  /// Whether the TV sent its end of this session (by itself, or confirming a close).
  bool get endConfirmed => _endConfirmed;
  bool _endConfirmed = false;

  /// Completes once the voice session has ended and the TV can take a new one: after [close] or [cancel] when the TV
  /// confirmed the end (or [endConfirmation] passed), or when the TV ended it. Fails with what ended the remote
  /// session, if that came first.
  Future<void> get done => _done.future;

  bool get _sending => _state == _State.open || _state == _State.closing;

  /// Adds [pcm] (16-bit little-endian, mono, 8 kHz). Completes once the audio is buffered; waits while more than
  /// [maxBufferedBytes] are waiting to go out. Audio added after the TV ended the session is dropped. Throws
  /// [StateError] after [close] or [cancel], and what ended the remote session.
  Future<void> add(List<int> pcm) async {
    switch (_state) {
      case _State.failed:
        throw _error!;
      case _State.endedByTv:
        return;
      case _State.closing || _State.closed:
        throw StateError('The voice session was closed');
      case _State.open:
        _audio.add(pcm);
        _pump();
        while (_state == _State.open && _audio.length > maxBufferedBytes) {
          await _waitForRoom();
        }
        if (_state == _State.failed) throw _error!;
    }
  }

  /// Adds every chunk of [audio], in order.
  Future<void> addStream(Stream<List<int>> audio) async {
    await for (final pcm in audio) {
      await add(pcm);
    }
  }

  /// Sends the audio left, the last chunk padded with silence, ends the session and waits for [done]. Does nothing
  /// more once the session is ending or has ended. Throws what ended the remote session if it ends first.
  Future<void> close() async {
    if (_state == _State.open) {
      await _sendRest();
      // Only the call that started closing ends the session, once the rest is out.
      if (_state == _State.closing) _sendClose();
    }
    await done;
  }

  /// Drops the audio not sent yet and ends the voice session now. Does nothing once it has ended.
  void cancel() {
    if (!_sending) return;
    _audio.clear();
    _sendClose();
  }

  Future<void> _sendRest() async {
    _state = _State.closing;
    _audio.padLast();
    while (_state == _State.closing && _audio.hasChunk) {
      _pump();
      if (_audio.hasChunk) await _waitForRoom();
    }
  }

  /// Sends whole chunks: all of them without pacing, otherwise one now and the next when its time comes.
  void _pump() {
    while (_sending && _paceTimer == null && _audio.hasChunk) {
      _session.send(VoiceAudioMessage(voiceId: voiceId, samples: _audio.take()));
      if (_pace) _paceTimer = _session.clock.timer(_chunkDuration, _onPaced);
    }
    if (_state != _State.open || _audio.length <= maxBufferedBytes) _wake();
  }

  void _onPaced() {
    _paceTimer = null;
    _pump();
  }

  Future<void> _waitForRoom() => (_room ??= Completer<void>()).future;

  void _wake() {
    final room = _room;
    _room = null;
    room?.complete();
  }

  void _sendClose() {
    _state = _State.closed;
    _paceTimer?.cancel();
    _session.send(VoiceCloseMessage(voiceId: voiceId));
    _closedAt = _session.clock.elapsed;
    _confirmTimer = _session.clock.timer(_session.roundTrip.waitFor(endConfirmation), _finish);
    _wake();
  }

  /// When the close went out: the TV's end, if it comes, answers it.
  Duration? _closedAt;

  @override
  void onMessage(RemoteEnvelope message) {
    if (message case VoiceEndedMessage(:final voiceId) when voiceId == this.voiceId && !_isStaleEnd()) _onEndedByTv();
  }

  @override
  void onEnd(TvRemoteException reason) => _fail(reason);

  /// Whether an end that just came is the late confirmation of the session before: the first one within the window.
  bool _isStaleEnd() {
    if (_staleEndSeen || _session.clock.elapsed >= _staleEndsUntil) return false;
    _staleEndSeen = true;
    return true;
  }

  void _onEndedByTv() {
    if (_closedAt case final closedAt?) _session.roundTrip.add(_session.clock.elapsed - closedAt);
    _endConfirmed = true;
    if (_sending) _state = _State.endedByTv;
    _audio.clear();
    _finish();
  }

  void _fail(Object error) {
    if (_done.isCompleted) return;
    _state = _State.failed;
    _error = error;
    _finish();
  }

  void _finish() {
    _paceTimer?.cancel();
    _confirmTimer?.cancel();
    _wake();
    _session.detach(this);
    if (_done.isCompleted) return;
    if (_state == _State.failed) {
      _done.completeError(_error!);
      _done.future.ignore();
    } else {
      _done.complete();
    }
  }
}
