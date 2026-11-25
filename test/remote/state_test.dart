// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

void main() {
  const empty = TvState();

  test('reports fill the state; a report that changes nothing returns the same object', () {
    final on = empty.apply(PowerReport(state: 1));
    expect(on.power, isTrue);
    expect(on.apply(PowerReport(state: 1)), same(on));
    final app = on.apply(FocusReport(app: FocusedApp(packageName: 'a.b')));
    expect((app.power, app.app), (true, 'a.b'));
    expect(app.apply(FocusReport(app: FocusedApp(keyboardRevision: 3))), same(app));
    expect(app.apply(PingMessage(id: 1)), same(app));
  });

  test('a volume report needs a level and a maximum once; later ones may leave fields out', () {
    expect(empty.apply(VolumeReport(level: 3)).volume, isNull);
    final full = empty.apply(VolumeReport(level: 3, maximum: 15));
    expect(full.volume, const TvVolume(level: 3, maximum: 15, muted: false));
    final muted = full.apply(VolumeReport(muteState: 1));
    expect(muted.volume, const TvVolume(level: 3, maximum: 15, muted: true));
    expect(muted.apply(VolumeReport(level: 4)).volume, const TvVolume(level: 4, maximum: 15, muted: true));
  });
}
