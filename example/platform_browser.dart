// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// A TvServiceBrowser over a platform's own service browser: where raw multicast is not allowed (iOS without the
// multicast entitlement) or not wanted (Android NSD), the app browses with the platform and hands the results over
// through this interface.
//
// Here the platform side is a stream of maps, as a Flutter EventChannel would deliver them from Swift (NWBrowser) or
// Kotlin (NsdManager):
//
//   {'event': 'found' | 'updated' | 'lost', 'type': '_androidtvremote2._tcp',
//    'name': 'Living room TV', 'host': '192.168.0.20', 'port': 6466, 'txt': {'bt': 'AA:BB:CC:DD:EE:FF'}}

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

/// Adapts a platform's event stream to [TvServiceBrowser].
final class PlatformServiceBrowser implements TvServiceBrowser {
  /// Adapts [_events], the platform side.
  PlatformServiceBrowser(this._events);

  /// Starts the platform browser for the given types and returns its events; cancelling the subscription stops it.
  final Stream<Map<Object?, Object?>> Function(List<String> types) _events;

  @override
  Stream<TvServiceEvent> browse(List<String> types) => _events(types).expand((m) => [?_toEvent(m)]);

  static TvServiceEvent? _toEvent(Map<Object?, Object?> m) {
    final host = m['host'];
    final service = TvService(
      type: m['type']! as String,
      instance: m['name']! as String,
      port: m['port']! as int,
      host: host is String ? host : null,
      addresses: [if (host is String && InternetAddress.tryParse(host) != null) InternetAddress(host)],
      txt: {for (final MapEntry(:key, :value) in ((m['txt'] as Map?) ?? const {}).entries) '$key': '$value'},
    );
    return switch (m['event']) {
      'found' => TvServiceFound(service),
      'updated' => TvServiceUpdated(service),
      'lost' => TvServiceLost(service),
      _ => null,
    };
  }
}

Future<void> main() async {
  // A stand-in for the platform: one TV appears.
  final browser = PlatformServiceBrowser(
    (types) => Stream.value({
      'event': 'found',
      'type': TvServiceType.v2,
      'name': 'Living room TV',
      'host': '192.168.0.20',
      'port': 6466,
      'txt': {'bt': 'AA:BB:CC:DD:EE:FF'},
    }),
  );
  await for (final event in browser.browse(TvServiceType.all)) {
    print('$event, Bluetooth ${event.service.bluetoothAddress}');
  }
}
