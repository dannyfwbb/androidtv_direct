// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';
import 'fake_session.dart';
import 'fake_tv.dart';
import 'fixtures.dart';

/// A client connected to a fake TV that plays [session], on a fake clock; closed when the test ends.
final class FakeRemote {
  FakeRemote._(this.session, this.clock, this.remote);

  /// Starts a fake TV serving [session] (a fresh one by default) and connects to it asking for [features].
  static Future<FakeRemote> connect({Set<TvFeature> features = TvFeature.defaults, FakeSession? session}) async {
    final fake = session ?? FakeSession();
    final clock = FakeClock();
    final tv = await startFakeTv(onRemote: fake.serve);
    final remote = await TvRemote.connect(
      InternetAddress.loopbackIPv4,
      port: tv.remotePort,
      identity: testClient(),
      fingerprint: null,
      features: features,
      clock: clock,
    );
    addTearDown(remote.close);
    return FakeRemote._(fake, clock, remote);
  }

  /// The TV's side.
  final FakeSession session;

  /// The client's clock.
  final FakeClock clock;

  /// The client.
  final TvRemote remote;
}
