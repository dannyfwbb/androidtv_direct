// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/fuzz.dart';

void main() {
  final key = testKey('client');

  test('PKCS#8 and PKCS#1 round trip', () {
    expect(RsaPrivateKey.fromPkcs8(key.toPkcs8()).modulus, key.modulus);
    expect(RsaPrivateKey.fromPkcs1(key.toPkcs1()).privateExponent, key.privateExponent);
  });

  test('an inconsistent key is refused', () {
    final other = testKey('other');
    expect(
      () => RsaPrivateKey(
        modulus: key.modulus,
        publicExponent: key.publicExponent,
        privateExponent: other.privateExponent,
        p: key.p,
        q: key.q,
      ),
      throwsFormatException,
    );
  });

  test('a signature verifies with the public exponent', () {
    final signature = key.signSha256([1, 2, 3]);
    expect(signature, hasLength(256));
    final recovered = Der.unsignedValue(signature).modPow(key.publicExponent, key.modulus);
    expect(
      Der.unsignedBytes(recovered, length: 256).sublist(256 - 32 - sha256DigestInfoPrefix.length, 256 - 32),
      sha256DigestInfoPrefix,
    );
  });

  test('the public key reads back from the SubjectPublicKeyInfo', () {
    final public = RsaPublicKey.fromSubjectPublicKeyInfo(DerElement.parse(key.subjectPublicKeyInfo()));
    expect(public, key.publicKey);
    expect(public.exponent, BigInt.from(65537));
  });

  test('a SubjectPublicKeyInfo of another algorithm is refused', () {
    final ec = Der.sequence([
      Der.sequence([Der.objectIdentifier('1.2.840.10045.2.1'), Der.objectIdentifier('1.2.840.10045.3.1.7')]),
      Der.bitString([4, 1, 2]),
    ]);
    expect(() => RsaPublicKey.fromSubjectPublicKeyInfo(DerElement.parse(ec)), throwsFormatException);
  });

  group('key import refuses', () {
    Uint8List pkcs1With(int index, Uint8List element) {
      final fields = [for (final e in DerElement.parse(key.toPkcs1()).sequence) e.encoded];
      fields[index] = element;
      return Der.sequence(fields);
    }

    test('a PKCS#1 key with another version', () {
      expect(() => RsaPrivateKey.fromPkcs1(pkcs1With(0, Der.smallInteger(1))), throwsFormatException);
    });

    test('a PKCS#1 key with wrong CRT values', () {
      expect(() => RsaPrivateKey.fromPkcs1(pkcs1With(6, Der.integer(key.dP + BigInt.one))), throwsFormatException);
    });

    test('a PKCS#8 key whose algorithm has parameters other than NULL', () {
      final pkcs8 = Der.sequence([
        Der.smallInteger(0),
        Der.sequence([Der.objectIdentifier(rsaEncryptionOid), Der.smallInteger(1)]),
        Der.octetString(key.toPkcs1()),
      ]);
      expect(() => RsaPrivateKey.fromPkcs8(pkcs8), throwsFormatException);
    });

    test('damaged keys, with a format error and nothing else', () {
      fuzz(RsaPrivateKey.fromPkcs8, seeds: [key.toPkcs8()], count: 3000);
      fuzz(RsaPrivateKey.fromPkcs1, seeds: [key.toPkcs1()], count: 3000, seed: 1);
    });
  });
}
