// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'hex.dart';

/// One line of `test/fixtures/remote/messages.txt`.
typedef RecordedMessage = ({bool outgoing, int port, String name, Uint8List bytes});

/// The path of a file under `test/fixtures/`.
String fixturePath(String relative) => 'test/fixtures/$relative';

/// Every message in `test/fixtures/remote/messages.txt`, in file order.
List<RecordedMessage> recordedMessages() => [
  for (final line in File(fixturePath('remote/messages.txt')).readAsLinesSync())
    if (line.isNotEmpty && !line.startsWith('#')) _parse(line),
];

/// The recorded message called [name] that went in the given direction.
RecordedMessage recorded(String name, {required bool outgoing}) =>
    recordedMessages().singleWhere((m) => m.name == name && m.outgoing == outgoing);

RecordedMessage _parse(String line) {
  final [direction, port, name, bytes] = line.split(' ');
  return (outgoing: direction == 'out', port: int.parse(port), name: name, bytes: unhex(bytes));
}

/// A test identity from `test/fixtures/identities/`: the certificate and the private key, as PEM.
typedef TestIdentity = ({String certificatePem, String privateKeyPem});

/// The test identity called [name] (`tv`, `client` or `other`).
TestIdentity testIdentity(String name) {
  final pem = File(fixturePath('identities/$name.pem')).readAsStringSync();
  final split = pem.indexOf('-----BEGIN PRIVATE KEY-----');
  return (certificatePem: pem.substring(0, split), privateKeyPem: pem.substring(split));
}
