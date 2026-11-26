// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/pairing_secret.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:androidtv_direct/src/protocol/pairing_messages.dart';
import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

/// A TV that answers each step of pairing correctly or otherwise, at random: another status, a message of another
/// kind, an extra message before the answer, the answer twice, unknown fields, a close, silence; and at the secret,
/// an empty, a different or no echo. Pairing must succeed or fail with a [TvRemoteException], never hang, be over
/// afterwards and leave no connection open.
void main() {
  final seeds = 60 * int.parse(Platform.environment['FUZZ_SCALE'] ?? '1');
  for (var seed = 0; seed < seeds; seed++) {
    test('seed $seed', () async {
      final tv = _HostileTv(Random(seed));
      final fake = await startFakeTv(onPairing: tv.serve);
      Future<void> expectTyped(Future<Object?> call) =>
          call.then<void>((_) {}, onError: (Object e) => expect(e, isA<TvRemoteException>(), reason: 'seed $seed'));

      TvPairing? pairing;
      await expectTyped(
        TvPairing.start(
          InternetAddress.loopbackIPv4,
          port: fake.pairingPort,
          identity: testClient(),
          clientName: 'Hostile',
          timeout: const Duration(milliseconds: 300),
        ).then((started) => pairing = started),
      );
      if (pairing case final started?) {
        await expectTyped(started.finish(await tv.code.future, timeout: const Duration(milliseconds: 300)));
        expect(started.isOpen, isFalse);
      }
      await until(() => fake.openConnections == 0);
    });
  }
}

final class _HostileTv {
  _HostileTv(this._random);

  final Random _random;
  final Completer<String> code = Completer();

  static const List<int> _statuses = [0, 1, 199, 201, 400, 401, 402, 403, 500, 0x7fffffff];

  Future<void> serve(FakeTvConnection connection) async {
    for (final step in _Step.values) {
      if (await connection.receive(timeout: const Duration(seconds: 5)) == null) return;
      final answer = _answerTo(step, connection);
      switch (_random.nextInt(12)) {
        case 0:
          return connection.close();
        case 1:
          // Silence until the client gives up.
          await connection.done;
          return;
        case 2:
          connection.send(PairingMessage(status: PairingStatus(_statuses[_random.nextInt(_statuses.length)])).encode());
        case 3:
          connection.send(PairingMessage(body: _wrongKind(step)).encode());
        case 4:
          connection
            ..send(PairingMessage(body: _wrongKind(step)).encode())
            ..send(answer.encode());
        case 5:
          connection
            ..send(answer.encode())
            ..send(answer.encode());
        case 6:
          connection.send(_withUnknownFields(answer).encode());
        default:
          connection.send(answer.encode());
      }
      connection.flush();
    }
    await connection.close();
  }

  PairingMessage _answerTo(_Step step, FakeTvConnection connection) => switch (step) {
    _Step.request => PairingMessage(body: PairingRequestAck(serverName: _random.nextBool() ? null : 'TV')),
    _Step.options => PairingMessage(
      body: PairingOptions(outputEncodings: [PairingEncoding.hex6()], preferredRole: PairingRole.input),
    ),
    _Step.configuration => _showCode(connection),
    _Step.secret => PairingMessage(body: PairingSecretAck(secret: _echo())),
  };

  /// The echo of the secret: right (the hash is not checked here), missing, empty or other bytes.
  Uint8List? _echo() => switch (_random.nextInt(4)) {
    0 => null,
    1 => Uint8List(0),
    2 => Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256))),
    _ => _expected,
  };

  Uint8List? _expected;

  PairingMessage _showCode(FakeTvConnection connection) {
    final client = CertificateInfo.parse(connection.clientCertificateDer!).rsaPublicKey;
    final tv = CertificateInfo.parse(pemOf(testIdentity('tv').certificatePem)).rsaPublicKey;
    final nonce = [_random.nextInt(256), _random.nextInt(256)];
    final hash = _expected = pairingHash(client: client, tv: tv, nonce: nonce);
    code.complete(hexEncode([hash[0], ...nonce]).toUpperCase());
    return PairingMessage(body: PairingConfigurationAck());
  }

  PairingBody _wrongKind(_Step step) => switch (step) {
    _Step.request => PairingConfigurationAck(),
    _Step.options => PairingRequestAck(),
    _Step.configuration => PairingSecretAck(secret: Uint8List(32)),
    _Step.secret => PairingOptions(),
  };

  PairingMessage _withUnknownFields(PairingMessage answer) => PairingMessage(
    status: answer.status,
    body: answer.body,
    unknownFields: [ProtoField.varint(99, _random.nextInt(1000)), ProtoField.bytes(98, Uint8List(3))],
  );
}

enum _Step { request, options, configuration, secret }
