// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/protocol/pairing_messages.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/fuzz.dart';
import '../support/hex.dart';

void main() {
  final recordings = [
    for (final m in recordedMessages())
      if (m.port == 6467) m,
  ];

  test('every recorded pairing message decodes to its kind and encodes to the same bytes', () {
    for (final recording in recordings) {
      final message = PairingMessage.decode(recording.bytes);
      expect(message.kind, recording.name);
      expect(message.version, pairingProtocolVersion);
      expect(message.isOk, isTrue);
      expect(hex(message.encode()), hex(recording.bytes), reason: recording.name);
    }
  });

  test('what the client sends encodes to the recorded bytes', () {
    final secret =
        (PairingMessage.decode(recorded('pairingSecret', outgoing: true).bytes).body! as PairingSecret).secret;
    final sent = {
      'pairingOptions': PairingOptions(inputEncodings: [PairingEncoding.hex6()], preferredRole: PairingRole.input),
      'pairingConfiguration': PairingConfiguration(encoding: PairingEncoding.hex6(), clientRole: PairingRole.input),
      'pairingSecret': PairingSecret(secret: secret),
    };
    for (final MapEntry(key: name, value: body) in sent.entries) {
      expect(hex(PairingMessage(body: body).encode()), hex(recorded(name, outgoing: true).bytes), reason: name);
    }
  });

  test('a pairing request carries the service and the client name', () {
    final request = PairingRequest(serviceName: 'atvremote', clientName: 'androidtv_direct');
    expect(
      hex(PairingMessage(body: request).encode()),
      '080210c801521d0a0961747672656d6f74651210616e64726f696474765f646972656374',
    );
  });

  test("the TV's options offer six hexadecimal characters for it to show", () {
    final options = PairingMessage.decode(recorded('pairingOptions', outgoing: false).bytes).body! as PairingOptions;
    expect(options.inputEncodings, isEmpty);
    expect(options.outputEncodings.single.type, PairingEncodingType.hexadecimal);
    expect(options.outputEncodings.single.symbolLength, 6);
    expect(options.preferredRole, PairingRole.input);
  });

  test('the secret ack echoes the secret', () {
    final secret = PairingMessage.decode(recorded('pairingSecret', outgoing: true).bytes).body! as PairingSecret;
    final ack = PairingMessage.decode(recorded('pairingSecretAck', outgoing: false).bytes).body! as PairingSecretAck;
    expect(ack.secret, secret.secret);
    expect(ack.secret, hasLength(32));
  });

  test('a status-only answer has no body', () {
    final message = PairingMessage.decode(unhex('0802109203'));
    expect(message.status, PairingStatus.badSecret);
    expect(message.isOk, isFalse);
    expect(message.body, isNull);
    expect(message.kind, 'status');
  });

  test('unknown fields survive; two inner messages are a format error', () {
    expect(hex(PairingMessage.decode(unhex('080210c8016001fa0100')).encode()), '080210c8016001fa0100');
    expect(() => PairingMessage.decode(unhex('080210c8015a00fa0100')), throwsFormatException);
  });

  group('random and damaged input gives a message or a format error, and encodes stably', () {
    final seeds = [for (final r in recordings) r.bytes];
    test('the outer message', () => fuzz(PairingMessage.decode, encode: (m) => m.encode(), seeds: seeds));
    for (final MapEntry(key: field, value: decode) in pairingBodyDecoders.entries) {
      final bodies = [
        for (final s in seeds)
          if (PairingMessage.decode(s).body case final body? when body.field == field) body.encode(),
      ];
      test('inner message $field', () => fuzz(decode, encode: (m) => m.encode(), seeds: bodies, seed: field));
    }
    test('an encoding', () => fuzz(PairingEncoding.decode, encode: (m) => m.encode(), seeds: [unhex('08031006')]));
  });
}
