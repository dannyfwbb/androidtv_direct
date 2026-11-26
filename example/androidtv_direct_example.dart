// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Pairs with a TV once, then connects and shows what the TV reports.
//
//   dart run example/androidtv_direct_example.dart <host>
//
// Keeps the client's identity in `identity.pem` and each TV's fingerprint in `tv-<host>.fingerprint` in the working
// directory. A real app keeps the identity in the platform's protected storage instead (doc/identity.md).

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

Future<void> main(List<String> args) async {
  final host = args.single;
  final identity = await _identity();
  final fingerprint = await _fingerprint(host, identity);
  final remote = await TvRemote.connect(host, identity: identity, fingerprint: fingerprint);
  try {
    print('${remote.device.vendor} ${remote.device.model}, Android ${remote.device.androidRelease}');
    print('power ${remote.state.power}, volume ${remote.state.volume}, features ${remote.features.map((f) => f.name)}');
    remote.changes.listen((state) => print('now: $state'));
    for (final key in [TvKey.volumeUp, TvKey.volumeDown]) {
      remote.press(key);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } finally {
    await remote.close();
  }
}

Future<TvClientIdentity> _identity() async {
  final file = File('identity.pem');
  if (file.existsSync()) return TvClientIdentity.fromPem(file.readAsStringSync());
  final identity = await TvClientIdentity.generate(now: DateTime.now());
  file.writeAsStringSync(identity.toPem());
  return identity;
}

Future<String> _fingerprint(String host, TvClientIdentity identity) async {
  final file = File('tv-$host.fingerprint');
  if (file.existsSync()) return file.readAsStringSync().trim();
  final pairing = await TvPairing.start(host, identity: identity, clientName: 'androidtv_direct example');
  print('Pairing with ${pairing.tv.model ?? host}: type the code the TV shows.');
  while (true) {
    stdout.write('Code: ');
    try {
      final result = await pairing.finish(stdin.readLineSync() ?? '');
      file.writeAsStringSync(result.fingerprint);
      return result.fingerprint;
    } on TvWrongCodeException {
      print('That is not the code on the TV; try again.');
    }
  }
}
