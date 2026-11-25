// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

TvIdentity identityOf(String path) => TvIdentity.fromCertificate(pemFixtureDer(path));

void main() {
  test('the emulator: names in the dnQualifier, the address in the common name', () {
    final tv = identityOf('pairing/vector/tv.crt.pem');
    expect(tv.product, 'sdk_google_atv_amati_x86');
    expect(tv.device, 'emulator_x86_arm');
    expect(tv.model, 'AOSP TV on x86');
    expect(tv.macAddress, 'BB:BB:BB:00:00:04');
    expect(tv.fingerprint, 'cd3c355d08cfdcea3ae0f4ba4bf289fad0ceff28715826334a2514d2101bf3da');
  });

  test('everything in the common name', () {
    final tv = identityOf('certificates/all-in-cn.crt.pem');
    expect(
      (tv.product, tv.device, tv.model, tv.macAddress),
      ('darcy', 'darcy', 'SHIELD Android TV', '00:04:4B:AA:BB:CC'),
    );
  });

  test('a dnQualifier that runs on into the common name', () {
    final tv = identityOf('certificates/dnqualifier-run-on.crt.pem');
    expect((tv.product, tv.device, tv.model, tv.macAddress), ('fugu', 'fugu', 'Nexus Player', 'AC:9E:17:AA:BB:CC'));
  });

  test('no address, or an unknown layout, leaves fields empty', () {
    final noMac = identityOf('certificates/no-mac.crt.pem');
    expect(noMac.model, 'Some TV');
    expect(noMac.macAddress, isNull);
    final unknown = identityOf('certificates/unknown.crt.pem');
    expect([unknown.product, unknown.device, unknown.model, unknown.macAddress], everyElement(isNull));
    expect(unknown.fingerprint, hasLength(64));
  });

  test('a TV certificate without an RSA key is a format error', () {
    expect(() => identityOf('certificates/ec.crt.pem'), throwsFormatException);
  });

  group('subject layouts', () {
    List<String?> read(String? cn, [String? qualifier]) {
      final s = TvSubject.parse(commonName: cn, dnQualifier: qualifier);
      return [s.product, s.device, s.model, s.macAddress];
    }

    test('a model may contain slashes and empty parts', () {
      expect(read('atvremote/p/d/A/B/aa:bb:cc:dd:ee:ff'), ['p', 'd', 'A/B', 'AA:BB:CC:DD:EE:FF']);
      expect(read('atvremote', 'p/d/A//B'), ['p', 'd', 'A//B', null]);
    });

    test('a common name without the atvremote prefix is not read', () {
      expect(read('Living Room', 'p/d/M'), ['p', 'd', 'M', null]);
      expect(read('a/b/c'), [null, null, null, null]);
      expect(read('x/atvremote/p/d/m'), [null, null, null, null]);
    });

    test('atvremote counts only as the prefix', () {
      expect(read('atvremote/p/atvremote/m/11:22:33:44:55:66'), ['p', 'atvremote', 'm', '11:22:33:44:55:66']);
    });

    test('too few names leave them empty; the address still counts', () {
      expect(read('atvremote/d/11:22:33:44:55:66', 'p/d'), [null, null, null, '11:22:33:44:55:66']);
      expect(read(null), [null, null, null, null]);
    });
  });
}
