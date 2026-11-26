// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Connects to a TV paired by androidtv_direct_example.dart, which keeps the client's identity in `identity.pem` and
// the TV's fingerprint in `tv-<host>.fingerprint` in the working directory.

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

/// A session with [host], asking for [features] besides the defaults. Exits with a hint when the TV was not paired.
Future<TvRemote> connectPaired(String host, {Set<TvFeature> features = const {}}) async {
  final identityFile = File('identity.pem');
  final fingerprintFile = File('tv-$host.fingerprint');
  if (!identityFile.existsSync() || !fingerprintFile.existsSync()) {
    stderr.writeln('Pair first: dart run example/androidtv_direct_example.dart $host');
    exit(1);
  }
  return TvRemote.connect(
    host,
    identity: TvClientIdentity.fromPem(identityFile.readAsStringSync()),
    fingerprint: fingerprintFile.readAsStringSync().trim(),
    features: {...TvFeature.defaults, ...features},
  );
}
