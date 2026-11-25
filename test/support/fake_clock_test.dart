// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:test/test.dart';

import 'fake_clock.dart';

void main() {
  test('fires timers in deadline order with time set to each deadline', () {
    final clock = FakeClock();
    final fired = <String>[];
    clock
      ..timer(const Duration(seconds: 3), () => fired.add('c@${clock.elapsed.inSeconds}'))
      ..timer(const Duration(seconds: 1), () => fired.add('a@${clock.elapsed.inSeconds}'))
      ..timer(const Duration(seconds: 1), () => fired.add('b@${clock.elapsed.inSeconds}'));
    clock.advance(const Duration(seconds: 2));
    expect(fired, ['a@1', 'b@1']);
    expect(clock.elapsed, const Duration(seconds: 2));
    clock.advance(const Duration(seconds: 5));
    expect(fired, ['a@1', 'b@1', 'c@3']);
    expect(clock.pendingTimers, 0);
  });

  test('cancelled timers never fire', () {
    final clock = FakeClock();
    var fired = false;
    final timer = clock.timer(const Duration(seconds: 1), () => fired = true);
    expect(timer.isActive, isTrue);
    timer.cancel();
    clock.advance(const Duration(seconds: 2));
    expect(fired, isFalse);
    expect(timer.isActive, isFalse);
  });

  test('a timer started by a callback fires in the same advance if due', () {
    final clock = FakeClock();
    final fired = <int>[];
    clock.timer(const Duration(seconds: 1), () {
      fired.add(clock.elapsed.inSeconds);
      clock.timer(const Duration(seconds: 1), () => fired.add(clock.elapsed.inSeconds));
    });
    clock.advance(const Duration(seconds: 5));
    expect(fired, [1, 2]);
  });
}
