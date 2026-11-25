// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:test/test.dart';

import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/fuzz.dart';
import '../support/tools.dart';

void main() {
  late TvClientIdentity generated;
  late String certificatePem;
  late String privateKeyPem;
  setUpAll(() async {
    generated = await TvClientIdentity.generate(now: DateTime.utc(2026, 11, 25));
    final [certificate, key] = Pem.decode(generated.toPem());
    certificatePem = Pem.encode(certificate.label, certificate.der);
    privateKeyPem = Pem.encode(key.label, key.der);
  });

  test('a generated identity survives PEM, in either order and with a PKCS#1 key', () {
    final again = TvClientIdentity.fromPem(generated.toPem());
    expect(again.certificateDer, generated.certificateDer);
    expect(again.fingerprint, generated.fingerprint);
    expect(TvClientIdentity.fromPem(privateKeyPem + certificatePem).fingerprint, generated.fingerprint);
    final key = RsaPrivateKey.fromPkcs8(Pem.decode(privateKeyPem).single.der);
    final pkcs1 = certificatePem + Pem.encode('RSA PRIVATE KEY', key.toPkcs1());
    expect(TvClientIdentity.fromPem(pkcs1).fingerprint, generated.fingerprint);
  });

  test('a key that does not match the certificate is refused', () {
    final other = testIdentity('other');
    expect(() => TvClientIdentity.fromPem(certificatePem + other.privateKeyPem), throwsFormatException);
  });

  test('missing or doubled blocks are refused', () {
    expect(() => TvClientIdentity.fromPem(certificatePem), throwsFormatException);
    expect(() => TvClientIdentity.fromPem(generated.toPem() + privateKeyPem), throwsFormatException);
    expect(() => TvClientIdentity.fromPem('nothing'), throwsFormatException);
  });

  test('the certificate bytes cannot be changed from outside', () {
    expect(() => generated.certificateDer[0] = 0, throwsUnsupportedError);
  });

  test('a validity that is not positive is refused', () {
    expect(TvClientIdentity.generate(now: DateTime.utc(2026), validity: Duration.zero), throwsArgumentError);
  });

  test('damaged PEM gives a format error, nothing else', () {
    final pem = generated.toPem();
    fuzz(
      (bytes) => TvClientIdentity.fromPem(String.fromCharCodes(bytes)),
      seeds: [Uint8List.fromList(pem.codeUnits)],
      count: 3000,
    );
  });

  test('identities get different keys and serials', () async {
    final second = await TvClientIdentity.generate(now: DateTime.utc(2026, 11, 25));
    expect(second.fingerprint, isNot(generated.fingerprint));
    BigInt serial(TvClientIdentity identity) =>
        DerElement.parse(identity.certificateDer).sequence[0].sequence[1].integer;
    expect(serial(second), isNot(serial(generated)));
    expect(serial(second).bitLength, lessThanOrEqualTo(63));
  });

  test('the fingerprint is the SHA-256 of the public key, as OpenSSL computes it', () async {
    expect(generated.fingerprint, await Tools.opensslSpkiFingerprint(certificatePem));
  }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

  test('its TLS context presents it to a TV that trusts it', () async {
    final seen = <List<int>?>[];
    final tv = await FakeTv.start(
      trusted: [certificatePem],
      onRemote: (c) async {
        seen.add(c.clientCertificateDer);
        await c.close();
      },
    );
    addTearDown(tv.close);
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      tv.remotePort,
      context: generated.securityContext(),
      onBadCertificate: (_) => true,
    );
    await socket.drain<void>();
    await socket.close();
    expect(seen.single, generated.certificateDer);
  });
}
