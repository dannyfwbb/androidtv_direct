// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:test/test.dart';

void main() {
  test('the standard description is the one recorded from an existing client', () {
    // The device field of the recorded client setup in test/fixtures/remote/session.txt.
    expect(hexEncode(TvClientInfo.standard.toMessage().encode()), '18012201312a0961747672656d6f74653205312e302e30');
  });

  test('fields left out are not sent; the OS goes by its number', () {
    const info = TvClientInfo(model: 'M', os: TvClientOs.unspecified, osVersion: null, appId: null, appVersion: null);
    final message = info.toMessage();
    expect((message.model, message.vendor, message.os, message.packageName), ('M', null, 0, null));
    expect([for (final os in TvClientOs.values) os.code], [0, 1, 2]);
  });

  test('equal descriptions are equal', () {
    expect(const TvClientInfo(model: 'a'), const TvClientInfo(model: 'a'));
    expect(const TvClientInfo(model: 'a').hashCode, const TvClientInfo(model: 'a').hashCode);
    expect(const TvClientInfo(model: 'a'), isNot(const TvClientInfo(model: 'b')));
    expect(TvClientInfo.standard, const TvClientInfo());
  });
}
