// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/crypto/rsa.dart';
import 'package:androidtv_direct/src/crypto/x509.dart';
import 'package:meta/meta.dart';

/// What a TV's certificate says about the TV.
///
/// The remote service makes the certificate itself and puts the device's names and network address in its subject.
/// The [fingerprint] identifies the TV's key, which is what pairing proves and what later connections check. The
/// other fields are best-effort: TVs differ in what they write, and an unknown layout leaves them `null`.
final class TvIdentity {
  TvIdentity._(Uint8List certificateDer, this.fingerprint, this._publicKey, TvSubject subject)
    : certificateDer = certificateDer.asUnmodifiableView(),
      product = subject.product,
      device = subject.device,
      model = subject.model,
      macAddress = subject.macAddress;

  /// Reads a TV's DER certificate. Throws [FormatException] if it is not a certificate with an RSA key.
  factory TvIdentity.fromCertificate(List<int> der) {
    final bytes = Uint8List.fromList(der);
    final info = CertificateInfo.parse(bytes);
    final subject = TvSubject.parse(
      commonName: info.attribute(commonNameOid),
      dnQualifier: info.attribute(dnQualifierOid),
    );
    return TvIdentity._(bytes, info.fingerprint, info.rsaPublicKey, subject);
  }

  /// The certificate, DER. Read-only.
  final Uint8List certificateDer;

  /// The SHA-256 of the TV's public key (its `SubjectPublicKeyInfo`), lower-case hex.
  final String fingerprint;

  /// The product name, such as `sdk_google_atv_amati_x86`.
  final String? product;

  /// The device name, such as `emulator_x86_arm`.
  final String? device;

  /// The model, such as `SHIELD Android TV`: a name to show before pairing.
  final String? model;

  /// The network (MAC) address, `AA:BB:CC:DD:EE:FF`, which Wake-on-LAN needs. Some TVs leave it out.
  final String? macAddress;

  final RsaPublicKey _publicKey;

  /// The TV's public key, for the pairing secret.
  @internal
  RsaPublicKey get publicKey => _publicKey;

  @override
  String toString() => 'TvIdentity(${model ?? 'unknown model'}, $fingerprint)';
}

/// The names and address in a TV certificate's subject (internal: [TvIdentity] carries them).
///
/// Layouts seen: `dnQualifier=<product>/<device>/<model>, CN=atvremote/<MAC>`, everything in the common name,
/// `CN=atvremote/<product>/<device>/<model>/<MAC>`, and a dnQualifier that runs on into `/CN=atvremote/<MAC>`. A common
/// name without the `atvremote` prefix is not read. The model is everything after the device, so it may contain `/`.
final class TvSubject {
  /// Creates the description.
  const TvSubject({this.product, this.device, this.model, this.macAddress});

  /// Reads the subject's common name and dnQualifier.
  factory TvSubject.parse({String? commonName, String? dnQualifier}) {
    var qualifier = dnQualifier;
    var tail = _afterPrefix(commonName);
    final runOn = qualifier?.indexOf(_runOn) ?? -1;
    if (runOn >= 0) {
      tail ??= qualifier!.substring(runOn + _runOn.length);
      qualifier = qualifier!.substring(0, runOn);
    }
    final segments = tail == null || tail.isEmpty ? <String>[] : tail.split('/');
    final mac = segments.isNotEmpty && _mac.hasMatch(segments.last) ? segments.removeLast().toUpperCase() : null;
    return TvSubject.fromNames(segments.isNotEmpty ? segments.join('/') : qualifier, mac);
  }

  /// `<product>/<device>/<model>` and the address; names that are not there are `null`.
  factory TvSubject.fromNames(String? names, String? macAddress) {
    final parts = names?.split('/') ?? const <String>[];
    if (parts.length < 3) return TvSubject(macAddress: macAddress);
    String? named(String part) => part.isEmpty ? null : part;
    return TvSubject(
      product: named(parts[0]),
      device: named(parts[1]),
      model: named(parts.sublist(2).join('/')),
      macAddress: macAddress,
    );
  }

  static const String _prefix = 'atvremote';
  static const String _runOn = '/CN=$_prefix/';
  static final RegExp _mac = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

  /// What follows `atvremote/` in [commonName], `''` for a bare `atvremote`, or `null` for any other common name.
  static String? _afterPrefix(String? commonName) {
    if (commonName == _prefix) return '';
    return commonName != null && commonName.startsWith('$_prefix/') ? commonName.substring(_prefix.length + 1) : null;
  }

  /// The product name.
  final String? product;

  /// The device name.
  final String? device;

  /// The model.
  final String? model;

  /// The network address, upper-case.
  final String? macAddress;
}
