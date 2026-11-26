// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

void main() {
  final all = <TvRemoteException>[
    const TvUnreachableException('m'),
    const TvNoServiceException('m'),
    const TvNotPairedException('m'),
    const TvWrongTvException('m', expected: 'aa', actual: 'bb'),
    const TvWrongCodeException('m'),
    const TvPairingRefusedException('m', status: 402),
    const TvLinkRefusedException('m', link: 'x', refusalCode: 7),
    const TvOutdatedServiceException('m'),
    const TvNotSupportedException('m', feature: TvFeature.voice),
    const TvTimeoutException('m'),
    const TvClosedException('m'),
    const TvProtocolException('m'),
    const TvCancelledException('m'),
  ];

  test('every code has exactly one subclass', () {
    expect(all.map((e) => e.code), TvErrorCode.values);
  });

  test('a switch over the subclasses is exhaustive', () {
    String name(TvRemoteException e) => switch (e) {
      TvUnreachableException() => 'unreachable',
      TvNoServiceException() => 'noService',
      TvNotPairedException() => 'notPaired',
      TvWrongTvException() => 'wrongTv',
      TvWrongCodeException() => 'wrongCode',
      TvPairingRefusedException() => 'pairingRefused',
      TvLinkRefusedException() => 'linkRefused',
      TvOutdatedServiceException() => 'outdatedService',
      TvNotSupportedException() => 'notSupported',
      TvTimeoutException() => 'timeout',
      TvClosedException() => 'closed',
      TvProtocolException() => 'protocol',
      TvCancelledException() => 'cancelled',
    };
    expect(all.map(name), TvErrorCode.values.map((c) => c.name));
  });

  test('toString names the code and the cause', () {
    expect(const TvClosedException('gone').toString(), 'TvRemoteException(closed): gone');
    expect(
      const TvUnreachableException('no route', cause: 'OSError').toString(),
      'TvRemoteException(unreachable): no route (cause: OSError)',
    );
  });
}
