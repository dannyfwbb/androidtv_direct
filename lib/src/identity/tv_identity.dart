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
  TvIdentity._(Uint8List certificateDer, this.fingerprint, this.publicKey, this._subject)
    : certificateDer = certificateDer.asUnmodifiableView();

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

  final TvSubject _subject;

  /// The certificate, DER. Read-only.
  final Uint8List certificateDer;

  /// The SHA-256 of the TV's public key (its `SubjectPublicKeyInfo`), lower-case hex.
  final String fingerprint;

  /// The TV's public key, for the pairing secret.
  @internal
  final RsaPublicKey publicKey;

  /// The product name, such as `sdk_google_atv_amati_x86`.
  String? get product => _subject.product;

  /// The device name, such as `emulator_x86_arm`.
  String? get device => _subject.device;

  /// The model, such as `SHIELD Android TV`: a name to show before pairing.
  String? get model => _subject.model;

  /// The network (MAC) address, `AA:BB:CC:DD:EE:FF`, which Wake-on-LAN needs. Some TVs leave it out.
  String? get macAddress => _subject.macAddress;

  /// Whether the certificate is one a TV's remote service makes (see [TvSubject.isRemoteService]).
  @internal
  bool get isRemoteService => _subject.isRemoteService;

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
  const TvSubject({this.product, this.device, this.model, this.macAddress, this.isRemoteService = false});

  /// Reads the subject's common name and dnQualifier.
  factory TvSubject.parse({String? commonName, String? dnQualifier}) {
    final (names: qualifier, :tail) = _splitRunOn(dnQualifier);
    final service = _afterPrefix(commonName) ?? tail;
    if (service == null) return TvSubject.fromNames(qualifier);
    final segments = service.isEmpty ? <String>[] : service.split('/');
    final mac = segments.isNotEmpty && _mac.hasMatch(segments.last) ? segments.last.toUpperCase() : null;
    final names = mac == null ? segments : segments.sublist(0, segments.length - 1);
    return TvSubject.fromNames(names.isEmpty ? qualifier : names.join('/'), macAddress: mac, isRemoteService: true);
  }

  /// `<product>/<device>/<model>` and the address; names that are not there are `null`.
  factory TvSubject.fromNames(String? names, {String? macAddress, bool isRemoteService = false}) {
    final parts = names?.split('/') ?? const <String>[];
    if (parts.length < 3) return TvSubject(macAddress: macAddress, isRemoteService: isRemoteService);
    return TvSubject(
      product: _named(parts[0]),
      device: _named(parts[1]),
      model: _named(parts.sublist(2).join('/')),
      macAddress: macAddress,
      isRemoteService: isRemoteService,
    );
  }

  static const String _prefix = 'atvremote';
  static const String _runOn = '/CN=$_prefix/';
  static final RegExp _mac = RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$');

  /// The product name.
  final String? product;

  /// The device name.
  final String? device;

  /// The model.
  final String? model;

  /// The network address, upper-case.
  final String? macAddress;

  /// Whether the subject has the `atvremote` common name a TV's remote service writes: `atvremote`, `atvremote/…`, or
  /// a dnQualifier that runs on into `/CN=atvremote/…`.
  final bool isRemoteService;

  /// What follows `atvremote/` in [commonName], `''` for a bare `atvremote`, or `null` for any other common name.
  static String? _afterPrefix(String? commonName) => switch (commonName) {
    _prefix => '',
    final name? when name.startsWith('$_prefix/') => name.substring(_prefix.length + 1),
    _ => null,
  };

  /// A dnQualifier split where it runs on into `/CN=atvremote/`: the names before, and what follows (or `null`).
  static ({String? names, String? tail}) _splitRunOn(String? dnQualifier) {
    final at = dnQualifier?.indexOf(_runOn) ?? -1;
    if (at < 0) return (names: dnQualifier, tail: null);
    return (names: dnQualifier!.substring(0, at), tail: dnQualifier.substring(at + _runOn.length));
  }

  static String? _named(String part) => part.isEmpty ? null : part;
}
