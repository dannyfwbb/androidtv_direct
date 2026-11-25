// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/fuzz.dart';
import '../support/tools.dart';

void main() {
  final tv = pemFixtureDer('pairing/vector/tv.crt.pem');

  test("reads the TV's subject and key", () {
    final info = CertificateInfo.parse(tv);
    expect(info.attribute(dnQualifierOid), 'sdk_google_atv_amati_x86/emulator_x86_arm/AOSP TV on x86');
    expect(info.attribute(commonNameOid), 'atvremote/BB:BB:BB:00:00:04');
    expect(info.rsaPublicKey.exponent, BigInt.from(65537));
    expect(info.rsaPublicKey.modulus.bitLength, 2048);
  });

  test("the fingerprint is the SHA-256 of the TV's SubjectPublicKeyInfo", () {
    expect(CertificateInfo.parse(tv).fingerprint, 'cd3c355d08cfdcea3ae0f4ba4bf289fad0ceff28715826334a2514d2101bf3da');
  });

  test('the fingerprint agrees with OpenSSL for every test certificate', () async {
    for (final name in ['tv', 'client', 'other']) {
      final pem = testIdentity(name).certificatePem;
      expect(CertificateInfo.parse(Pem.decode(pem).single.der).fingerprint, await Tools.opensslSpkiFingerprint(pem));
    }
  }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

  test('a non-RSA key is a format error, on demand', () {
    final info = CertificateInfo.parse(pemFixtureDer('certificates/ec.crt.pem'));
    expect(info.attribute(commonNameOid), 'atvremote');
    expect(() => info.rsaPublicKey, throwsFormatException);
  });

  test('anything but a certificate is a format error', () {
    expect(() => CertificateInfo.parse([0x30, 0x00]), throwsFormatException);
    expect(() => CertificateInfo.parse([0x02, 0x01, 0x01]), throwsFormatException);
  });

  test('damaged certificates give a format error, nothing else', () {
    fuzz((bytes) => CertificateInfo.parse(bytes).rsaPublicKey, seeds: [tv], count: 20000);
  });
}
