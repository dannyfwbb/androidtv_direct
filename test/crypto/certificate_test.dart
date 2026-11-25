// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/src/crypto/certificate.dart';
import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/tools.dart';

void main() {
  final key = testKey('client');
  final now = DateTime.utc(2026, 11, 25, 12, 30, 45, 999);
  final der = buildCertificate(
    key,
    commonName: 'androidtv_direct',
    serial: BigInt.parse('1234567890abcdef', radix: 16),
    notBefore: now,
    validity: const Duration(days: 3650),
  );
  final pem = Pem.encode('CERTIFICATE', der);

  late Directory temp;
  setUpAll(() async => temp = await Directory.systemTemp.createTemp('cert'));
  tearDownAll(() => temp.delete(recursive: true));

  Future<String> openssl(List<String> args) => Tools.run(Tools.openssl!, args);
  final skip = Tools.skipUnless(Tools.openssl, 'openssl');

  test('has the fields TVs need', () async {
    final file = File('${temp.path}/a.pem')..writeAsStringSync(pem);
    final text = await openssl(['x509', '-noout', '-text', '-in', file.path]);
    expect(text, contains('Version: 3 (0x2)'));
    expect(text, contains('(0x1234567890abcdef)'));
    expect(text, contains('Signature Algorithm: sha256WithRSAEncryption'));
    expect(text, contains('Issuer: CN=androidtv_direct'));
    expect(text, contains('Subject: CN=androidtv_direct'));
    expect(text, contains('Not Before: Nov 25 12:30:45 2026 GMT'));
    expect(text, contains('Not After : Nov 22 12:30:45 2036 GMT'));
    expect(text, contains('X509v3 Basic Constraints: critical'));
    expect(text, contains('CA:TRUE'));
    expect(text, contains('Digital Signature, Certificate Sign, CRL Sign'));
    expect(text, isNot(contains('Subject Alternative Name')));
  }, skip: skip);

  test('verifies as a self-signed authority', () async {
    final file = File('${temp.path}/b.pem')..writeAsStringSync(pem);
    final at = '${now.millisecondsSinceEpoch ~/ 1000 + 60}';
    expect((await openssl(['verify', '-attime', at, '-CAfile', file.path, file.path])).trim(), endsWith(': OK'));
  }, skip: skip);

  test('OpenSSL reads the PKCS#8 key and finds the same modulus', () async {
    final file = File('${temp.path}/key.pem')..writeAsStringSync(Pem.encode('PRIVATE KEY', key.toPkcs8()));
    final modulus = await openssl(['rsa', '-in', file.path, '-noout', '-modulus']);
    expect(BigInt.parse(modulus.trim().split('=').last, radix: 16), key.modulus);
  }, skip: skip);
}
