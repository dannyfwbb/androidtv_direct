// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/remote/watchdog.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';

void main() {
  const limit = Duration(seconds: 16);

  test('fires once after the limit without activity', () {
    final clock = FakeClock();
    var fired = 0;
    Watchdog(clock, limit, () => fired++);
    clock.advance(const Duration(seconds: 15));
    expect(fired, 0);
    clock.advance(const Duration(seconds: 1));
    expect(fired, 1);
    clock.advance(const Duration(minutes: 1));
    expect((fired, clock.pendingTimers), (1, 0));
  });

  test('activity moves the deadline, as often as it happens', () {
    final clock = FakeClock();
    final firedAt = <Duration>[];
    final watchdog = Watchdog(clock, limit, () => firedAt.add(clock.elapsed));
    for (var i = 0; i < 5; i++) {
      clock.advance(const Duration(seconds: 10));
      watchdog.touch();
    }
    clock.advance(const Duration(seconds: 40));
    expect(firedAt, [const Duration(seconds: 66)]);
  });

  test('cancel stops it', () {
    final clock = FakeClock();
    var fired = false;
    Watchdog(clock, limit, () => fired = true).cancel();
    clock.advance(const Duration(minutes: 1));
    expect((fired, clock.pendingTimers), (false, 0));
  });
}
