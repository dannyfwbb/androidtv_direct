// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/pairing_secret.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/hex.dart';
import '../support/tools.dart';

RsaPublicKey keyOf(String path) => CertificateInfo.parse(pemFixtureDer(path)).rsaPublicKey;

void main() {
  final client = keyOf('pairing/vector/client.crt.pem');
  final tv = keyOf('pairing/vector/tv.crt.pem');

  group('parsePairingCode', () {
    test('reads six hexadecimal characters in either case, ignoring surrounding space', () {
      expect(parsePairingCode('FDFD37'), [0xfd, 0xfd, 0x37]);
      expect(parsePairingCode(' fdFd37\n'), [0xfd, 0xfd, 0x37]);
    });

    test('refuses anything else', () {
      for (final code in ['', 'FDFD3', 'FDFD377', 'FDFD3G', 'FD FD37', '0xFDFD', '１２３４５６']) {
        expect(parsePairingCode(code), isNull, reason: code);
      }
    });
  });

  group('pairingSecret', () {
    test('gives the secret a TV accepted for FDFD37', () {
      final secret = pairingSecret(client: client, tv: tv, code: parsePairingCode('FDFD37')!);
      expect(hexEncode(secret!), 'fdb6b5c3613bcff2ada1ae1c5e5489727473995741909bae39adf79f917a632b');
    });

    test('refuses every other first byte', () {
      for (var first = 0; first < 256; first++) {
        if (first == 0xfd) continue;
        expect(pairingSecret(client: client, tv: tv, code: Uint8List.fromList([first, 0xfd, 0x37])), isNull);
      }
    });

    test('agrees with Python for keys with the high bit set and with short magnitudes', () async {
      final keys = [
        RsaPublicKey(BigInt.parse('80${'11' * 255}', radix: 16), BigInt.from(3)),
        RsaPublicKey(BigInt.parse('00ff${'22' * 254}', radix: 16), BigInt.from(65537)),
      ];
      for (final nonce in [
        [0x00, 0x00],
        [0xab, 0xcd],
      ]) {
        final expected = await _pythonSecret(keys[0], keys[1], nonce);
        final code = Uint8List.fromList([expected[0], ...nonce]);
        expect(hexEncode(pairingSecret(client: keys[0], tv: keys[1], code: code)!), hexEncode(expected));
      }
    }, skip: Tools.skipUnless(Tools.python, 'python3'));

    test('agrees with Python for a freshly generated pair', () async {
      final client = RsaPrivateKey.generate().publicKey;
      final tv = RsaPrivateKey.generate().publicKey;
      final expected = await _pythonSecret(client, tv, [0x12, 0x34]);
      final code = Uint8List.fromList([expected[0], 0x12, 0x34]);
      expect(hexEncode(pairingSecret(client: client, tv: tv, code: code)!), hexEncode(expected));
    }, skip: Tools.skipUnless(Tools.python, 'python3'));
  });
}

/// The secret computed by Python's own integer encoding and hashlib.
Future<Uint8List> _pythonSecret(RsaPublicKey client, RsaPublicKey tv, List<int> nonce) async {
  const script = '''
import hashlib, sys
def b(n): return n.to_bytes((n.bit_length() + 7) // 8, "big")
cn, ce, tn, te, nonce = sys.argv[1:]
data = b(int(cn, 16)) + b(int(ce, 16)) + b(int(tn, 16)) + b(int(te, 16)) + bytes.fromhex(nonce)
print(hashlib.sha256(data).hexdigest())
''';
  final out = await Tools.run(Tools.python!, [
    '-I',
    '-c',
    script,
    for (final n in [client.modulus, client.exponent, tv.modulus, tv.exponent]) n.toRadixString(16),
    hexEncode(nonce),
  ]);
  return unhex(out.trim());
}
