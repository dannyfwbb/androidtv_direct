// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Lists TVs that announce their remote service for ten seconds; with a /24 prefix, also scans that subnet. Nothing is
// sent to the TVs and nothing appears on them.
//
//   dart run example/discover.dart [192.168.0]

import 'package:androidtv_direct/androidtv_direct.dart';

Future<void> main(List<String> args) async {
  final browsing = TvMdnsBrowser().browse(TvServiceType.all).listen((event) {
    final service = event.service;
    final outdated = service.protocol == TvProtocol.v1 ? ' (remote service outdated: update it on the TV)' : '';
    print('$event: ${service.instance} at ${service.address?.address}$outdated');
  });
  if (args.isNotEmpty) {
    final hosts = [for (var i = 1; i < 255; i++) '${args.single}.$i'];
    await for (final found in TvProbe.scan(hosts)) {
      print('scan: ${found.host} is ${found.tv.model ?? 'a TV'} (${found.tv.macAddress ?? 'no MAC'})');
    }
  }
  await Future<void>.delayed(const Duration(seconds: 10));
  await browsing.cancel();
}
