// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Waits, on real time, until [condition] holds; fails after [timeout].
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
