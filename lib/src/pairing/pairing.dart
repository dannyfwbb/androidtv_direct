// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/crypto/pairing_secret.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/client_identity.dart';
import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:androidtv_direct/src/pairing/pairing_channel.dart';
import 'package:androidtv_direct/src/protocol/pairing_messages.dart';
import 'package:androidtv_direct/src/trace.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// Pairing with a TV: the TV shows a six-character code, the user types it in, and the TV remembers the client.
///
/// [start] runs the exchange until the code is on the TV's screen; [finish] sends the secret made from the code the
/// user typed. A code that cannot be the TV's fails with [TvWrongCodeException] before anything is sent, and the
/// pairing stays open for another try. [cancel] ends the pairing; the TV closes its dialog.
final class TvPairing {
  TvPairing._(this._channel, this._identity, this.tv);

  /// The pairing port.
  static const int defaultPort = 6467;

  /// The service every client asks for.
  static const String serviceName = 'atvremote';

  /// Connects to [host] and asks the TV to show a code; returns once it does.
  ///
  /// [clientName] appears in the TV's dialog ("Enter the following code on your …"). [timeout] limits the connection,
  /// the TLS handshake and each step. Throws [TvUnreachableException], [TvNoServiceException],
  /// [TvPairingRefusedException] (the TV said no or closed the connection), [TvTimeoutException] (also when the TV is
  /// busy with another pairing), [TvProtocolException] or, when [cancelOn] completes before this returns,
  /// [TvCancelledException]. [cancelOn] has no effect afterwards; use [cancel].
  static Future<TvPairing> start(
    Object host, {
    required TvClientIdentity identity,
    required String clientName,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 10),
    TvClock clock = TvClock.system,
    TvTracer? tracer,
    Future<void>? cancelOn,
  }) async {
    final socket = await TvSocket.connect(
      host,
      port,
      context: identity.securityContext(),
      timeout: timeout,
      clock: clock,
      tracer: tracer,
      cancelOn: cancelOn,
    );
    var cancelled = false;
    var started = false;
    cancelOn?.whenComplete(() {
      if (started) return;
      cancelled = true;
      unawaited(socket.close());
    }).ignore();
    try {
      final channel = PairingChannel(socket);
      await _askForCode(channel, clientName, timeout);
      final pairing = TvPairing._(channel, identity, socket.tvIdentity);
      started = true;
      return pairing;
    } on TvRemoteException catch (e) {
      await socket.close();
      if (cancelled) throw TvCancelledException('Pairing was cancelled', cause: e);
      rethrow;
    }
  }

  static Future<void> _askForCode(PairingChannel channel, String clientName, Duration timeout) async {
    final hex6 = PairingEncoding.hex6();
    await channel.exchange<PairingRequestAck>(
      PairingRequest(serviceName: serviceName, clientName: clientName),
      timeout: timeout,
    );
    await channel.exchange<PairingOptions>(
      PairingOptions(inputEncodings: [hex6], preferredRole: PairingRole.input),
      timeout: timeout,
    );
    await channel.exchange<PairingConfigurationAck>(
      PairingConfiguration(encoding: hex6, clientRole: PairingRole.input),
      timeout: timeout,
    );
  }

  final PairingChannel _channel;
  final TvClientIdentity _identity;
  bool _over = false;
  bool _busy = false;

  /// The TV, as its certificate describes it. [TvIdentity.fingerprint] is what [finish] returns.
  final TvIdentity tv;

  /// Whether [finish] can still be called: neither finished, cancelled nor closed by the TV.
  bool get isOpen => !_over && !_channel.socket.isClosed;

  /// Sends the secret for [code], the six characters on the TV's screen, and returns the paired TV.
  ///
  /// Throws [TvWrongCodeException] when [code] cannot be the TV's (not six hexadecimal characters, or it does not fit
  /// the keys): nothing was sent and the pairing stays open. Throws [TvPairingRefusedException] when the TV refuses
  /// the code (one wrong code in 256 passes the local check) or has closed the pairing (its user pressed Cancel, or
  /// its dialog timed out), [TvTimeoutException] when it does not answer within [timeout], [TvProtocolException] for
  /// anything malformed, and [TvCancelledException] when [cancel] is called meanwhile. After any of these but the
  /// first, the pairing is over. A [TvProtocolException] after the secret was sent may come after the TV stored the
  /// client; pairing again is harmless.
  ///
  /// Throws [StateError] when called while another [finish] runs, or after the pairing is over.
  Future<TvPairingResult> finish(String code, {Duration timeout = const Duration(seconds: 10)}) async {
    _checkCanFinish();
    final secret = _secretFor(code);
    _busy = true;
    try {
      final ack = await _channel.exchange<PairingSecretAck>(PairingSecret(secret: secret), timeout: timeout);
      // TVs seen echo the secret; one that leaves the echo out has still accepted it (status OK).
      final echo = ack.secret;
      if (echo != null && !sameBytes(echo, secret)) throw const TvProtocolException('The TV echoed another secret');
      return TvPairingResult(tv);
    } finally {
      _busy = false;
      await _end();
    }
  }

  /// Ends the pairing; the TV closes its dialog. Does nothing once the pairing is over.
  Future<void> cancel() => _end();

  void _checkCanFinish() {
    if (_busy) throw StateError('finish is already running');
    if (_over) throw StateError('The pairing is over');
    if (_channel.socket.isClosed) throw const TvPairingRefusedException('The TV closed the pairing');
  }

  Uint8List _secretFor(String code) {
    final bytes = parsePairingCode(code);
    if (bytes == null) throw const TvWrongCodeException('The code is not six hexadecimal characters');
    return pairingSecret(client: _identity.publicKey, tv: tv.publicKey, code: bytes) ??
        (throw const TvWrongCodeException('The code does not match the TV'));
  }

  Future<void> _end() async {
    _over = true;
    await _channel.socket.close();
  }
}

/// A finished pairing.
final class TvPairingResult {
  /// Wraps the paired TV.
  const TvPairingResult(this.tv);

  /// The paired TV, as its certificate describes it.
  final TvIdentity tv;

  /// The TV's key fingerprint: store it and pass it to every later connection.
  String get fingerprint => tv.fingerprint;
}
