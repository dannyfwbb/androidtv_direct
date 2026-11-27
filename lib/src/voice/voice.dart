// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/voice/chunk_queue.dart';

/// The voice side of a remote session: the one owner of the TV's voice opens and ends.
///
/// Each start presses Search. An open goes to the start waiting for it; one nobody waits for (it came after the
/// start gave up) is closed again, so the TV's voice search does not stay open, unless it is the current session's:
/// a start retried after a timeout takes the late open of the first press, and the open of its own press then has
/// the same id. Every end is placed: the confirmation of the current session's close, the late
/// confirmation of an earlier close (the emulator sends one right after the next open, with the same id), the TV
/// ending the current session, the confirmation of an earlier close while no session is open, or nothing.
final class VoiceChannel extends SessionPart {
  /// Follows [_session]'s voice messages.
  VoiceChannel(this._session) {
    _session.attach(this);
  }

  final RemoteSession _session;
  Completer<TvVoiceSession>? _starting;
  bool _pace = true;
  TvVoiceSession? _current;

  /// The closes this side sent (of sessions, or of opens nobody waited for) the TV has not confirmed yet.
  int _unconfirmedCloses = 0;

  /// Unconfirmed closes whose confirmation may come right after the last open, until [_lateUntil].
  int _lateConfirmations = 0;
  Duration _lateUntil = Duration.zero;

  /// Presses Search and waits for the TV to open a voice session (at least [timeout], longer as long as the TV's
  /// answers have been taking), then acknowledges it.
  ///
  /// Throws [TvNotSupportedException] without [TvFeature.voice] and [TvFeature.key], [StateError] while another voice
  /// session is starting or not [TvVoiceSession.done], [TvTimeoutException] when the TV does not open one in time, and
  /// what ended the session.
  Future<TvVoiceSession> start({required Duration timeout, required bool pace}) async {
    _session
      ..require(TvFeature.voice)
      ..require(TvFeature.key);
    if (_starting != null || _sessionOpen) throw StateError('A voice session is open');
    final starting = _starting = Completer();
    _pace = pace;
    sendKey(_session, TvKey.search.code, TvKeyAction.press);
    final wait = _session.roundTrip.waitFor(timeout);
    try {
      return await _session.clock.deadline(
        starting.future,
        wait,
        () => TvTimeoutException('The TV did not open a voice session within $wait'),
      );
    } finally {
      // Given up on: an open that still comes is nobody's.
      if (identical(_starting, starting)) _starting = null;
    }
  }

  bool get _sessionOpen {
    final current = _current;
    return current != null && !current.isDone;
  }

  @override
  void onMessage(RemoteEnvelope message) {
    // Proto3 leaves out a zero: a missing id is id 0, on both sides.
    switch (message) {
      case VoiceOpenMessage(:final voiceId):
        _onOpen(voiceId ?? 0);
      case VoiceEndedMessage(:final voiceId):
        _onEnded(voiceId ?? 0);
      default:
    }
  }

  @override
  void onEnd(TvRemoteException reason) {
    _starting?.completeError(reason);
    _starting = null;
    _current?._fail(reason);
  }

  void _onOpen(int voiceId) {
    final starting = _starting;
    _starting = null;
    if (starting != null) return _begin(starting, voiceId);
    if (_sessionOpen && voiceId == _current!.voiceId) return;
    _session.send(VoiceCloseMessage(voiceId: voiceId));
    _unconfirmedCloses++;
  }

  void _begin(Completer<TvVoiceSession> starting, int voiceId) {
    _session.send(VoiceOpenMessage(voiceId: voiceId));
    // The closes still unconfirmed may be confirmed right after this open; after the window they are forgotten.
    _lateConfirmations = _unconfirmedCloses;
    _unconfirmedCloses = 0;
    _lateUntil = _session.clock.elapsed + TvVoiceSession.lateConfirmationWindow;
    starting.complete(_current = TvVoiceSession._(this, voiceId, pace: _pace));
  }

  void _onEnded(int voiceId) {
    final current = _sessionOpen && voiceId == _current!.voiceId ? _current! : null;
    if (current != null && current._closing) {
      _unconfirmedCloses = max(0, _unconfirmedCloses - 1);
      current._endedByTv();
    } else if (_isLateConfirmation) {
      _lateConfirmations--;
    } else if (current != null) {
      current._endedByTv();
    } else if (_unconfirmedCloses > 0) {
      _unconfirmedCloses--;
    }
  }

  /// Whether an end that just came confirms, late, a close from before the last open.
  bool get _isLateConfirmation => _lateConfirmations > 0 && _session.clock.elapsed < _lateUntil;

  /// The current session sent its close.
  void _closed() => _unconfirmedCloses++;
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
/// Its remote session's [VoiceChannel] tells it of the TV's end and the end of the remote session as they happen, so
/// nothing is sent for it after either.
final class TvVoiceSession {
  TvVoiceSession._(this._channel, this.voiceId, {required bool pace}) : _session = _channel._session, _pace = pace;

  /// The bytes of one chunk.
  static const int chunkBytes = 20480;

  /// Bytes of audio per second: 8000 samples of 2 bytes.
  static const int bytesPerSecond = 16000;

  /// How much audio [add] buffers before it waits for chunks to go out: ten seconds.
  static const int maxBufferedBytes = 10 * bytesPerSecond;

  /// How long [close] waits at least for the TV to confirm the end before [done] completes anyway; longer as long as
  /// the TV's answers have been taking.
  static const Duration endConfirmation = Duration(seconds: 1);

  /// How long after the open an end is taken as a late confirmation of an earlier close the TV had not confirmed. Late
  /// confirmations came 5 to 12 ms after the open; a recognition ends after audio, much later.
  static const Duration lateConfirmationWindow = Duration(milliseconds: 250);

  static const Duration _chunkDuration = Duration(microseconds: chunkBytes * 1000000 ~/ bytesPerSecond);

  final VoiceChannel _channel;
  final RemoteSession _session;
  final bool _pace;
  final ChunkQueue _audio = ChunkQueue(chunkBytes);
  final Completer<void> _done = Completer();
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

  /// Whether this side sent the close: an end from the TV now confirms it.
  bool get _closing => _state == _State.closed;

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
    _channel._closed();
    _confirmTimer = _session.clock.timer(_session.roundTrip.waitFor(endConfirmation), _finish);
    _wake();
  }

  /// The TV ended the session, or confirmed this side's close.
  void _endedByTv() {
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
    if (_done.isCompleted) return;
    if (_state == _State.failed) {
      _done.completeError(_error!);
      _done.future.ignore();
    } else {
      _done.complete();
    }
  }
}
