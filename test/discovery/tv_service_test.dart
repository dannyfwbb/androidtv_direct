// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

void main() {
  group('services', () {
    test('protocol from the type, Bluetooth address from the TXT record', () {
      final v2 = TvService(type: TvServiceType.v2, instance: 'TV', port: 6466, txt: const {'bt': 'AA:BB'});
      final v1 = TvService(type: '_AndroidTvRemote._tcp', instance: 'Old TV', port: 6466);
      expect((v2.protocol, v2.bluetoothAddress), (TvProtocol.v2, 'AA:BB'));
      expect(v1.protocol, TvProtocol.v1);
      expect(v1.bluetoothAddress, isNull);
    });
  });
}
