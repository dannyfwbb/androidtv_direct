// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// Types into the TV's focused text field and follows what is typed on the TV.
//
//   dart run example/text.dart <host> <text>
//
// Open a text field on the TV (a search box, a name field in Settings): the field gets <text>, then edits made on the
// TV with its own remote are printed until Ctrl+C. Needs a TV paired by androidtv_direct_example.dart.

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

import 'paired.dart';

Future<void> main(List<String> args) async {
  final [host, text] = args;
  final remote = await connectPaired(host, features: {TvFeature.ime});
  try {
    final field = await _focusedField(remote);
    if (field == null) return print('No text field got the focus within a minute.');
    print('Field: "${field.text}" (${field.kind.password ? 'password' : 'text'}, action ${field.kind.action.name})');
    final result = await field.setText(text);
    print(result == text ? 'The field holds "$result"' : 'The field changed it to "$result" (a filter or a limit)');
    field.changes.listen((typed) => print('Typed on the TV: "$typed"'));
    await Future.any([ProcessSignal.sigint.watch().first, remote.done]);
  } finally {
    await remote.close();
  }
}

/// The field that has the focus, waiting up to a minute for one; `null` if none gets it.
Future<TvTextField?> _focusedField(TvRemote remote) async {
  if (remote.textField case final field?) return field;
  print('Open a text field on the TV.');
  return remote.textFieldChanges
      .firstWhere((field) => field != null && field.isFocused)
      .timeout(const Duration(minutes: 1), onTimeout: () => null);
}
