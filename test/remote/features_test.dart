// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

void main() {
  test('masks carry the protocol bits, pings always', () {
    expect(TvFeature.maskOf(const {}), 1);
    expect(TvFeature.maskOf(TvFeature.defaults), 1 | 2 | 32 | 64 | 512);
    expect(TvFeature.maskOf(TvFeature.values), 1 | 2 | 4 | 8 | 32 | 64 | 512);
  });

  test('a mask reads back as the features it holds, ignoring other bits', () {
    expect(TvFeature.fromMask(639), TvFeature.values.toSet());
    expect(TvFeature.fromMask(1 | 16 | 4), {TvFeature.ime});
  });
}
