// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/state.dart';
import 'package:androidtv_direct/src/remote/watchdog.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// What the client says about itself in its setup: the values recorded from an existing client of the protocol
/// (Android release `1`, package `atvremote`, version `1.0.0`, field 3 set to 1). What the TV does with them is not
/// known.
final DeviceInfo clientDevice = DeviceInfo(
  androidRelease: '1',
  packageName: 'atvremote',
  serviceVersion: '1.0.0',
  unknownFields: [ProtoField.varint(3, 1)],
);

/// A message from the TV with the bytes it arrived as.
typedef ReceivedMessage = ({RemoteEnvelope message, Uint8List bytes});

/// One remote session's protocol: answers the TV's setup, activation and pings, keeps the state its reports give,
/// watches for silence and ends once, with a reason.
final class RemoteSession {
  /// A session over [_socket] that asks for the feature bits [_wanted].
  RemoteSession(this._socket, {required int wanted, required TvClock clock, required Duration idleTimeout})
    : _wanted = wanted,
      _clock = clock,
      _idleTimeout = idleTimeout;

  final TvSocket _socket;
  final int _wanted;
  final TvClock _clock;
  final Duration _idleTimeout;
  final Completer<void> _ready = Completer();
  final Completer<TvRemoteException?> _done = Completer();
  final StreamController<TvState> _changes = StreamController.broadcast();
  final StreamController<ReceivedMessage> _messages = StreamController.broadcast();
  Watchdog? _watchdog;
  bool _heardFromTv = false;
  TvRemoteException? _endReason;

  /// The TV, from its setup.
  TvDevice device = const TvDevice();

  /// The feature bits both sides agreed on.
  int granted = 0;

  /// The session's clock.
  TvClock get clock => _clock;

  /// Throws [TvNotSupportedException] unless the session has [feature], and what ended the session once it has ended.
  void require(TvFeature feature) {
    throwIfEnded();
    if (granted & feature.bit == 0) {
      throw TvNotSupportedException('The session does not have ${feature.name}', feature: feature.name);
    }
  }

  /// Throws what ended the session, once it has ended.
  void throwIfEnded() {
    if (_done.isCompleted) throw _endReason ?? _closed;
  }

  /// Counts `setVolume` calls, so a newer one can stop an older one.
  int volumeCalls = 0;

  /// The latest state.
  TvState state = const TvState();

  /// Every state change.
  Stream<TvState> get changes => _changes.stream;

  /// Every message from the TV, with its bytes.
  Stream<ReceivedMessage> get messages => _messages.stream;

  /// Completes once: `null` after [close], otherwise why the session ended.
  Future<TvRemoteException?> get done => _done.future;

  /// Whether the session has ended.
  bool get isClosed => _done.isCompleted;

  /// Reads until the TV reported its power state, within [timeout]; then watches for silence.
  ///
  /// Throws what ended the session, or [TvTimeoutException] when the TV does not start it in time. The session is
  /// closed after any failure.
  Future<void> start(Duration timeout) async {
    _socket.listen(_onFrame);
    _socket.done.then(_onSocketEnd).ignore();
    try {
      await _clock.deadline(
        _ready.future,
        timeout,
        () => TvTimeoutException('The TV did not start the session within $timeout'),
      );
    } on TvRemoteException catch (e) {
      _end(e);
      rethrow;
    }
    // The connection may have ended between the power report and this point.
    if (isClosed) throw _endReason ?? _closed;
    _watchdog = Watchdog(_clock, _idleTimeout, () {
      _end(TvTimeoutException('No message in either direction for $_idleTimeout'));
    });
  }

  /// Sends [message]. Throws what ended the session once it has ended.
  void send(RemoteEnvelope message) => sendBytes(message.encodeEnvelope(), kind: message.kind);

  /// Sends an envelope given as bytes. Throws what ended the session once it has ended.
  void sendBytes(Uint8List envelope, {required String kind}) {
    throwIfEnded();
    _watchdog?.touch();
    _socket.send(envelope, kind: kind);
  }

  /// Ends the session from this side; [done] completes with `null`.
  Future<void> close() async {
    _end(null);
    await _socket.close();
  }

  static const TvCancelledException _closed = TvCancelledException('The session was closed');

  void _onFrame(Uint8List bytes) {
    if (isClosed) return;
    _watchdog?.touch();
    _heardFromTv = true;
    final RemoteEnvelope message;
    try {
      message = RemoteEnvelope.fromTv(bytes);
    } on FormatException catch (e) {
      _end(TvProtocolException('The TV sent a malformed message', cause: e));
      return;
    }
    _socket.traceReceived(bytes, kind: message.kind);
    _messages.add((message: message, bytes: bytes));
    _handle(message);
  }

  void _handle(RemoteEnvelope message) {
    switch (message) {
      case SetupMessage(:final features, device: final info):
        device = TvDevice.fromInfo(info);
        granted = _wanted & (features ?? 0);
        send(SetupMessage(features: granted, device: clientDevice));
      case ActivateMessage():
        send(ActivateMessage(features: granted));
      case PingMessage(:final id):
        send(PongMessage(id: id));
      case RefusalMessage():
        _end(_refusalError(message));
      default:
        _report(message);
    }
  }

  void _report(RemoteEnvelope message) {
    final next = state.apply(message);
    if (!identical(next, state)) {
      state = next;
      _changes.add(next);
    }
    if (message is PowerReport && !_ready.isCompleted) _ready.complete();
  }

  static TvRemoteException _refusalError(RefusalMessage refusal) {
    final RemoteEnvelope? refused;
    try {
      refused = refusal.refusedMessage;
    } on FormatException catch (e) {
      return TvProtocolException('The TV refused a message (code ${refusal.code})', cause: e);
    }
    if (refused is OpenLinkMessage) {
      return TvLinkRefusedException(
        'The TV refused the link ${refused.link}',
        link: refused.link ?? '',
        refusalCode: refusal.code,
      );
    }
    return TvProtocolException('The TV refused ${refused?.kind ?? 'a message'} (code ${refusal.code})');
  }

  void _onSocketEnd(TvRemoteException? reason) {
    if (reason == null) return _end(null);
    _end(_heardFromTv ? reason : _beforeFirstMessage(reason));
  }

  /// A TV that does not know the client's certificate ends the connection before its first message, with a TLS alert
  /// or a clean close. A reset or another network error is not that.
  static TvRemoteException _beforeFirstMessage(TvRemoteException reason) {
    if (reason is! TvClosedException) return reason;
    final cause = reason.cause;
    if (cause != null && cause is! TlsException) return reason;
    return TvNotPairedException('The TV refused this client: it is not paired', cause: reason);
  }

  void _end(TvRemoteException? reason) {
    if (_done.isCompleted) return;
    _endReason = reason;
    _watchdog?.cancel();
    _done.complete(reason);
    if (!_ready.isCompleted) _ready.completeError(reason ?? _closed);
    _ready.future.ignore();
    unawaited(_changes.close());
    unawaited(_messages.close());
    unawaited(_socket.close());
  }
}
