// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/client_identity.dart';
import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/remote/state.dart';
import 'package:androidtv_direct/src/trace.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// A remote session with a paired TV.
///
/// [connect] returns once the TV reported its power state. [state] then always holds the latest of what the TV
/// reported, [changes] tells when it changes, and [done] completes once when the session ends. The session answers
/// the TV's pings itself and ends with [TvTimeoutException] after [connect]'s `idleTimeout` without a message in
/// either direction (a TV that went away). Sending counts as activity, because a TV does not ping a client that
/// sends; an app that keeps sending to a TV that went away learns it only when the writes fail. There is no
/// reconnecting inside: the app decides when to connect again.
final class TvRemote {
  TvRemote._(this._session);

  /// The remote port.
  static const int defaultPort = 6466;

  /// Connects to the TV at [host] with the paired [identity] and starts a session.
  ///
  /// [fingerprint] is the TV's key fingerprint from pairing (`TvPairingResult.fingerprint`): a device with another key
  /// is refused with [TvWrongTvException] during the TLS handshake, before anything is sent. It must be given; `null`
  /// deliberately accepts whatever device answers at [host], which then receives everything the app sends, typed
  /// passwords included.
  ///
  /// [features] is what the session asks for; the TV grants what it offers of it ([TvRemote.features]). Power reports
  /// are always asked for: the session is ready when the TV reports its power state.
  ///
  /// Throws [TvUnreachableException], [TvNoServiceException], [TvWrongTvException], [TvNotPairedException] (the TV does
  /// not know [identity]), [TvTimeoutException] (no TLS within [connectTimeout], or no start within [startTimeout]),
  /// [TvClosedException], [TvProtocolException] or, when [cancelOn] completes before this returns,
  /// [TvCancelledException].
  static Future<TvRemote> connect(
    Object host, {
    required TvClientIdentity identity,
    required String? fingerprint,
    Set<TvFeature> features = TvFeature.defaults,
    int port = defaultPort,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration startTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 16),
    TvClock clock = TvClock.system,
    TvTracer? tracer,
    Future<void>? cancelOn,
  }) async {
    final socket = await TvSocket.connect(
      host,
      port,
      context: identity.securityContext(),
      timeout: connectTimeout,
      pin: fingerprint,
      clock: clock,
      tracer: tracer,
      cancelOn: cancelOn,
    );
    final wanted = TvFeature.maskOf({...features, TvFeature.power});
    final session = RemoteSession(socket, wanted: wanted, clock: clock, idleTimeout: idleTimeout);
    var started = false;
    cancelOn?.whenComplete(() {
      if (!started) unawaited(session.close());
    }).ignore();
    await session.start(startTimeout);
    started = true;
    return TvRemote._(session);
  }

  final RemoteSession _session;

  /// The TV, as it described itself when the session started.
  TvDevice get device => _session.device;

  /// What the session can do: what it asked for and the TV offered.
  Set<TvFeature> get features => TvFeature.fromMask(_session.granted);

  /// The latest of everything the TV reported.
  TvState get state => _session.state;

  /// Every change of [state], as it happens. Closes when the session ends.
  Stream<TvState> get changes => _session.changes;

  /// Completes once when the session ends: with `null` after [close], otherwise with why it ended.
  Future<TvRemoteException?> get done => _session.done;

  /// Whether the session has ended.
  bool get isClosed => _session.isClosed;

  /// Every message from the TV as raw bytes, for messages this package does not handle yet. Experimental: the shape
  /// may change in a minor version.
  Stream<TvRawMessage> get rawMessages =>
      _session.messages.map((received) => TvRawMessage(received.message.field, received.bytes));

  /// Sends a message this package does not offer yet: [body] in envelope field [field]. Experimental: the shape may
  /// change in a minor version. Throws what ended the session once it has ended.
  void sendRaw(int field, List<int> body) {
    final envelope = (ProtoWriter()..bytes(field, body)).toBytes();
    _session.sendBytes(envelope, kind: _kindOf(envelope, field));
  }

  /// The traced name of a raw message: its kind when the package knows it, else `raw(field)`.
  static String _kindOf(Uint8List envelope, int field) {
    try {
      final message = RemoteEnvelope.fromClient(envelope);
      return message is UnknownEnvelope ? 'raw($field)' : message.kind;
    } on FormatException {
      return 'raw($field)';
    }
  }

  /// Ends the session. Does nothing once it has ended.
  Future<void> close() => _session.close();
}

/// One message of the remote session as it was on the wire.
final class TvRawMessage {
  /// Creates the message.
  TvRawMessage(this.field, this.envelope);

  /// The envelope field it travels in: what kind of message it is.
  final int field;

  /// The whole envelope.
  final Uint8List envelope;

  @override
  String toString() => 'TvRawMessage($field, ${envelope.length} bytes)';
}
