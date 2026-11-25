// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/certificate.dart';
import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:meta/meta.dart';

/// The client's identity: an RSA key and a self-signed certificate for it.
///
/// A TV remembers the certificate when it pairs with the client and recognises the client by it afterwards. Make one
/// per app installation with [generate], keep [toPem] in the platform's protected storage, and bring it back with
/// [TvClientIdentity.fromPem]. Whoever has a copy can control every TV paired with it. One identity serves any number
/// of TVs.
final class TvClientIdentity {
  TvClientIdentity._(this._key, Uint8List certificateDer, this._certificate)
    : certificateDer = certificateDer.asUnmodifiableView();

  /// Reads an identity written by [toPem]: a certificate and its private key (PKCS#8 or PKCS#1), in either order.
  ///
  /// Throws [FormatException] if [pem] does not hold exactly one certificate and one RSA private key, or if the key is
  /// not the one the certificate certifies.
  factory TvClientIdentity.fromPem(String pem) {
    final blocks = Pem.decode(pem);
    final certificate = _single(blocks, {'CERTIFICATE'}).der;
    final key = _readKey(_single(blocks, {'PRIVATE KEY', 'RSA PRIVATE KEY'}));
    final info = CertificateInfo.parse(certificate);
    if (info.rsaPublicKey != key.publicKey) throw const FormatException('The key does not match the certificate');
    return TvClientIdentity._(key, certificate, info);
  }

  /// Makes a new identity: an RSA-2048 key and a certificate valid from [now] for [validity].
  ///
  /// TVs remember paired clients by the name in their certificate (seen on remote service 7.00): pairing a client whose
  /// certificate has the same name as an earlier one replaces the earlier one on that TV. The default [commonName] is therefore unique per
  /// identity (`androidtv_direct/` and 16 random hexadecimal digits); a name given here must be unique as well.
  ///
  /// Generating the key takes a fraction of a second on a desktop, possibly more on a phone; it runs in a separate
  /// isolate. Throws [ArgumentError] if [validity] is not positive or [commonName] is empty.
  static Future<TvClientIdentity> generate({
    required DateTime now,
    String? commonName,
    Duration validity = const Duration(days: 3650),
  }) async {
    if (commonName != null && commonName.isEmpty) throw ArgumentError.value(commonName, 'commonName', 'is empty');
    if (validity <= Duration.zero) throw ArgumentError.value(validity, 'validity', 'must be positive');
    final key = await Isolate.run(RsaPrivateKey.generate);
    final certificate = buildCertificate(
      key,
      commonName: commonName ?? 'androidtv_direct/${hexEncode(randomBytes(8))}',
      serial: _randomSerial(),
      notBefore: now,
      validity: validity,
    );
    return TvClientIdentity._(key, certificate, CertificateInfo.parse(certificate));
  }

  final RsaPrivateKey _key;
  final CertificateInfo _certificate;

  /// The certificate, DER. Read-only.
  final Uint8List certificateDer;

  /// The SHA-256 fingerprint of the client's public key, lower-case hex: a name for it in logs.
  String get fingerprint => _certificate.fingerprint;

  /// The certificate and the private key (PKCS#8) as PEM, for the app to store. It contains the private key.
  String toPem() => '$_certificatePem$_privateKeyPem';

  String get _certificatePem => Pem.encode('CERTIFICATE', certificateDer);

  String get _privateKeyPem => Pem.encode('PRIVATE KEY', _key.toPkcs8());

  /// The public key, for the pairing secret.
  @internal
  RsaPublicKey get publicKey => _key.publicKey;

  /// A TLS context that presents this identity and trusts no authority: TVs' certificates are self-signed and are
  /// checked by fingerprint instead.
  @internal
  SecurityContext securityContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(_certificatePem))
    ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));

  static PemBlock _single(List<PemBlock> blocks, Set<String> labels) {
    final matching = blocks.where((block) => labels.contains(block.label)).toList();
    if (matching.length != 1) {
      throw FormatException('Expected one ${labels.join(' or ')} block, found ${matching.length}');
    }
    return matching.single;
  }

  static RsaPrivateKey _readKey(PemBlock block) =>
      block.label == 'PRIVATE KEY' ? RsaPrivateKey.fromPkcs8(block.der) : RsaPrivateKey.fromPkcs1(block.der);

  /// A positive 63-bit serial, so no two clients share one.
  static BigInt _randomSerial() {
    final bytes = randomBytes(8)..[0] &= 0x7f;
    final serial = Der.unsignedValue(bytes);
    return serial == BigInt.zero ? BigInt.one : serial;
  }
}
