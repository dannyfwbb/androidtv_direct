// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:androidtv_direct/src/protocol/frame.dart';
import 'package:androidtv_direct/src/trace.dart';

/// A TLS connection to one of the TV's ports, read and written in frames.
///
/// The TV's certificate is accepted whatever it is ([peerCertificate] keeps it): it is self-signed, and checking it
/// is the caller's job (by fingerprint). Frames arrive in order through [receive]; once the connection ends, every
/// pending and later [receive] fails with the same error.
final class TvSocket {
  TvSocket._(this._socket, this.port, this._clock, this._tracer) {
    _subscription = _socket.listen(
      _onData,
      onError: _onError,
      onDone: () => _end(const TvClosedException('The TV closed the connection')),
    );
    // Write errors surface as read errors or the end of the stream.
    _socket.done.ignore();
  }

  /// Opens a TLS connection to [host]:[port] presenting [context]'s certificate: TCP within [timeout], then the TLS
  /// handshake within [timeout] again.
  ///
  /// Throws [TvNoServiceException] when nothing listens on the port, [TvUnreachableException] when the address does
  /// not answer in time or has no route, [TvTimeoutException] when the TV accepts the connection but does not finish
  /// the handshake (a TV busy with another pairing does that), [TvProtocolException] when the handshake fails, and
  /// [TvCancelledException] when [cancelOn] completes first.
  ///
  /// With [pin], the TV's key must have that fingerprint (see `spkiFingerprint`), or the connection fails with
  /// [TvWrongTvException]. The check runs inside the TLS handshake, which is aborted on a mismatch before the client's
  /// certificate goes out; it is repeated once the handshake is done. No message is sent either way.
  static Future<TvSocket> connect(
    Object host,
    int port, {
    required SecurityContext context,
    required Duration timeout,
    String? pin,
    TvClock clock = TvClock.system,
    TvTracer? tracer,
    Future<void>? cancelOn,
  }) async {
    final attempt = _Attempt('$host:$port', clock, timeout, pin);
    cancelOn?.whenComplete(attempt.cancel).ignore();
    final socket = TvSocket._(await attempt.open(host, port, context), port, clock, tracer);
    return socket.._note('connected to ${attempt.target}');
  }

  final SecureSocket _socket;
  final TvClock _clock;
  final TvTracer? _tracer;
  late final StreamSubscription<Uint8List> _subscription;
  final FrameReader _reader = FrameReader();
  final Queue<Uint8List> _frames = Queue();
  final Completer<TvRemoteException?> _ended = Completer();
  Completer<void>? _arrival;
  void Function(Uint8List frame)? _onFrame;

  /// The TV's port.
  final int port;

  /// The certificate the TV presented.
  X509Certificate? get peerCertificate => _socket.peerCertificate;

  /// What the TV's certificate says. Throws [TvProtocolException] if the TV presented none, or one this package
  /// cannot use (not RSA, malformed).
  TvIdentity get tvIdentity {
    final certificate = peerCertificate ?? (throw TvProtocolException('Port $port presented no certificate'));
    try {
      return TvIdentity.fromCertificate(certificate.der);
    } on FormatException catch (e) {
      throw TvProtocolException('The certificate on port $port is not usable', cause: e);
    }
  }

  /// Completes when the connection has ended: with `null` when this side closed it, otherwise with why it ended.
  Future<TvRemoteException?> get done => _ended.future;

  /// Whether the connection has ended.
  bool get isClosed => _ended.isCompleted;

  /// Sends [body] as one frame; [kind] names it in traces.
  void send(Uint8List body, {required String kind}) {
    if (isClosed) return;
    _traceMessage(outgoing: true, kind: kind, body: body);
    _socket.add(encodeFrame(body));
  }

  /// The next frame, within [timeout].
  ///
  /// Throws [TvTimeoutException] when none arrives in time, the error that ended the connection when the TV ended it
  /// first (see [done]), and [TvCancelledException] once this side closed it. Only one call may wait at a time.
  Future<Uint8List> receive({required Duration timeout}) async {
    if (_arrival != null) throw StateError('Only one receive at a time');
    if (_onFrame != null) throw StateError('Frames go to the listener');
    if (_frames.isEmpty && !isClosed) await _waitForFrame(timeout);
    if (_frames.isNotEmpty) return _frames.removeFirst();
    throw await _ended.future ?? const TvCancelledException('The connection was closed from this side');
  }

  /// Hands every frame, the ones already received first, to [onFrame] from now on, as it arrives. [receive] cannot be
  /// used afterwards; [done] still tells when the connection ends.
  void listen(void Function(Uint8List frame) onFrame) {
    if (_arrival != null) throw StateError('A receive is waiting');
    _onFrame = onFrame;
    while (_frames.isNotEmpty && !isClosed) {
      onFrame(_frames.removeFirst());
    }
  }

  /// Records a frame [receive] returned once the caller has decoded it, under [kind].
  void traceReceived(Uint8List body, {required String kind}) => _traceMessage(outgoing: false, kind: kind, body: body);

  /// Closes the connection from this side; [done] completes with `null`.
  Future<void> close() async {
    _end(null);
    await _subscription.cancel();
    try {
      await _socket.close();
    } on IOException {
      // Already broken; destroy below.
    }
    _socket.destroy();
  }

  Future<void> _waitForFrame(Duration timeout) async {
    final arrival = _arrival = Completer();
    var timedOut = false;
    final timer = _clock.timer(timeout, () {
      timedOut = true;
      if (!arrival.isCompleted) arrival.complete();
    });
    try {
      await Future.any([arrival.future, _ended.future]);
    } finally {
      timer.cancel();
      _arrival = null;
    }
    if (timedOut && _frames.isEmpty) throw TvTimeoutException('No message from port $port within $timeout');
  }

  void _onData(Uint8List chunk) {
    final List<Uint8List> frames;
    try {
      frames = _reader.add(chunk);
    } on FormatException catch (e) {
      _end(TvProtocolException('The TV sent a malformed frame', cause: e));
      _socket.destroy();
      return;
    }
    final onFrame = _onFrame;
    if (onFrame == null) {
      _frames.addAll(frames);
      if (_frames.isNotEmpty) _wake();
      return;
    }
    for (final frame in frames) {
      if (isClosed) return;
      onFrame(frame);
    }
  }

  void _onError(Object error) => _end(TvClosedException('The connection to port $port failed', cause: error));

  void _end(TvRemoteException? error) {
    if (_ended.isCompleted) return;
    _note(error == null ? 'closed' : 'ended: ${error.message}');
    _ended.complete(error);
    _wake();
  }

  void _wake() {
    final arrival = _arrival;
    if (arrival != null && !arrival.isCompleted) arrival.complete();
  }

  void _traceMessage({required bool outgoing, required String kind, required Uint8List body}) {
    final tracer = _tracer;
    if (tracer == null) return;
    tracer.onEvent(
      TvMessageTrace(
        at: _clock.elapsed,
        outgoing: outgoing,
        port: port,
        kind: kind,
        length: body.length,
        raw: tracer.includesRaw ? body : null,
      ),
    );
  }

  void _note(String message) => _tracer?.onEvent(TvNoteTrace(at: _clock.elapsed, message: 'port $port: $message'));

  static TvRemoteException _connectError(SocketException e, String target) {
    final code = e.osError?.errorCode;
    if (code != null && _refusedCodes.contains(code)) {
      return TvNoServiceException('$target refused the connection: no remote service listens there', cause: e);
    }
    return TvUnreachableException('Could not reach $target', cause: e);
  }

  // ECONNREFUSED on Linux and Android (111), macOS and iOS (61); on Windows WSAECONNREFUSED (10061) and
  // ERROR_CONNECTION_REFUSED (1225), which dart:io reports for an asynchronous connect.
  static const Set<int> _refusedCodes = {111, 61, 10061, 1225};
}

/// One connection attempt: its two stages, their deadlines and its cancellation.
final class _Attempt {
  _Attempt(this.target, this.clock, this.timeout, this.pin);

  final String target;
  final TvClock clock;
  final Duration timeout;
  final String? pin;
  String? _presented;
  bool _mismatch = false;
  bool _cancelled = false;
  bool _opened = false;
  ConnectionTask<Socket>? _task;
  Socket? _socket;

  /// Stops the attempt; does nothing once [open] has returned (the caller owns the socket then).
  void cancel() {
    if (_opened) return;
    _cancelled = true;
    _task?.cancel();
    _socket?.destroy();
  }

  TvCancelledException _cancelledError([Object? cause]) =>
      TvCancelledException('The connection to $target was cancelled', cause: cause);

  /// TCP, then TLS over it: the TLS socket owns the plain one.
  Future<SecureSocket> open(Object host, int port, SecurityContext context) async {
    final socket = await _secure(await _openTcp(host, port), context);
    _opened = true;
    return socket;
  }

  Future<Socket> _openTcp(Object host, int port) async {
    try {
      // The host lookup happens before startConnect returns its task, so it is under the deadline too.
      final task = await clock.deadline(
        Socket.startConnect(host, port),
        timeout,
        () => TvUnreachableException('$target could not be resolved within $timeout'),
      );
      _task = task;
      if (_cancelled) task.cancel();
      final socket = await clock.deadline(task.socket, timeout, () {
        task.cancel();
        return TvUnreachableException('$target did not answer within $timeout');
      });
      _socket = socket;
      if (_cancelled) throw _cancelledError();
      socket.setOption(SocketOption.tcpNoDelay, true);
      return socket;
    } on SocketException catch (e) {
      if (_cancelled) throw _cancelledError(e);
      throw TvSocket._connectError(e, target);
    }
  }

  Future<SecureSocket> _secure(Socket socket, SecurityContext context) async {
    try {
      final secured = SecureSocket.secure(socket, context: context, onBadCertificate: _accept);
      final tls = await clock.deadline(secured, timeout, () {
        socket.destroy();
        return TvTimeoutException('$target accepted the connection but did not finish TLS within $timeout');
      });
      if (_cancelled) {
        tls.destroy();
        throw _cancelledError();
      }
      // onBadCertificate runs only for certificates that fail verification, which every self-signed one does here;
      // checked again in case one ever passes.
      final certificate = tls.peerCertificate;
      if (pin != null && (certificate == null || !_accept(certificate))) {
        tls.destroy();
        throw _wrongTv();
      }
      return tls;
    } on IOException catch (e) {
      if (_cancelled) throw _cancelledError(e);
      if (_mismatch) throw _wrongTv(e);
      throw TvProtocolException('The TLS handshake with $target failed', cause: e);
    }
  }

  /// Whether to go on with the TV's [certificate]: always without a pin, otherwise only for the pinned key.
  bool _accept(X509Certificate certificate) {
    _presented = certificateFingerprint(certificate.der);
    final accepted = pin == null || _presented == pin;
    if (!accepted) _mismatch = true;
    return accepted;
  }

  TvWrongTvException _wrongTv([Object? cause]) => TvWrongTvException(
    'The device at $target has another key than the paired TV',
    expected: pin!,
    actual: _presented ?? 'none',
    cause: cause,
  );
}
