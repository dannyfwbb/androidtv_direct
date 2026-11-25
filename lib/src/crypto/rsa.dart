// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/crypto/rsa.dart.

import 'dart:typed_data';

import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/der.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart' as pc;

/// OID of `rsaEncryption`.
const String rsaEncryptionOid = '1.2.840.113549.1.1.1';

/// OID of `sha256WithRSAEncryption`.
const String sha256WithRsaOid = '1.2.840.113549.1.1.11';

/// The modulus size of client keys, in bits: what every client of the protocol uses.
const int rsaKeyBits = 2048;

/// An RSA public key: what the pairing secret hashes and what a certificate carries.
final class RsaPublicKey {
  /// Creates the key.
  const RsaPublicKey(this.modulus, this.exponent);

  /// The key in a DER `SubjectPublicKeyInfo`. Throws [FormatException] if it is malformed or not an RSA key.
  factory RsaPublicKey.fromSubjectPublicKeyInfo(DerElement spki) {
    final fields = spki.sequence;
    if (fields.length != 2) throw const FormatException('Not a SubjectPublicKeyInfo');
    final algorithm = fields[0].sequence;
    if (algorithm.isEmpty || algorithm.first.objectIdentifier != rsaEncryptionOid) {
      throw const FormatException('Not an RSA public key');
    }
    final key = DerElement.parse(fields[1].bits).sequence;
    if (key.length != 2) throw const FormatException('Not a PKCS#1 RSA public key');
    return RsaPublicKey(key[0].integer, key[1].integer);
  }

  /// n.
  final BigInt modulus;

  /// e.
  final BigInt exponent;

  @override
  bool operator ==(Object other) => other is RsaPublicKey && other.modulus == modulus && other.exponent == exponent;

  @override
  int get hashCode => Object.hash(modulus, exponent);
}

/// An RSA-2048 private key with its CRT parameters.
///
/// Every way in validates the key completely, so a key that exists is consistent: a broken or hostile key file fails on
/// import with a [FormatException] instead of producing wrong signatures later.
///
/// Internal: the public face is `TvClientIdentity`.
final class RsaPrivateKey {
  RsaPrivateKey._({
    required this.modulus,
    required this.publicExponent,
    required this.privateExponent,
    required this.p,
    required this.q,
    required this.dP,
    required this.dQ,
    required this.qInv,
  });

  /// Creates a key from its parameters after checking that they form a valid RSA-2048 key; derives or checks the CRT
  /// values.
  ///
  /// Throws [FormatException] for anything inconsistent: factors that do not multiply to the modulus, a modulus that is
  /// not 2048 bits, an even or out-of-range exponent, a private exponent that does not invert the public one, or CRT
  /// values that do not match.
  factory RsaPrivateKey({
    required BigInt modulus,
    required BigInt publicExponent,
    required BigInt privateExponent,
    required BigInt p,
    required BigInt q,
    BigInt? dP,
    BigInt? dQ,
    BigInt? qInv,
  }) {
    final one = BigInt.one;
    void check(bool ok, String problem) {
      if (!ok) throw FormatException('Invalid RSA key: $problem');
    }

    check(modulus.bitLength == rsaKeyBits, 'modulus is not $rsaKeyBits bits');
    check(modulus.isOdd, 'even modulus');
    check(p > one && q > one && p != q, 'bad prime factors');
    check(p * q == modulus, 'p * q does not equal the modulus');
    check(p.gcd(q) == one, 'factors share a divisor');
    check(
      publicExponent.isOdd && publicExponent >= BigInt.from(3) && publicExponent.bitLength <= 32,
      'public exponent must be odd, at least 3 and fit in 32 bits',
    );
    final pMinus1 = p - one;
    final qMinus1 = q - one;
    final lambda = pMinus1 * qMinus1 ~/ pMinus1.gcd(qMinus1);
    check(
      privateExponent > one && privateExponent < modulus && (publicExponent * privateExponent) % lambda == one,
      'private exponent does not invert the public exponent',
    );
    final derivedDP = privateExponent % pMinus1;
    final derivedDQ = privateExponent % qMinus1;
    final derivedQInv = q.modInverse(p);
    check(
      (dP ?? derivedDP) == derivedDP && (dQ ?? derivedDQ) == derivedDQ && (qInv ?? derivedQInv) == derivedQInv,
      'CRT parameters do not match',
    );
    return RsaPrivateKey._(
      modulus: modulus,
      publicExponent: publicExponent,
      privateExponent: privateExponent,
      p: p,
      q: q,
      dP: derivedDP,
      dQ: derivedDQ,
      qInv: derivedQInv,
    );
  }

  /// Generates an RSA-2048 key with exponent 65537.
  ///
  /// CPU-heavy (a fraction of a second on a desktop, possibly more on a phone): call it from an isolate.
  factory RsaPrivateKey.generate() {
    final random = pc.FortunaRandom()..seed(pc.KeyParameter(randomBytes(32)));
    final generator = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(pc.RSAKeyGeneratorParameters(BigInt.from(65537), rsaKeyBits, 64), random));
    final pair = generator.generateKeyPair();
    final private = pair.privateKey;
    return RsaPrivateKey(
      modulus: private.modulus!,
      publicExponent: pair.publicKey.publicExponent!,
      privateExponent: private.privateExponent!,
      p: private.p!,
      q: private.q!,
    );
  }

  /// Parses a DER `RSAPrivateKey` (PKCS#1, two primes).
  ///
  /// Throws [FormatException] for anything else or for an invalid key.
  factory RsaPrivateKey.fromPkcs1(List<int> der) {
    final fields = DerElement.parse(der).sequence;
    if (fields.length != 9 || fields[0].integer != BigInt.zero) {
      throw const FormatException('Not a two-prime PKCS#1 RSA private key');
    }
    return RsaPrivateKey(
      modulus: fields[1].integer,
      publicExponent: fields[2].integer,
      privateExponent: fields[3].integer,
      p: fields[4].integer,
      q: fields[5].integer,
      dP: fields[6].integer,
      dQ: fields[7].integer,
      qInv: fields[8].integer,
    );
  }

  /// Parses a DER `PrivateKeyInfo` (PKCS#8) holding an RSA key.
  ///
  /// Throws [FormatException] for any other content or an invalid key.
  factory RsaPrivateKey.fromPkcs8(List<int> der) {
    final fields = DerElement.parse(der).sequence;
    if (fields.length < 3 || fields[0].integer != BigInt.zero) {
      throw const FormatException('Not a PKCS#8 PrivateKeyInfo');
    }
    final algorithm = fields[1].sequence;
    if (algorithm.isEmpty ||
        algorithm.first.objectIdentifier != rsaEncryptionOid ||
        algorithm.length > 2 ||
        (algorithm.length == 2 && algorithm[1].tag != Der.tagNull)) {
      throw const FormatException('Not an RSA PKCS#8 key');
    }
    return RsaPrivateKey.fromPkcs1(fields[2].octets);
  }

  /// n.
  final BigInt modulus;

  /// e.
  final BigInt publicExponent;

  /// d.
  final BigInt privateExponent;

  /// First prime.
  final BigInt p;

  /// Second prime.
  final BigInt q;

  /// d mod (p − 1).
  final BigInt dP;

  /// d mod (q − 1).
  final BigInt dQ;

  /// q⁻¹ mod p.
  final BigInt qInv;

  /// The public half.
  RsaPublicKey get publicKey => RsaPublicKey(modulus, publicExponent);

  /// Modulus size in bytes (256).
  int get modulusLength => (modulus.bitLength + 7) ~/ 8;

  /// DER `RSAPrivateKey` (PKCS#1).
  Uint8List toPkcs1() => Der.sequence([
    Der.smallInteger(0),
    Der.integer(modulus),
    Der.integer(publicExponent),
    Der.integer(privateExponent),
    Der.integer(p),
    Der.integer(q),
    Der.integer(dP),
    Der.integer(dQ),
    Der.integer(qInv),
  ]);

  /// DER `PrivateKeyInfo` (PKCS#8).
  Uint8List toPkcs8() => Der.sequence([Der.smallInteger(0), _rsaAlgorithm(), Der.octetString(toPkcs1())]);

  /// DER `SubjectPublicKeyInfo` of the public half.
  Uint8List subjectPublicKeyInfo() => Der.sequence([_rsaAlgorithm(), Der.bitString(publicKeyPkcs1())]);

  /// DER `RSAPublicKey` (PKCS#1): modulus and exponent.
  Uint8List publicKeyPkcs1() => Der.sequence([Der.integer(modulus), Der.integer(publicExponent)]);

  /// The private-key operation m^d mod n.
  ///
  /// Blinded with a fresh random factor against timing attacks on the CRT, and verified with the public exponent
  /// before the result leaves, against faults.
  BigInt privateOperation(BigInt message) {
    if (message.isNegative || message >= modulus) throw ArgumentError('RSA input out of range');
    final r = _blindingFactor();
    final blinded = (message * r.modPow(publicExponent, modulus)) % modulus;
    final m1 = blinded.modPow(dP, p);
    final m2 = blinded.modPow(dQ, q);
    final h = (qInv * (m1 - m2)) % p;
    final signature = ((m2 + h * q) * r.modInverse(modulus)) % modulus;
    if (signature.modPow(publicExponent, modulus) != message) {
      throw StateError('RSA private operation failed its own verification');
    }
    return signature;
  }

  /// RSASSA-PKCS1-v1_5 over a [digest] that is already hashed, prefixed with the algorithm's [digestInfoPrefix] (RFC
  /// 8017 9.2).
  Uint8List signDigest(List<int> digestInfoPrefix, List<int> digest) {
    final t = [...digestInfoPrefix, ...digest];
    final k = modulusLength;
    if (t.length + 11 > k) throw ArgumentError('Digest too long for the key');
    final encoded = Uint8List(k)
      ..[1] = 0x01
      ..fillRange(2, k - t.length - 1, 0xff)
      ..[k - t.length - 1] = 0x00
      ..setRange(k - t.length, k, t);
    final signature = privateOperation(Der.unsignedValue(encoded));
    return Der.unsignedBytes(signature, length: k);
  }

  /// RSASSA-PKCS1-v1_5 with SHA-256 over [message].
  Uint8List signSha256(List<int> message) => signDigest(sha256DigestInfoPrefix, hashes.sha256.convert(message).bytes);

  /// A random r in [2, n − 1] coprime with n.
  BigInt _blindingFactor() {
    while (true) {
      final r = Der.unsignedValue(randomBytes(modulusLength)) % modulus;
      if (r > BigInt.one && r.gcd(modulus) == BigInt.one) return r;
    }
  }

  static Uint8List _rsaAlgorithm() => Der.sequence([Der.objectIdentifier(rsaEncryptionOid), Der.nullValue()]);
}

/// DER prefix of `DigestInfo` for SHA-256 (RFC 8017 9.2, note 1).
const List<int> sha256DigestInfoPrefix = [
  0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, //
  0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
  0x00, 0x04, 0x20,
];
