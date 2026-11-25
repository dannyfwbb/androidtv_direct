// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';

import 'hex.dart';

/// One line of `test/fixtures/remote/messages.txt`.
typedef RecordedMessage = ({bool outgoing, int port, String name, Uint8List bytes});

/// The path of a file under `test/fixtures/`.
String fixturePath(String relative) => 'test/fixtures/$relative';

/// Every message in the recording [file] under `test/fixtures/remote/`, in file order.
List<RecordedMessage> recordedMessages([String file = 'messages.txt']) => [
  for (final line in File(fixturePath('remote/$file')).readAsLinesSync())
    if (line.isNotEmpty && !line.startsWith('#')) _parse(line),
];

/// The recorded message called [name] that went in the given direction, from [file].
RecordedMessage recorded(String name, {required bool outgoing, String file = 'messages.txt'}) =>
    recordedMessages(file).singleWhere((m) => m.name == name && m.outgoing == outgoing);

/// The bytes of the message called [name] in the package's own session recording (`session.txt`).
Uint8List sessionMessage(String name, {required bool outgoing}) =>
    recorded(name, outgoing: outgoing, file: 'session.txt').bytes;

RecordedMessage _parse(String line) {
  final [direction, port, name, bytes] = line.split(' ');
  return (outgoing: direction == 'out', port: int.parse(port), name: name, bytes: unhex(bytes));
}

/// A test identity from `test/fixtures/identities/`: the certificate and the private key, as PEM.
typedef TestIdentity = ({String certificatePem, String privateKeyPem});

/// The DER of the single PEM block in the fixture file at [path].
Uint8List pemFixtureDer(String path) => pemOf(File(fixturePath(path)).readAsStringSync());

/// The DER of the single PEM block in [pem].
Uint8List pemOf(String pem) => Pem.decode(pem).single.der;

/// The private key of the test identity called [name].
RsaPrivateKey testKey(String name) => RsaPrivateKey.fromPkcs8(Pem.decode(testIdentity(name).privateKeyPem).single.der);

/// The test identity called [name] as a client identity; the fake TV trusts `client`.
TvClientIdentity testClient([String name = 'client']) =>
    TvClientIdentity.fromPem(testIdentity(name).certificatePem + testIdentity(name).privateKeyPem);

/// [code] with its first byte changed, so it fails the check against the keys.
String codeWithWrongCheckByte(String code) {
  final first = (int.parse(code.substring(0, 2), radix: 16) + 1) % 256;
  return first.toRadixString(16).padLeft(2, '0') + code.substring(2);
}

/// The test identity called [name] (`tv`, `client` or `other`).
TestIdentity testIdentity(String name) {
  final pem = File(fixturePath('identities/$name.pem')).readAsStringSync();
  final split = pem.indexOf('-----BEGIN PRIVATE KEY-----');
  return (certificatePem: pem.substring(0, split), privateKeyPem: pem.substring(split));
}
