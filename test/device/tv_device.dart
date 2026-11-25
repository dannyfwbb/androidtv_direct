// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// The TV the device tests use, from the environment: `ANDROIDTV_DIRECT_TEST_HOST` (required) and
/// `ANDROIDTV_DIRECT_TEST_SERIAL` (the adb serial, to read the screen).
abstract final class TvDevice {
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

  static Future<String> _adb(List<String> args) async {
    final adb = Platform.environment['ADB'] ?? 'adb';
    final result = await Process.run(adb, ['-s', serial!, ...args]);
    if (result.exitCode != 0) throw ProcessException(adb, args, '${result.stderr}', result.exitCode);
    return result.stdout as String;
  }
}
