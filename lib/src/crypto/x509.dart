// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:crypto/crypto.dart' as hashes;

/// OID of the common name (CN) attribute.
const String commonNameOid = '2.5.4.3';

/// OID of the distinguished name qualifier (dnQualifier) attribute.
const String dnQualifierOid = '2.5.4.46';

/// The tag of `[0]`, the optional version at the start of a certificate's fields.
const int _versionTag = 0xa0;

/// What this package reads from an X.509 certificate: the subject and the public key. Nothing is verified.
final class CertificateInfo {
  CertificateInfo._(this.subject, this.subjectPublicKeyInfo);

  /// Reads a DER certificate. Throws [FormatException] if it is not one.
  factory CertificateInfo.parse(List<int> der) {
    final certificate = DerElement.parse(der).sequence;
    if (certificate.length != 3) throw const FormatException('Not an X.509 certificate');
    final tbs = certificate.first.sequence;
    // The version ([0]) is optional; serial, signature algorithm, issuer and validity come before the subject.
    final fields = tbs.isNotEmpty && tbs.first.tag == _versionTag ? tbs.sublist(1) : tbs;
    if (fields.length < 6) throw const FormatException('Not an X.509 certificate');
    return CertificateInfo._(_attributes(fields[4]), fields[5].encoded);
  }

  /// The subject's attributes in order, as (OID, text) pairs. Attributes whose value is not text are left out.
  final List<(String, String)> subject;

  /// The DER `SubjectPublicKeyInfo`.
  final Uint8List subjectPublicKeyInfo;

  /// The first subject attribute with [oid], or `null`.
  String? attribute(String oid) => subject.where((a) => a.$1 == oid).firstOrNull?.$2;

  /// The public key. Throws [FormatException] if it is not an RSA key.
  RsaPublicKey get rsaPublicKey => RsaPublicKey.fromSubjectPublicKeyInfo(DerElement.parse(subjectPublicKeyInfo));

  /// The SHA-256 of [subjectPublicKeyInfo], lower-case hex: the key's fingerprint.
  String get fingerprint => spkiFingerprint(subjectPublicKeyInfo);

  static List<(String, String)> _attributes(DerElement name) => [
    for (final rdn in name.sequence)
      for (final attribute in rdn.children) ?_attribute(attribute),
  ];

  static (String, String)? _attribute(DerElement attribute) {
    final parts = attribute.sequence;
    if (parts.length != 2) throw const FormatException('Malformed name attribute');
    try {
      return (parts[0].objectIdentifier, parts[1].text);
    } on FormatException {
      return null;
    }
  }
}

/// The fingerprint of the key in a DER certificate, or `null` if the certificate cannot be read.
String? certificateFingerprint(List<int> der) {
  try {
    return CertificateInfo.parse(der).fingerprint;
  } on FormatException {
    return null;
  }
}

/// The SHA-256 of a DER `SubjectPublicKeyInfo`, lower-case hex.
String spkiFingerprint(List<int> subjectPublicKeyInfo) => hexEncode(hashes.sha256.convert(subjectPublicKeyInfo).bytes);
