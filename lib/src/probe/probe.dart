// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/client_identity.dart';
import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:androidtv_direct/src/pairing/pairing.dart';
import 'package:androidtv_direct/src/probe/scan.dart';
import 'package:androidtv_direct/src/trace.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// Reads what a TV's certificate says without pairing and without anything appearing on the TV.
///
/// The probe opens a TLS connection to the pairing port, reads the certificate and closes without sending a message.
abstract final class TvProbe {
  static Future<TvClientIdentity>? _throwaway;

  /// The TV at [host]: model, names, network address and key fingerprint.
  ///
  /// The TLS handshake needs a client certificate; without [identity], one made once per isolate (valid from [now]) is
  /// used. [timeout] limits the connection and the handshake. Throws [TvUnreachableException], [TvNoServiceException],
  /// [TvTimeoutException] (the TV accepted the connection but did not finish TLS: it is busy with a pairing),
  /// [TvClosedException] (the port closed the connection during the handshake), [TvProtocolException] (no usable
  /// certificate) or, when [cancelOn] completes first, [TvCancelledException].
  static Future<TvIdentity> identify(
    Object host, {
    int port = TvPairing.defaultPort,
    TvClientIdentity? identity,
    Duration timeout = const Duration(seconds: 5),
    TvClock clock = TvClock.system,
    TvTracer? tracer,
    Future<void>? cancelOn,
    DateTime Function() now = DateTime.now,
  }) async {
    final client = identity ?? await _sharedIdentity(now);
    final socket = await TvSocket.connect(
      host,
      port,
      context: client.securityContext(),
      timeout: timeout,
      clock: clock,
      tracer: tracer,
      cancelOn: cancelOn,
    );
    try {
      return socket.tvIdentity;
    } finally {
      await socket.close();
    }
  }

  /// The throwaway identity, made once; a failed attempt is not kept.
  static Future<TvClientIdentity> _sharedIdentity(DateTime Function() now) =>
      _throwaway ??= TvClientIdentity.generate(now: now()).catchError((Object error, StackTrace stack) {
        _throwaway = null;
        return Future<TvClientIdentity>.error(error, stack);
      });

  /// Probes many hosts, for a scan: at most [concurrency] connections at once, each limited by [timeout]. Emits the
  /// hosts that answer as a TV's remote service (a certificate made by it), in the order they answer; hosts that do
  /// not answer, refuse or speak something else are left out. Nothing appears on the TVs. Which hosts to try (a
  /// subnet, a list) is the caller's policy. Pausing the subscription stops new probes; cancelling it stops the
  /// running ones too.
  static Stream<TvScanResult> scan(
    Iterable<Object> hosts, {
    int port = TvPairing.defaultPort,
    int concurrency = 16,
    Duration timeout = const Duration(seconds: 1),
    TvClientIdentity? identity,
    TvClock clock = TvClock.system,
    DateTime Function() now = DateTime.now,
  }) => scanHosts(
    hosts,
    concurrency: concurrency,
    identify: (host, cancelOn) =>
        identify(host, port: port, identity: identity, timeout: timeout, clock: clock, now: now, cancelOn: cancelOn),
  );
}
