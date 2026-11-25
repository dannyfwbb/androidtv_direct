// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import 'tv_device.dart';

void main() {
  group('pairing', skip: TvDevice.skip, () {
    late TvClientIdentity identity;
    setUpAll(() async => identity = await TvClientIdentity.generate(now: DateTime.now()));

    Future<TvPairing> start() =>
        TvPairing.start(TvDevice.host!, identity: identity, clientName: 'androidtv_direct test');

    test('a fresh identity pairs, after a wrong code in the same pairing', () async {
      final pairing = await start();
      final code = await TvDevice.waitForCode();
      await expectLater(pairing.finish(codeWithWrongCheckByte(code)), throwsA(isA<TvWrongCodeException>()));
      expect(pairing.isOpen, isTrue);
      final result = await pairing.finish(code);
      expect(result.fingerprint, pairing.tv.fingerprint);
      expect(await TvProbe.identify(TvDevice.host!, identity: identity), isA<TvIdentity>());
    });

    test('cancel closes the dialog on the TV', () async {
      final pairing = await start();
      await TvDevice.waitForCode();
      await pairing.cancel();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await TvDevice.code(), isNull);
    });
  });
}
