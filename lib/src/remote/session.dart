// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/client_info.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/state.dart';
import 'package:androidtv_direct/src/remote/watchdog.dart';
import 'package:androidtv_direct/src/text/field_tracker.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// Something that follows a session from inside: every message, field change and the end, as the session handles
/// them and before any other code runs. Its state therefore never lags behind the session's: no timer, report or call
/// can come between the session ending and the part knowing it.
abstract class SessionPart {
  /// [message] arrived and the session applied it ([RemoteSession.state] and [RemoteSession.field] are current).
  void onMessage(RemoteEnvelope message) {}

  /// The message just passed to [onMessage] changed the focused field as [event] says.
  void onFieldEvent(FieldEvent event) {}

  /// The session ended: [reason] is what ended it, [RemoteSession.closedError] after `close`. The last call.
  void onEnd(TvRemoteException reason) {}
}

/// A message from the TV with the bytes it arrived as.
typedef ReceivedMessage = ({RemoteEnvelope message, Uint8List bytes});

/// One remote session's protocol: answers the TV's setup, activation and pings, keeps the state its reports give,
/// watches for silence and ends once, with a reason.
final class RemoteSession {
  /// A session over [_socket] that asks for [_wanted] (pings and power are always asked for) and describes the client
  /// as [client].
  RemoteSession(
    this._socket,
    Set<TvFeature> wanted, {
    required TvClock clock,
    required Duration idleTimeout,
    TvClientInfo client = TvClientInfo.standard,
  }) : _wanted = TvFeature.maskOf({...wanted, TvFeature.power}),
       _client = client.toMessage(),
       _clock = clock,
       _idleTimeout = idleTimeout;

  /// What a call after [close] throws.
  static const TvCancelledException closedError = TvCancelledException('The session was closed');

  final TvSocket _socket;
  final int _wanted;
  final DeviceInfo _client;
  final TvClock _clock;
  final Duration _idleTimeout;
  final Completer<void> _ready = Completer();
  final Completer<TvRemoteException?> _done = Completer();
  final StreamController<TvState> _changes = StreamController.broadcast();
  final StreamController<ReceivedMessage> _messages = StreamController.broadcast();
  final List<SessionPart> _parts = [];
  Watchdog? _watchdog;
  bool _heardFromTv = false;

  /// The feature bits agreed in the first setup.
  int? _agreed;
  TvRemoteException? _endReason;
  TvDevice _device = const TvDevice();
  Set<TvFeature> _granted = const {};
  TvState _state = const TvState();

  /// The focused text field, as the TV's reports describe it.
  final FieldTracker field = FieldTracker();

  /// The TV, from its setup.
  TvDevice get device => _device;

  /// The features both sides agreed on.
  Set<TvFeature> get granted => _granted;

  /// The latest state.
  TvState get state => _state;

  /// The session's clock.
  TvClock get clock => _clock;

  /// Every state change.
  Stream<TvState> get changes => _changes.stream;

  /// Makes [part] follow the session until [detach], or until its end, which it is told of.
  void attach(SessionPart part) {
    if (isClosed) return part.onEnd(_endReason ?? closedError);
    _parts.add(part);
  }

  /// Stops telling [part] about the session.
  void detach(SessionPart part) => _parts.remove(part);

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
    throwIfEnded();
    _watchdog = Watchdog(_clock, _idleTimeout, () {
      _end(TvTimeoutException('No message in either direction for $_idleTimeout'));
    });
  }

  /// The first event of [events] that [test] accepts, within [timeout] ([onTimeout] makes the error then). Throws
  /// what ended the session if it ends first.
  Future<T> next<T>(
    Stream<T> events,
    bool Function(T event) test, {
    required Duration timeout,
    required TvRemoteException Function() onTimeout,
  }) {
    final found = Completer<T>();
    final subscription = events.listen((event) {
      if (!found.isCompleted && test(event)) found.complete(event);
    });
    done.then((reason) {
      if (!found.isCompleted) found.completeError(reason ?? closedError);
    }).ignore();
    // The subscription goes when the wait ends, matched, timed out or failed.
    return _clock.deadline(found.future, timeout, onTimeout).whenComplete(subscription.cancel);
  }

  /// Throws [TvNotSupportedException] unless the session has [feature], and what ended the session once it has ended.
  void require(TvFeature feature) {
    throwIfEnded();
    if (_granted.contains(feature)) return;
    throw TvNotSupportedException('The session does not have ${feature.name}', feature: feature);
  }

  /// Throws what ended the session, once it has ended.
  void throwIfEnded() {
    if (isClosed) throw _endReason ?? closedError;
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
      // Features are agreed once: a TV that sends its setup again gets the same answer.
      case SetupMessage(:final features, device: final info) when _agreed == null:
        _device = TvDevice.fromInfo(info);
        final agreed = _agreed = _wanted & (features ?? 0);
        _granted = TvFeature.fromMask(agreed);
        send(SetupMessage(features: agreed, device: _client));
      case SetupMessage():
        send(SetupMessage(features: _agreed, device: _client));
      case ActivateMessage():
        send(ActivateMessage(features: TvFeature.maskOf(_granted)));
      case PingMessage(:final id):
        send(PongMessage(id: id));
      case RefusalMessage():
        _end(_refusalError(message));
      default:
        _report(message);
    }
  }

  void _report(RemoteEnvelope message) {
    final event = field.apply(message);
    final next = _state.apply(message);
    if (!identical(next, _state)) {
      _state = next;
      _changes.add(next);
    }
    // Parts may detach, or end the session, while they are told.
    for (final part in [..._parts]) {
      if (isClosed) return;
      part.onMessage(message);
      if (event != null) part.onFieldEvent(event);
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
    if (!_ready.isCompleted) _ready.completeError(reason ?? closedError);
    _ready.future.ignore();
    final parts = [..._parts];
    _parts.clear();
    for (final part in parts) {
      part.onEnd(reason ?? closedError);
    }
    unawaited(_changes.close());
    unawaited(_messages.close());
    unawaited(_socket.close());
  }
}
