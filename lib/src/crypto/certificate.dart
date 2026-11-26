// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/crypto/certificate.dart.

import 'dart:typed_data';

import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:crypto/crypto.dart' as hashes;

/// Builds a self-signed X.509 v3 certificate for [key]: subject and issuer `CN=[commonName]`, [serial], valid from
/// [notBefore] (to the second) for [validity], `basicConstraints` CA (critical), `keyUsage` digitalSignature,
/// keyCertSign and cRLSign (critical), `subjectKeyIdentifier`, signed with SHA-256.
///
/// One version of the remote service was seen to refuse the remote port to a client certificate without CA (pairing
/// still worked); the current one accepts it. Nothing else in the certificate has been seen to matter to TVs.
Uint8List buildCertificate(
  RsaPrivateKey key, {
  required String commonName,
  required BigInt serial,
  required DateTime notBefore,
  required Duration validity,
}) {
  final start = DateTime.fromMillisecondsSinceEpoch(notBefore.millisecondsSinceEpoch ~/ 1000 * 1000, isUtc: true);
  final name = Der.sequence([
    Der.set([
      Der.sequence([Der.objectIdentifier(commonNameOid), Der.utf8String(commonName)]),
    ]),
  ]);
  final algorithm = Der.algorithm(sha256WithRsaOid);
  final tbs = Der.sequence([
    Der.explicit(0, Der.smallInteger(2)),
    Der.integer(serial),
    algorithm,
    name,
    Der.sequence([Der.time(start), Der.time(start.add(validity))]),
    name,
    key.subjectPublicKeyInfo(),
    _extensions(key),
  ]);
  return Der.sequence([tbs, algorithm, Der.bitString(key.signSha256(tbs))]);
}

Uint8List _extensions(RsaPrivateKey key) => Der.explicit(
  3,
  Der.sequence([
    _extension('2.5.29.19', critical: true, value: Der.sequence([Der.boolean(true)])),
    // digitalSignature (bit 0), keyCertSign (5), cRLSign (6): the bit string 0x86 with one unused trailing bit.
    _extension('2.5.29.15', critical: true, value: Der.element(Der.tagBitString, const [0x01, 0x86])),
    _extension('2.5.29.14', critical: false, value: Der.octetString(hashes.sha1.convert(key.publicKeyPkcs1()).bytes)),
  ]),
);

Uint8List _extension(String oid, {required bool critical, required List<int> value}) =>
    Der.sequence([Der.objectIdentifier(oid), if (critical) Der.boolean(true), Der.octetString(value)]);
