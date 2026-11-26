// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/voice/chunk_queue.dart';

/// Presses Search and waits up to [timeout] for the TV to open a voice session, then acknowledges it.
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
}) async {
  session
    ..require(TvFeature.voice)
    ..require(TvFeature.key);
  sendKey(session, TvKey.search.code, TvKeyAction.press);
  try {
    final open = await _nextVoiceOpen(session, timeout);
    final voiceId = open.voiceId ?? 0;
    session.send(VoiceOpenMessage(voiceId: voiceId));
    final staleEndsUntil = afterUnconfirmed ? session.clock.elapsed + TvVoiceSession.staleEndWindow : Duration.zero;
    return TvVoiceSession._(session, voiceId, pace: pace, staleEndsUntil: staleEndsUntil);
  } on TvTimeoutException {
    _closeLateOpen(session, within: timeout);
    rethrow;
  }
}

Future<VoiceOpenMessage> _nextVoiceOpen(RemoteSession session, Duration timeout) => session.next(
  session.messagesOf<VoiceOpenMessage>(),
  (_) => true,
  timeout: timeout,
  onTimeout: () => TvTimeoutException('The TV did not open a voice session within $timeout'),
);

/// Closes a voice session the TV opens [within] a timeout after the client stopped waiting.
void _closeLateOpen(RemoteSession session, {required Duration within}) =>
    _nextVoiceOpen(session, within).then((open) => session.send(VoiceCloseMessage(voiceId: open.voiceId))).ignore();

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
final class TvVoiceSession {
  TvVoiceSession._(this._session, this.voiceId, {required bool pace, required Duration staleEndsUntil}) : _pace = pace {
    _session.done.then((reason) => _fail(reason ?? RemoteSession.closedError)).ignore();
    _endedByTv = _session
        .messagesOf<VoiceEndedMessage>()
        .where((ended) => ended.voiceId == voiceId && !_isStaleEnd(staleEndsUntil))
        .listen((_) => _onEndedByTv());
  }

  /// The bytes of one chunk.
  static const int chunkBytes = 20480;

  /// Bytes of audio per second: 8000 samples of 2 bytes.
  static const int bytesPerSecond = 16000;

  /// How much audio [add] buffers before it waits for chunks to go out: ten seconds.
  static const int maxBufferedBytes = 10 * bytesPerSecond;

  /// How long [close] waits for the TV to confirm the end before [done] completes anyway.
  static const Duration endConfirmation = Duration(seconds: 1);

  /// How long after the open an end is taken as a late confirmation of the session before, when that one's close was
  /// not confirmed. Late confirmations came 5 to 12 ms after the open; a recognition ends after audio, much later.
  static const Duration staleEndWindow = Duration(milliseconds: 250);

  static const Duration _chunkDuration = Duration(microseconds: chunkBytes * 1000000 ~/ bytesPerSecond);

  final RemoteSession _session;
  final bool _pace;
  final ChunkQueue _audio = ChunkQueue(chunkBytes);
  final Completer<void> _done = Completer();
  late final StreamSubscription<VoiceEndedMessage> _endedByTv;
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

  /// Sends whole chunks: all of them without pacing, otherwise one now and the next when its time comes. Nothing once
  /// the session ended: the end reaches this voice session through [RemoteSession.done].
  void _pump() {
    while (_sending && !_session.isClosed && _paceTimer == null && _audio.hasChunk) {
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
    if (!_session.isClosed) _session.send(VoiceCloseMessage(voiceId: voiceId));
    _confirmTimer = _session.clock.timer(endConfirmation, _finish);
    _wake();
  }

  /// Whether an end that just came is the late confirmation of the session before: the first one within the window.
  bool _isStaleEnd(Duration until) {
    if (_staleEndSeen || _session.clock.elapsed >= until) return false;
    _staleEndSeen = true;
    return true;
  }

  void _onEndedByTv() {
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
    unawaited(_endedByTv.cancel());
    if (_done.isCompleted) return;
    if (_state == _State.failed) {
      _done.completeError(_error!);
      _done.future.ignore();
    } else {
      _done.complete();
    }
  }
}
