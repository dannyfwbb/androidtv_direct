// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:test/test.dart';

import 'test_tv.dart';

/// Uses the device name field of TV Settings on an Android TV image: "Change", then "Enter custom name…" (the last
/// entry). Nothing is saved: the tests leave the screen with Back.
void main() {
  group('text', skip: TestTv.skip, () {
    late TvRemote remote;

    setUpAll(() async {
      remote = await TestTv.connectFresh({TvFeature.ime});
    });

    tearDownAll(() async {
      for (var i = 0; i < 3; i++) {
        await TestTv.keyEvent('BACK');
      }
      await TestTv.keyEvent('HOME');
      await remote.close();
    });

    test('the name field gets the focus and reports its kind', () async {
      await TestTv.shell(['am', 'start', '-n', 'com.android.tv.settings/.name.DeviceNameSettingsActivity']);
      await Future<void>.delayed(const Duration(seconds: 3));
      remote.press(TvKey.dpadCenter);
      await Future<void>.delayed(const Duration(seconds: 2));
      for (var i = 0; i < 12; i++) {
        remote.press(TvKey.dpadDown);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      final focused = remote.textFieldChanges.firstWhere((field) => field != null);
      remote.press(TvKey.dpadCenter);
      final field = (await focused.timeout(const Duration(seconds: 10)))!;
      expect(field.kind.action, TvFieldAction.done);
      expect(field.kind.password, isFalse);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('setText reaches every text, also replacing and emptying', () async {
      final field = remote.textField!;
      for (final text in ['Привет, мир', 'Привет, мир 👍🏽', 'abc', 'x' * 200, 'Living room TV', '']) {
        expect(await field.setText(text), text);
      }
    }, timeout: const Timeout(Duration(seconds: 40)));

    test("text typed with the TV's own keyboard arrives as a change", () async {
      final field = remote.textField!;
      final changes = <String>[];
      field.changes.listen(changes.add);
      await TestTv.shell(['input', 'text', 'typed_on_tv']);
      expect(await TestTv.waitFor(() async => field.text, 'typed_on_tv'), 'typed_on_tv');
      expect(changes.last, 'typed_on_tv', reason: 'the TV reports each typed character');
      expect(await field.setText(''), '');
    });
  });
}
