// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

void main() {
  test("keys carry AOSP's codes", () {
    expect(TvKey.unknown.code, 0);
    expect(TvKey.home.code, 3);
    expect(TvKey.digit0.code, 7);
    expect(TvKey.dpadCenter.code, 23);
    expect(TvKey.volumeUp.code, 24);
    expect(TvKey.power.code, 26);
    expect(TvKey.del.code, 67);
    expect(TvKey.search.code, 84);
    expect(TvKey.moveEnd.code, 123);
    expect(TvKey.mode3d.code, 206);
    expect(TvKey.key11.code, 227);
    expect(TvKey.tvInputHdmi1.code, 243);
    expect(TvKey.allApps.code, 284);
    expect(TvKey.newKey.code, 320);
    expect(TvKey.f24.code, 337);
  });

  test('the table has every code from 0 to 337 once', () {
    expect(TvKey.values.map((k) => k.code), List.generate(338, (i) => i));
  });

  test('fromCode finds a key by code', () {
    expect(TvKey.fromCode(66), TvKey.enter);
    expect(TvKey.fromCode(338), isNull);
    expect(TvKey.fromCode(-1), isNull);
  });
}
