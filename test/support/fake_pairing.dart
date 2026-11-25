// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/pairing_secret.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:androidtv_direct/src/protocol/pairing_messages.dart';

import 'fake_tv.dart';
import 'fixtures.dart';
import 'hex.dart';

/// The steps of pairing, in order: what the client sends at each.
enum PairingStep { request, options, configuration, secret }

/// How the fake TV misbehaves at a step instead of answering.
enum PairingFault {
  /// Answers status 400.
  errorStatus,

  /// Closes the connection.
  close,

  /// Sends bytes that are not a pairing message.
  garbage,

  /// Answers OK with a message that does not belong to the step.
  unexpected,

  /// Never answers.
  silence,

  /// Acknowledges the secret without echoing it (only at the secret step).
  noEcho,

  /// Acknowledges the secret echoing other bytes (only at the secret step).
  wrongEcho,
}

/// The TV's side of pairing, as the remote service does it: it shows a code made from both keys and a random nonce,
/// and accepts only the matching secret (402 otherwise). One [serve] per connection.
final class FakePairing {
  /// A TV that answers every step, or misbehaves with [fault] at [faultAt].
  FakePairing({this.faultAt, this.fault, int seed = 7}) : _random = Random(seed);

  /// Where to misbehave.
  final PairingStep? faultAt;

  /// How.
  final PairingFault? fault;

  final Random _random;

  /// The code the TV shows, once the configuration step is done.
  final Completer<String> code = Completer();

  /// The step whose message arrived last.
  PairingStep? reached;

  /// The client name the request carried.
  String? clientName;

  /// Whether a secret arrived.
  bool secretReceived = false;

  /// Plays the TV's side on [connection].
  Future<void> serve(FakeTvConnection connection) async {
    for (final step in PairingStep.values) {
      final bytes = await connection.receive(timeout: const Duration(minutes: 1));
      if (bytes == null) return;
      reached = step;
      final message = PairingMessage.decode(bytes);
      if (step == faultAt) return _misbehave(step, connection);
      final answer = _answer(step, message, connection);
      connection.send(answer.encode());
    }
    await connection.close();
  }

  PairingMessage _answer(PairingStep step, PairingMessage message, FakeTvConnection connection) {
    switch (step) {
      case PairingStep.request:
        clientName = (message.body! as PairingRequest).clientName;
        return PairingMessage(body: PairingRequestAck());
      case PairingStep.options:
        return PairingMessage(
          body: PairingOptions(outputEncodings: [PairingEncoding.hex6()], preferredRole: PairingRole.input),
        );
      case PairingStep.configuration:
        _expected = _showCode(connection);
        return PairingMessage(body: PairingConfigurationAck());
      case PairingStep.secret:
        secretReceived = true;
        final secret = (message.body! as PairingSecret).secret!;
        if (!sameBytes(secret, _expected!)) return PairingMessage(status: PairingStatus.badSecret);
        // The TV closes after the last answer; serve's close sends it.
        return PairingMessage(body: PairingSecretAck(secret: secret));
    }
  }

  Uint8List? _expected;

  Uint8List _showCode(FakeTvConnection connection) {
    final client = CertificateInfo.parse(connection.clientCertificateDer!).rsaPublicKey;
    final tv = CertificateInfo.parse(pemOf(testIdentity('tv').certificatePem)).rsaPublicKey;
    final nonce = [_random.nextInt(256), _random.nextInt(256)];
    final hash = pairingHash(client: client, tv: tv, nonce: nonce);
    code.complete(hex([hash[0], ...nonce]).toUpperCase());
    return hash;
  }

  Future<void> _misbehave(PairingStep step, FakeTvConnection connection) async {
    switch (fault!) {
      case PairingFault.errorStatus:
        connection.send(PairingMessage(status: PairingStatus.error).encode());
        await connection.close();
      case PairingFault.close:
        await connection.close();
      case PairingFault.garbage:
        connection
          ..send(const [0x0b, 0x0c])
          ..flush();
      case PairingFault.unexpected:
        final wrong = step == PairingStep.options ? PairingRequestAck() : PairingOptions();
        connection
          ..send(PairingMessage(body: wrong).encode())
          ..flush();
      case PairingFault.silence:
        connection.freeze();
      case PairingFault.noEcho:
        connection.send(PairingMessage(body: PairingSecretAck()).encode());
        await connection.close();
      case PairingFault.wrongEcho:
        connection.send(PairingMessage(body: PairingSecretAck(secret: Uint8List(32))).encode());
        await connection.close();
    }
  }
}
