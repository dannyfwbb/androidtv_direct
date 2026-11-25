// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

/// The TV the device tests use, from the environment: `ANDROIDTV_DIRECT_TEST_HOST` (required) and
/// `ANDROIDTV_DIRECT_TEST_SERIAL` (the adb serial, to read the screen).
abstract final class TestTv {
  /// The TV's address.
  static String? get host => Platform.environment['ANDROIDTV_DIRECT_TEST_HOST'];

  /// The TV's adb serial.
  static String? get serial => Platform.environment['ANDROIDTV_DIRECT_TEST_SERIAL'];

  /// Skip reason when no TV is configured, or null to run.
  static String? get skip => host == null || serial == null
      ? 'Set ANDROIDTV_DIRECT_TEST_HOST and ANDROIDTV_DIRECT_TEST_SERIAL (see test/device/README.md)'
      : null;

  /// The texts on the TV's screen.
  static Future<List<String>> texts() async {
    await _adb(['shell', 'uiautomator', 'dump', '/sdcard/ui.xml']);
    final xml = await _adb(['shell', 'cat', '/sdcard/ui.xml']);
    return [for (final m in RegExp(r'text="([^"]*)"').allMatches(xml)) m.group(1)!];
  }

  /// The pairing code on screen, or null.
  static Future<String?> code() async => (await texts()).where((t) => RegExp(r'^[0-9A-F]{6}$').hasMatch(t)).firstOrNull;

  /// Waits for a pairing code on screen.
  static Future<String> waitForCode() async {
    for (var i = 0; i < 20; i++) {
      final shown = await code();
      if (shown != null) return shown;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('No pairing code on the screen');
  }

  /// Pairs a fresh identity with the TV, reading the code from its screen; returns it with the TV's fingerprint.
  static Future<(TvClientIdentity, String)> pairFresh() async {
    final identity = await TvClientIdentity.generate(now: DateTime.now());
    final pairing = await TvPairing.start(host!, identity: identity, clientName: 'androidtv_direct test');
    return (identity, (await pairing.finish(await waitForCode())).fingerprint);
  }

  /// The output of `adb shell` [command] on the TV.
  static Future<String> shell(List<String> command) => _adb(['shell', ...command]);

  /// The TV's media volume, from `cmd media_session`.
  static Future<int> mediaVolume() async {
    final out = await shell(['cmd', 'media_session', 'volume', '--stream', '3', '--get']);
    return int.parse(RegExp(r'volume is (\d+)').firstMatch(out)!.group(1)!);
  }

  /// `Awake`, `Asleep` or `Dozing`, from `dumpsys power`.
  static Future<String> wakefulness() async =>
      RegExp(r'mWakefulness=(\w+)').firstMatch(await shell(['dumpsys', 'power']))!.group(1)!;

  /// The activity in front, from `dumpsys activity`.
  static Future<String> resumedActivity() async =>
      RegExp(r'ResumedActivity: (.*)').firstMatch(await shell(['dumpsys', 'activity', 'activities']))?.group(1) ?? '';

  /// Polls [read] every 200 ms until it gives [expected]; returns the last value read (within [timeout]).
  static Future<T> waitFor<T>(
    Future<T> Function() read,
    T expected, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var value = await read();
    while (value != expected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      value = await read();
    }
    return value;
  }

  /// Sets the TV's media volume directly, to restore it after a test.
  static Future<void> setMediaVolume(int level) =>
      shell(['cmd', 'media_session', 'volume', '--stream', '3', '--set', '$level']);

  /// Wakes the TV if it is not awake, to restore it after a test.
  static Future<void> wake() async {
    if (await wakefulness() != 'Awake') await shell(['input', 'keyevent', 'KEYCODE_WAKEUP']);
  }

  static Future<String> _adb(List<String> args) async {
    final adb = Platform.environment['ADB'] ?? 'adb';
    final result = await Process.run(adb, ['-s', serial!, ...args]);
    if (result.exitCode != 0) throw ProcessException(adb, args, '${result.stderr}', result.exitCode);
    return result.stdout as String;
  }
}
