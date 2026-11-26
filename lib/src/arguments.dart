// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

// Checks of what the public calls take, so a wrong argument fails as an ArgumentError at the call instead of as a
// confusing failure later (a zero idle timeout ending every session, a mistyped fingerprint refusing every TV).

/// [value], which must be longer than zero (a timeout, a validity).
Duration checkPositive(Duration value, String name) {
  if (value <= Duration.zero) throw ArgumentError.value('$value', name, 'must be longer than zero');
  return value;
}

/// [host]: a host name or an address as text (without spaces around it), or an [InternetAddress].
Object checkHost(Object host) => switch (host) {
  InternetAddress() => host,
  String() when host.isNotEmpty && host.trim() == host => host,
  _ => throw ArgumentError.value(host, 'host', 'must be a host name, an address as text, or an InternetAddress'),
};

/// [text], which must hold more than spaces.
String checkNotBlank(String text, String name) {
  if (text.trim().isEmpty) throw ArgumentError.value(text, name, 'is blank');
  return text;
}

/// [port], from 1 to 65535.
int checkPort(int port) => RangeError.checkValueInInterval(port, 1, 65535, 'port');

/// A key fingerprint as `TvPairingResult.fingerprint` gives it: 64 hexadecimal characters, in either case; returned
/// in lower case, as the package computes them.
String checkFingerprint(String fingerprint, String name) {
  if (!_sha256Hex.hasMatch(fingerprint)) {
    throw ArgumentError.value(fingerprint, name, 'must be 64 hexadecimal characters (a SHA-256)');
  }
  return fingerprint.toLowerCase();
}

final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');

/// [host]:[port] for messages: an [InternetAddress] as its address, IPv6 in brackets.
String describeTarget(Object host, int port) {
  final text = host is InternetAddress ? host.address : '$host';
  return text.contains(':') ? '[$text]:$port' : '$text:$port';
}
