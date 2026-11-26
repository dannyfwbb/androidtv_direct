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
/// A session the TV opens just after [timeout] is closed again, so its voice search does not stay open. Throws
/// [TvNotSupportedException] without [TvFeature.voice] and [TvFeature.key], [TvTimeoutException] when the TV does not
/// open one in time, and what ended the session.
Future<TvVoiceSession> startVoiceSession(RemoteSession session, {required Duration timeout, required bool pace}) async {
  session
    ..require(TvFeature.voice)
    ..require(TvFeature.key);
  final opened = Completer<VoiceOpenMessage>();
  final subscription = _onVoiceOpen(session, (open) {
    if (!opened.isCompleted) opened.complete(open);
  });
  final timer = session.clock.timer(timeout, () {
    if (opened.isCompleted) return;
    opened.completeError(TvTimeoutException('The TV did not open a voice session within $timeout'));
    _closeLateOpen(session, after: timeout);
  });
  try {
    sendKey(session, TvKey.search.code, TvKeyAction.press);
    await Future.any([opened.future, session.done]);
    session.throwIfEnded();
    final open = await opened.future;
    final voiceId = open.voiceId ?? 0;
    session.send(VoiceOpenMessage(voiceId: voiceId));
    return TvVoiceSession._(session, voiceId, pace: pace);
  } finally {
    timer.cancel();
    await subscription.cancel();
  }
}

StreamSubscription<ReceivedMessage> _onVoiceOpen(RemoteSession session, void Function(VoiceOpenMessage) handle) =>
    session.messages.listen((received) {
      final message = received.message;
      if (message is VoiceOpenMessage) handle(message);
    });

/// Closes a voice session the TV opens within [after] past a timeout.
void _closeLateOpen(RemoteSession session, {required Duration after}) {
  late final StreamSubscription<ReceivedMessage> late;
  final timer = session.clock.timer(after, () => unawaited(late.cancel()));
  late = _onVoiceOpen(session, (open) {
    timer.cancel();
    unawaited(late.cancel());
    if (!session.isClosed) session.send(VoiceCloseMessage(voiceId: open.voiceId));
  });
}

enum _State { open, closing, ended }

/// A voice session: audio from the app's microphone, sent to the TV's voice search.
///
/// The audio is 16-bit little-endian PCM, mono, 8 kHz. It goes out in chunks of 20 480 bytes (1.28 s), as TVs take
/// it; with pacing (the default) one chunk per 1.28 s, as a microphone delivers audio. [close] sends what is left (the
/// last chunk padded with silence) and ends the session; [cancel] ends it at once. The TV may end it first (its voice
/// search finished or gave up): audio added after that is dropped, and [close] does nothing.
final class TvVoiceSession {
  TvVoiceSession._(this._session, this.voiceId, {required bool pace}) : _pace = pace {
    _session.done.then((reason) => _fail(reason ?? const TvCancelledException('The session was closed'))).ignore();
    _endedByTv = _session.messages.listen((received) {
      final message = received.message;
      if (message is VoiceEndedMessage && message.voiceId == voiceId) _onEndedByTv();
    });
  }

  /// The bytes of one chunk.
  static const int chunkBytes = 20480;

  /// Bytes of audio per second: 8000 samples of 2 bytes.
  static const int bytesPerSecond = 16000;

  /// How much audio [add] buffers before it waits for chunks to go out: ten seconds.
  static const int maxBufferedBytes = 10 * bytesPerSecond;

  /// How long [close] waits for the TV to confirm the end before [done] completes anyway.
  static const Duration endConfirmation = Duration(seconds: 1);

  static const Duration _chunkDuration = Duration(microseconds: chunkBytes * 1000000 ~/ bytesPerSecond);

  final RemoteSession _session;
  final bool _pace;
  final ChunkQueue _audio = ChunkQueue(chunkBytes);
  final Completer<void> _done = Completer();
  late final StreamSubscription<ReceivedMessage> _endedByTv;
  _State _state = _State.open;
  bool _endedByTvFirst = false;
  Object? _error;
  Timer? _paceTimer;
  Timer? _confirmTimer;
  Completer<void>? _room;

  /// The TV's id of this session.
  final int voiceId;

  /// Whether audio can still be added.
  bool get isOpen => _state == _State.open && _error == null;

  /// Whether [done] has completed: the TV can take a new voice session.
  bool get isDone => _done.isCompleted;

  /// Completes once the voice session has ended and the TV can take a new one: after [close] or [cancel] when the TV
  /// confirmed the end (or [endConfirmation] passed), or when the TV ended it. Fails with what ended the remote
  /// session, if that came first.
  Future<void> get done => _done.future;

  /// Adds [pcm] (16-bit little-endian, mono, 8 kHz). Completes once the audio is buffered; waits while more than
  /// [maxBufferedBytes] are waiting to go out. Audio added after the TV ended the session is dropped. Throws
  /// [StateError] after [close] or [cancel], and what ended the remote session.
  Future<void> add(List<int> pcm) async {
    _throwIfFailed();
    if (_endedByTvFirst) return;
    if (_state != _State.open) throw StateError('The voice session was closed');
    _audio.add(pcm);
    _pump();
    while (_audio.length > maxBufferedBytes && _state == _State.open && _error == null) {
      await _waitForRoom();
    }
    _throwIfFailed();
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
    _throwIfFailed();
    if (_state == _State.open) {
      _state = _State.closing;
      _audio.padLast();
      while (_audio.hasChunk && _state == _State.closing && _error == null) {
        _pump();
        if (_audio.hasChunk) await _waitForRoom();
      }
      if (_state == _State.closing) _sendClose();
    }
    await done;
  }

  /// Drops the audio not sent yet and ends the voice session now. Does nothing once it has ended.
  void cancel() {
    if (_state == _State.ended || _error != null) return;
    _audio.clear();
    _sendClose();
  }

  void _throwIfFailed() {
    if (_error != null) throw _error!;
  }

  /// Sends whole chunks: all of them without pacing, otherwise one now and the next when its time comes.
  void _pump() {
    while (_paceTimer == null && _audio.hasChunk && _state != _State.ended && _error == null) {
      _session.send(VoiceAudioMessage(voiceId: voiceId, samples: _audio.take()));
      if (_pace) _paceTimer = _session.clock.timer(_chunkDuration, _onPaced);
    }
    if (_audio.length <= maxBufferedBytes || _state != _State.open) _wake();
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
    _state = _State.ended;
    _paceTimer?.cancel();
    if (!_session.isClosed) _session.send(VoiceCloseMessage(voiceId: voiceId));
    _confirmTimer = _session.clock.timer(endConfirmation, () => _finish(null));
    _wake();
  }

  void _onEndedByTv() {
    if (_state != _State.ended) _endedByTvFirst = true;
    _state = _State.ended;
    _audio.clear();
    _finish(null);
  }

  void _fail(Object error) {
    if (_done.isCompleted) return;
    _error = error;
    _finish(error);
  }

  void _finish(Object? error) {
    _paceTimer?.cancel();
    _confirmTimer?.cancel();
    _wake();
    unawaited(_endedByTv.cancel());
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error);
      _done.future.ignore();
    }
  }
}
