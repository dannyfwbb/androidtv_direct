// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/frame.dart';

import 'fixtures.dart';
import 'hex.dart';

/// What the fake TV does with one accepted connection.
typedef FakeTvHandler = Future<void> Function(FakeTvConnection connection);

/// A TV on loopback: the pairing port and the remote port, each a TLS server with the TV's identity.
///
/// What happens on a connection is up to the test: a [FakeTvHandler] per port, usually [FakeTvConnection.run] with a
/// script. dart:io's server only accepts client certificates it trusts, so the fake TV trusts the certificates it is
/// given (a real TV accepts any certificate on the pairing port); a client with another certificate fails the
/// handshake, which is what a real TV's remote port does with a client it has not paired.
final class FakeTv {
  FakeTv._(this._pairing, this._remote, this.certificateDer);

  /// Starts both ports with the identity [identityName] from `test/fixtures/identities/`, trusting [trusted]
  /// certificates (PEM).
  static Future<FakeTv> start({
    required List<String> trusted,
    FakeTvHandler? onPairing,
    FakeTvHandler? onRemote,
    String identityName = 'tv',
  }) async {
    final identity = testIdentity(identityName);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    if (trusted.isNotEmpty) context.setTrustedCertificatesBytes(utf8.encode(trusted.join()));
    final pairing = await _Port.bind(context, onPairing);
    try {
      return FakeTv._(pairing, await _Port.bind(context, onRemote), _derOf(identity.certificatePem));
    } on Object {
      await pairing.close();
      rethrow;
    }
  }

  final _Port _pairing;
  final _Port _remote;

  /// The TV's certificate (DER), as a client should see it.
  final Uint8List certificateDer;

  /// The pairing port.
  int get pairingPort => _pairing.port;

  /// The remote port.
  int get remotePort => _remote.port;

  /// Handshakes that failed on either port (an untrusted client certificate, or a client that went away).
  int get rejected => _pairing.rejected + _remote.rejected;

  /// What went against a script on either port; empty when every script ran as written.
  List<String> get errors => [..._pairing.errors, ..._remote.errors];

  /// Stops listening and closes every open connection.
  Future<void> close() => Future.wait([_pairing.close(), _remote.close()]);
}

Uint8List _derOf(String pem) {
  final body = pem.split('\n').where((line) => line.isNotEmpty && !line.startsWith('-----')).join();
  return base64.decode(body);
}

final class _Port {
  _Port(this._server, this._handler);

  static Future<_Port> bind(SecurityContext context, FakeTvHandler? handler) async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: true,
    );
    final port = _Port(server, handler);
    port._subscription = server.listen(port._accept, onError: (Object _) => port.rejected++);
    return port;
  }

  final SecureServerSocket _server;
  final FakeTvHandler? _handler;
  late final StreamSubscription<SecureSocket> _subscription;
  final Set<FakeTvConnection> _open = {};
  final List<String> errors = [];
  int rejected = 0;

  int get port => _server.port;

  void _accept(SecureSocket socket) {
    final connection = FakeTvConnection._(socket, errors);
    _open.add(connection);
    unawaited(connection.done.whenComplete(() => _open.remove(connection)));
    final handler = _handler;
    if (handler == null) {
      unawaited(connection.close());
      return;
    }
    unawaited(_handle(handler, connection));
  }

  Future<void> _handle(FakeTvHandler handler, FakeTvConnection connection) async {
    try {
      await handler(connection);
    } on Object catch (e) {
      errors.add('handler failed: $e');
      await connection.close();
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
    await Future.wait([
      for (final connection in [..._open]) connection.close(),
    ]);
  }
}

/// How the fake TV hands its writes to the socket, from `FAKE_TV_CHUNKING`: `none` (one write per message, the
/// default), `coalesce` (everything sent until the TV next waits or closes in one write) or `bytes` (every byte on its
/// own). A client must read the same messages in every mode.
enum FakeTvChunking {
  /// One write per message.
  none,

  /// Messages gathered until the TV waits, then one write.
  coalesce,

  /// One write per byte.
  bytes;

  /// The mode CI chose, or [none].
  static final FakeTvChunking current = FakeTvChunking.values.byName(
    Platform.environment['FAKE_TV_CHUNKING'] ?? 'none',
  );
}

/// One accepted TLS connection to the fake TV, read and written in frames.
final class FakeTvConnection {
  FakeTvConnection._(this._socket, this._errors) {
    _subscription = _socket.listen(_onData, onError: (Object _) => _finish(), onDone: _finish);
  }

  final SecureSocket _socket;
  final List<String> _errors;
  late final StreamSubscription<Uint8List> _subscription;
  final FrameReader _reader = FrameReader();
  final List<Uint8List> _received = [];
  final List<int> _pending = [];
  final Completer<void> _done = Completer();
  Completer<void>? _arrival;
  Future<void> _writes = Future.value();
  bool _frozen = false;

  /// How writes reach the socket. Each write is flushed before the next, so the client sees the pieces apart.
  FakeTvChunking chunking = FakeTvChunking.current;

  /// The certificate the client presented (DER), if any.
  Uint8List? get clientCertificateDer => _socket.peerCertificate?.der;

  /// Completes when the connection is closed, by either side.
  Future<void> get done => _done.future;

  /// Sends one message (without its length prefix; the frame is added here).
  void send(List<int> body) {
    _pending.addAll(encodeFrame(body));
    if (chunking != FakeTvChunking.coalesce) _flush();
  }

  /// The next message the client sent, or `null` if the connection closed first or [timeout] passed.
  Future<Uint8List?> receive({Duration timeout = const Duration(seconds: 5)}) async {
    if (_arrival != null) throw StateError('Only one receive at a time');
    _flush();
    if (_received.isEmpty && !_done.isCompleted) {
      final arrival = _arrival = Completer();
      final timer = Timer(timeout, () => _wake(arrival));
      await Future.any([arrival.future, _done.future]);
      timer.cancel();
      _arrival = null;
    }
    return _received.isEmpty ? null : _received.removeAt(0);
  }

  /// Plays [script] in order. Every step that does not go as written is recorded in [FakeTv.errors], and the
  /// connection is closed.
  Future<void> run(List<FakeTvStep> script) async {
    for (final (i, step) in script.indexed) {
      final error = await step._play(this);
      if (error != null) {
        _errors.add('step ${i + 1}: $error');
        await close();
        return;
      }
    }
  }

  /// Stops reading and writing, as a TV that froze; the socket stays open until [close].
  void freeze() {
    _frozen = true;
    _pending.clear();
    _subscription.pause();
  }

  /// Sends what is pending and closes the connection.
  Future<void> close() async {
    _flush();
    await _writes;
    await _subscription.cancel();
    await _socket.close().catchError((Object _) => _socket);
    _socket.destroy();
    _finish();
  }

  void _onData(Uint8List chunk) {
    try {
      final frames = _reader.add(chunk);
      if (frames.isEmpty) return;
      _received.addAll(frames);
      _wake(_arrival);
    } on FormatException catch (e) {
      _errors.add('client sent a bad frame: ${e.message}');
      unawaited(close());
    }
  }

  void _wake(Completer<void>? arrival) {
    if (arrival != null && !arrival.isCompleted) arrival.complete();
  }

  void _flush() {
    if (_pending.isEmpty || _done.isCompleted || _frozen) return;
    final bytes = Uint8List.fromList(_pending);
    _pending.clear();
    final pieces = chunking == FakeTvChunking.bytes
        ? [
            for (final byte in bytes) Uint8List.fromList([byte]),
          ]
        : [bytes];
    _writes = _writes.then((_) => _write(pieces));
  }

  Future<void> _write(List<Uint8List> pieces) async {
    try {
      for (final piece in pieces) {
        if (_done.isCompleted) return;
        _socket.add(piece);
        await _socket.flush();
        // A timer turn lets the client's read event run before the next piece, so the pieces arrive apart.
        await Future<void>.delayed(Duration.zero);
      }
    } on Object {
      // The client went away; what it missed does not matter any more.
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// One step of a fake TV's script.
sealed class FakeTvStep {
  const FakeTvStep();

  /// Plays the step; returns what went wrong, or `null`.
  Future<String?> _play(FakeTvConnection connection);
}

/// Sends a message.
final class FakeTvSend extends FakeTvStep {
  /// Sends [body].
  const FakeTvSend(this.body);

  /// The message, without its length prefix.
  final List<int> body;

  @override
  Future<String?> _play(FakeTvConnection connection) async {
    connection.send(body);
    return null;
  }
}

/// Waits for the client's next message and checks it.
final class FakeTvExpect extends FakeTvStep {
  /// Expects a message that [matches] accepts; [description] names it in errors.
  const FakeTvExpect(this.description, this.matches, {this.timeout = const Duration(seconds: 5)});

  /// Expects exactly [body].
  FakeTvExpect.bytes(List<int> body, {Duration timeout = const Duration(seconds: 5)})
    : this(hex(body), (received) => hex(received) == hex(body), timeout: timeout);

  /// What the message should be, for errors.
  final String description;

  /// Whether a received message is the expected one.
  final bool Function(Uint8List body) matches;

  /// How long to wait.
  final Duration timeout;

  @override
  Future<String?> _play(FakeTvConnection connection) async {
    final body = await connection.receive(timeout: timeout);
    if (body == null) return 'expected $description, got nothing';
    return matches(body) ? null : 'expected $description, got ${hex(body)}';
  }
}

/// Closes the connection.
final class FakeTvClose extends FakeTvStep {
  /// Closes the connection.
  const FakeTvClose();

  @override
  Future<String?> _play(FakeTvConnection connection) async {
    await connection.close();
    return null;
  }
}

/// Stops reading and writing, and stays so until the test closes the fake TV.
final class FakeTvFreeze extends FakeTvStep {
  /// Freezes the connection.
  const FakeTvFreeze();

  @override
  Future<String?> _play(FakeTvConnection connection) async {
    connection.freeze();
    return null;
  }
}
