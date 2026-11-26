// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

/// Browses a service the local Avahi daemon publishes (tool/mdns_publish.py, Linux, python3 with dbus): the real
/// network stack and a real responder. Set ANDROIDTV_DIRECT_TEST_MDNS=1. It uses its own service type, so no TV and
/// no remote app on the network sees a fake TV.
final String? skip = Platform.environment['ANDROIDTV_DIRECT_TEST_MDNS'] == '1'
    ? null
    : 'set ANDROIDTV_DIRECT_TEST_MDNS=1 (needs Avahi; see test/device/README.md)';

const type = '_androidtvdirect-test._tcp';

void main() {
  test('found with name, port and TXT; lost on the goodbye', () async {
    final instance = 'Test TV ${pid % 1000}';
    final events = StreamController<TvServiceEvent>.broadcast();
    final sub = TvMdnsBrowser().browse([type]).listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      await events.close();
    });
    final publisher = await Process.start('python3', ['tool/mdns_publish.py', instance, type, '6466', 'bt=AA:BB']);
    // A failed expectation must not leave the service published.
    addTearDown(publisher.kill);
    final found = await events.stream
        .where((e) => e is TvServiceFound && e.service.instance == instance)
        .first
        .timeout(const Duration(seconds: 10));
    expect((found.service.port, found.service.bluetoothAddress), (6466, 'AA:BB'));
    expect(found.service.address!.isLoopback, isFalse);

    final lost = events.stream
        .where((e) => e is TvServiceLost && e.service.instance == instance)
        .first
        .timeout(const Duration(seconds: 4));
    await publisher.stdin.close();
    await lost;
    await publisher.exitCode;
  }, skip: skip);
}
