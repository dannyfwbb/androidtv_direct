// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/arguments.dart';
import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:androidtv_direct/src/protocol/frame.dart';
import 'package:androidtv_direct/src/trace.dart';
import 'package:androidtv_direct/src/transport/secure_link.dart';

/// A TLS connection to one of the TV's ports, read and written in frames.
///
/// The TV's certificate is accepted whatever it is ([peerCertificate] keeps it): it is self-signed, and checking it
/// is the caller's job (by fingerprint). Frames arrive in order through [receive]; once the connection ends, every
/// pending and later [receive] fails with the same error.
final class TvSocket {
  TvSocket._(this._link, this.port, this._clock, this._tracer) {
    _link.listen(onData: _onData, onEnd: _onLinkEnd);
  }

  /// Opens a TLS connection to [host]:[port] presenting [context]'s certificate: TCP within [timeout], then the TLS
  /// handshake within [timeout] again.
  ///
  /// Throws [TvNoServiceException] when nothing listens on the port, [TvUnreachableException] when the address does
  /// not answer in time or has no route, [TvTimeoutException] when the TV accepts the connection but does not finish
  /// the handshake (a TV busy with another pairing does that), [TvClosedException] when it closes the connection
  /// during the handshake, [TvProtocolException] when the handshake fails otherwise, and [TvCancelledException] when
  /// [cancelOn] completes first.
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
    final attempt = _Attempt(
      describeTarget(checkHost(host), checkPort(port)),
      clock,
      timeout,
      pin == null ? null : checkFingerprint(pin, 'fingerprint'),
    );
    cancelOn?.whenComplete(attempt.cancel).ignore();
    final socket = TvSocket._(await attempt.open(host, port, context), port, clock, tracer);
    return socket.._note('connected to ${attempt.target}');
  }

  final SecureLink _link;
  final TvClock _clock;
  final TvTracer? _tracer;
  final FrameReader _reader = FrameReader();
  final Queue<Uint8List> _frames = Queue();
  final Completer<TvRemoteException?> _ended = Completer();
  Completer<void>? _arrival;
  void Function(Uint8List frame)? _onFrame;

  /// The TV's port.
  final int port;

  /// The certificate the TV presented.
  X509Certificate? get peerCertificate => _link.peerCertificate;

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
    _link.add(encodeFrame(body));
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
    await _link.close();
  }

  /// Waits for a frame or the end of the connection, up to [timeout].
  Future<void> _waitForFrame(Duration timeout) async {
    final arrival = _arrival = Completer();
    try {
      await _clock.sleep(timeout, cancelOn: Future.any([arrival.future, _ended.future]));
    } finally {
      _arrival = null;
    }
    if (_frames.isEmpty && !isClosed) throw TvTimeoutException('No message from port $port within $timeout');
  }

  void _onData(Uint8List chunk) {
    final List<Uint8List> frames;
    try {
      frames = _reader.add(chunk);
    } on FormatException catch (e) {
      _end(TvProtocolException('The TV sent a malformed frame', cause: e));
      _link.destroy();
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

  void _onLinkEnd([Object? error]) => _end(
    error == null
        ? const TvClosedException('The TV closed the connection')
        : TvClosedException('The connection to port $port failed', cause: error),
  );

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
}

/// One connection attempt: TCP, then TLS over it.
///
/// Every stage races its deadline and [cancel] ([_stage]); what a stage given up on still produces is closed when it
/// comes. Everything the attempt acquired is closed when it fails, and the connection becomes the caller's only if no
/// cancellation came before [open] returns.
final class _Attempt {
  _Attempt(this.target, this.clock, this.timeout, this.pin);

  final String target;
  final TvClock clock;
  final Duration timeout;
  final String? pin;
  final Completer<void> _cancel = Completer();
  String? _presented;

  /// Stops the attempt; does nothing once [open] has returned.
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  /// TCP, then TLS over it.
  Future<SecureLink> open(Object host, int port, SecurityContext context) async {
    final acquired = <void Function()>[];
    try {
      final plain = await _connect(host, port, acquired);
      final link = SecureLink(await _secure(plain, context), plain);
      _checkPin(link);
      if (_cancel.isCompleted) throw _cancelled;
      return link;
    } on Object {
      for (final release in acquired.reversed) {
        release();
      }
      rethrow;
    }
  }

  /// The TCP connection; adds what must be released to [acquired]. The host lookup happens before
  /// `startConnect` returns its task, so it is a stage of its own.
  Future<RawSocket> _connect(Object host, int port, List<void Function()> acquired) async {
    try {
      final task = await _stage(
        RawSocket.startConnect(host, port),
        discard: _discardTask,
        onTimeout: () => TvUnreachableException('$target could not be resolved within $timeout'),
      );
      acquired.add(task.cancel);
      final plain = await _stage(
        task.socket,
        discard: (socket) => socket.close().ignore(),
        onTimeout: () => TvUnreachableException('$target did not answer within $timeout'),
      );
      acquired.add(() => plain.close().ignore());
      plain.setOption(SocketOption.tcpNoDelay, true);
      return plain;
    } on SocketException catch (e) {
      throw _connectError(e);
    }
  }

  /// The TLS handshake over [plain]. One given up on never completes once [open] closed [plain].
  Future<RawSecureSocket> _secure(RawSocket plain, SecurityContext context) async {
    try {
      return await _stage(
        RawSecureSocket.secure(plain, context: context, onBadCertificate: _accept),
        discard: (tls) => tls.close().ignore(),
        onTimeout: () => TvTimeoutException('$target accepted the connection but did not finish TLS within $timeout'),
      );
    } on IOException catch (e) {
      if (_mismatch) throw _wrongTv(e);
      if (_closedByPeer(e)) throw TvClosedException('$target closed the connection during the TLS handshake', cause: e);
      throw TvProtocolException('The TLS handshake with $target failed', cause: e);
    }
  }

  /// [work] within [timeout], unless [cancel] comes first. What [work] produces after the stage was given up on goes
  /// to [discard], so nothing it opens is left behind.
  Future<T> _stage<T>(
    Future<T> work, {
    required void Function(T late) discard,
    required TvRemoteException Function() onTimeout,
  }) {
    final result = Completer<T>();
    void giveUp(Object error) {
      if (!result.isCompleted) result.completeError(error);
    }

    final timer = clock.timer(timeout, () => giveUp(onTimeout()));
    _cancel.future.then((_) => giveUp(_cancelled)).ignore();
    work
        .then(
          (value) => result.isCompleted ? discard(value) : result.complete(value),
          onError: (Object e, StackTrace s) => result.isCompleted ? null : result.completeError(e, s),
        )
        .whenComplete(timer.cancel)
        .ignore();
    return result.future;
  }

  /// Stops a connection [task] whose lookup finished too late, and closes the socket it may still open.
  static void _discardTask(ConnectionTask<RawSocket> task) {
    task.cancel();
    task.socket.then((socket) => socket.close(), onError: (Object _) {}).ignore();
  }

  TvCancelledException get _cancelled => TvCancelledException('The connection to $target was cancelled');

  /// onBadCertificate runs only for certificates that fail verification, which every self-signed one does here; the
  /// pin is checked again in case one ever passes.
  void _checkPin(SecureLink link) {
    final certificate = link.peerCertificate;
    if (pin != null && (certificate == null || !_presentsPin(certificate))) throw _wrongTv();
  }

  /// Whether to go on with the TV's [certificate]: always without a pin, otherwise only for the pinned key.
  bool _accept(X509Certificate certificate) => pin == null || _presentsPin(certificate);

  /// Records the key of [certificate] as the one presented, and whether it is the pinned one.
  bool _presentsPin(X509Certificate certificate) {
    _presented = certificateFingerprint(certificate.der);
    return _presented == pin;
  }

  /// Whether the TV presented a key that is not the pinned one.
  bool get _mismatch => pin != null && _presented != null && _presented != pin;

  TvWrongTvException _wrongTv([Object? cause]) => TvWrongTvException(
    'The device at $target has another key than the paired TV',
    expected: pin!,
    actual: _presented ?? 'none',
    cause: cause,
  );

  /// Whether the handshake failed because the other side went away (a remote service restarting behind a port
  /// forward accepts and closes), not because of what it said. dart:io tells only by its message.
  static bool _closedByPeer(IOException e) =>
      e is SocketException || (e is HandshakeException && e.message.contains('terminated during handshake'));

  TvRemoteException _connectError(SocketException e) {
    final code = e.osError?.errorCode;
    if (_refusedCodes.contains(code)) {
      return TvNoServiceException('$target refused the connection: no remote service listens there', cause: e);
    }
    return TvUnreachableException('Could not reach $target', cause: e);
  }

  // ECONNREFUSED on Linux and Android (111), macOS and iOS (61); on Windows WSAECONNREFUSED (10061) and
  // ERROR_CONNECTION_REFUSED (1225), which dart:io reports for an asynchronous connect.
  static const Set<int> _refusedCodes = {111, 61, 10061, 1225};
}
