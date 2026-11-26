// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/round_trip.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:test/test.dart';

import '../support/fake_session.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';

const Duration ms = Duration(milliseconds: 1);

void main() {
  test('nothing measured: the floor', () {
    final roundTrip = RoundTrip();
    expect((roundTrip.smoothed, roundTrip.timeout), (null, Duration.zero));
    expect(roundTrip.waitFor(ms * 1500), ms * 1500);
  });

  test('the first answer sets the time and half of it as the variation (RFC 6298 2.2)', () {
    final roundTrip = RoundTrip()..add(ms * 200);
    expect((roundTrip.smoothed, roundTrip.timeout), (ms * 200, ms * 600));
    expect(roundTrip.waitFor(ms * 100), ms * 600);
    expect(roundTrip.waitFor(ms * 1500), ms * 1500);
  });

  test('later answers move it by an eighth, the variation by a quarter of the difference (RFC 6298 2.3)', () {
    final roundTrip = RoundTrip()
      ..add(ms * 200)
      ..add(ms * 600);
    // Variation: 3/4 · 100 + 1/4 · 400 = 175; smoothed: 7/8 · 200 + 1/8 · 600 = 250.
    expect(roundTrip.smoothed, ms * 250);
    expect(roundTrip.timeout, ms * (250 + 4 * 175));
  });

  test('steady answers bring the wait close to them', () {
    final roundTrip = RoundTrip();
    for (var i = 0; i < 50; i++) {
      roundTrip.add(ms * 100);
    }
    expect(roundTrip.timeout.inMilliseconds, inInclusiveRange(100, 105));
  });

  test('one answer measured across a pause, or a slow first one, cannot make the waits longer than the ceiling', () {
    final roundTrip = RoundTrip();
    for (var i = 0; i < 20; i++) {
      roundTrip.add(ms * 50);
    }
    roundTrip.add(const Duration(minutes: 5));
    expect(roundTrip.timeout, lessThanOrEqualTo(RoundTrip.ceiling));
    for (var i = 0; i < 20; i++) {
      roundTrip.add(ms * 50);
    }
    expect(roundTrip.timeout, lessThan(const Duration(seconds: 1)), reason: 'it recovers');
    expect((RoundTrip()..add(const Duration(seconds: 9))).timeout, RoundTrip.ceiling);
    expect(
      (RoundTrip()..add(const Duration(seconds: 9))).waitFor(const Duration(seconds: 30)),
      const Duration(seconds: 30),
    );
  });

  test('a session knows the round trip once it started', () async {
    final fake = FakeSession()..latency = ms * 120;
    final tv = await startFakeTv(onRemote: fake.serve);
    final socket = await TvSocket.connect(
      InternetAddress.loopbackIPv4,
      tv.remotePort,
      context: testClient().securityContext(),
      timeout: const Duration(seconds: 5),
    );
    final session = RemoteSession(
      socket,
      TvFeature.defaults,
      clock: TvClock.system,
      idleTimeout: const Duration(seconds: 16),
    );
    addTearDown(session.close);
    await session.start(const Duration(seconds: 5));
    expect(session.roundTrip.smoothed!.inMilliseconds, inInclusiveRange(110, 400));
  });
}
