// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// A TLS connection over a plain socket this package keeps: reads as they come, writes queued until the socket takes
/// them, a graceful close and an abrupt one.
///
/// dart:io's `SecureSocket` detaches its plain socket, after which nothing can end a handshake that the other side
/// holds: the connection stays open until that side closes it. With the plain [RawSocket] at hand, [destroy] ends the
/// connection at any point, the handshake included.
final class SecureLink {
  /// Wraps [_tls], made over [_plain] by `RawSecureSocket.secure`.
  SecureLink(this._tls, this._plain);

  /// How long [close] waits for queued bytes to go out before it closes anyway.
  static const Duration flushTimeout = Duration(seconds: 2);

  final RawSecureSocket _tls;
  final RawSocket _plain;
  final Queue<Uint8List> _queued = Queue();
  int _offset = 0;
  Completer<void>? _flushed;
  void Function([Object? error])? _onEnd;

  /// Whether this side closed or destroyed the connection, or the other side ended it.
  bool _over = false;

  /// The certificate the other side presented.
  X509Certificate? get peerCertificate => _tls.peerCertificate;

  /// Delivers what arrives to [onData], and calls [onEnd] once when the other side closes or the connection fails
  /// (with the error); not after [close] or [destroy].
  void listen({required void Function(Uint8List chunk) onData, required void Function([Object? error]) onEnd}) {
    _onEnd = onEnd;
    _tls.writeEventsEnabled = false;
    _tls.listen(
      (event) {
        // What arrived before a close came in read events before it.
        switch (event) {
          case RawSocketEvent.read:
            _read(onData);
          case RawSocketEvent.write:
            _write();
          case RawSocketEvent.readClosed:
          case RawSocketEvent.closed:
            _end();
        }
      },
      onError: _end,
      onDone: _end,
    );
  }

  /// Queues [bytes] and writes what the socket takes now; the rest goes when it can.
  void add(Uint8List bytes) {
    if (_over) return;
    _queued.add(bytes);
    if (_queued.length == 1) _write();
  }

  /// Sends what is queued (waiting up to [flushTimeout]), then closes.
  Future<void> close() async {
    if (_over) return;
    if (_queued.isNotEmpty) await (_flushed ??= Completer()).future.timeout(flushTimeout, onTimeout: () {});
    if (_over) return;
    _over = true;
    if (_queued.isNotEmpty) return _closePlain();
    try {
      await _tls.close();
    } on IOException {
      _closePlain();
    }
  }

  /// Ends the connection now, dropping what is queued.
  void destroy() {
    _over = true;
    _closePlain();
  }

  void _closePlain() {
    _queued.clear();
    _plain.close().ignore();
    _completeFlush();
  }

  void _end([Object? error]) {
    if (_over) return;
    _over = true;
    _closePlain();
    _onEnd?.call(error);
  }

  void _read(void Function(Uint8List chunk) onData) {
    try {
      for (var chunk = _tls.read(); chunk != null && !_over; chunk = _tls.read()) {
        onData(chunk);
      }
    } on SocketException catch (e) {
      _end(e);
    }
  }

  void _write() {
    try {
      while (_queued.isNotEmpty) {
        final next = _queued.first;
        _offset += _tls.write(next, _offset);
        if (_offset < next.length) {
          _tls.writeEventsEnabled = true;
          return;
        }
        _queued.removeFirst();
        _offset = 0;
      }
    } on SocketException catch (e) {
      return _end(e);
    }
    _completeFlush();
  }

  void _completeFlush() {
    final flushed = _flushed;
    _flushed = null;
    flushed?.complete();
  }
}
