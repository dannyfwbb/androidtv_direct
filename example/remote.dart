// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

// A remote control in the terminal.
//
//   dart run example/remote.dart <host>
//
// Arrows move, Enter selects, b goes back, h goes home, + and - change the volume, m mutes, p is the power key.
// t types into the focused text field, l opens a link; q quits. Needs a TV paired by androidtv_direct_example.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';

import 'paired.dart';

/// Single keys and what they press.
const Map<String, TvKey> _keys = {
  '\x1b[A': TvKey.dpadUp,
  '\x1b[B': TvKey.dpadDown,
  '\x1b[C': TvKey.dpadRight,
  '\x1b[D': TvKey.dpadLeft,
  '\r': TvKey.dpadCenter,
  '\n': TvKey.dpadCenter,
  'b': TvKey.back,
  'h': TvKey.home,
  '+': TvKey.volumeUp,
  '-': TvKey.volumeDown,
  'm': TvKey.volumeMute,
  'p': TvKey.power,
};

Future<void> main(List<String> args) async {
  if (args.length != 1) return print('Usage: dart run example/remote.dart <host>');
  final remote = await connectPaired(args.single, features: {TvFeature.ime});
  print('${remote.device.vendor} ${remote.device.model}: arrows, Enter, b, h, +, -, m, p, t (text), l (link), q');
  remote.changes.listen((state) => print('  $state'));
  remote.textFieldChanges.listen((field) => print(field == null ? '  no text field' : '  text field: "${field.text}"'));
  unawaited(remote.done.then((reason) => print('Session ended${reason == null ? '' : ': ${reason.message}'}')));

  final input = _Input();
  try {
    for (var key = await input.nextKey(); key != null && key != 'q' && !remote.isClosed; key = await input.nextKey()) {
      switch (key) {
        case 't':
          await _type(remote, await input.line('Text: '));
        case 'l':
          remote.openLink(await input.line('Link: '));
        default:
          if (_keys[key] case final tvKey?) remote.press(tvKey);
      }
    }
  } on TvRemoteException catch (e) {
    print('Stopped: ${e.message}');
  } finally {
    input.close();
    await remote.close();
  }
}

Future<void> _type(TvRemote remote, String text) async {
  final field = remote.textField;
  if (field == null) return print('  No text field has the focus: open a search box on the TV first.');
  try {
    print('  The field now holds "${await field.setText(text)}"');
  } on TvCancelledException {
    print('  The field lost the focus.');
  }
}

/// Keys from the terminal as they are pressed (an arrow's escape sequence is one key), or lines when asked for one;
/// input piped in works the same way, in order.
final class _Input {
  _Input() {
    if (_raw) {
      stdin
        ..echoMode = false
        ..lineMode = false;
    }
    _subscription = stdin
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            _pending += chunk;
            _wake();
          },
          onDone: () {
            _ended = true;
            _wake();
          },
        );
  }

  final bool _raw = stdin.hasTerminal;
  late final StreamSubscription<String> _subscription;
  String _pending = '';
  Completer<void>? _arrival;
  bool _ended = false;

  /// The next key, or `null` once the input ended.
  Future<String?> nextKey() async {
    while (_pending.isEmpty) {
      if (_ended) return null;
      await (_arrival = Completer()).future;
    }
    final length = _pending.startsWith('\x1b[') && _pending.length >= 3 ? 3 : 1;
    final key = _pending.substring(0, length);
    _pending = _pending.substring(length);
    return key;
  }

  /// The next line, after [prompt].
  Future<String> line(String prompt) async {
    stdout.write(prompt);
    var typed = '';
    for (var key = await nextKey(); key != null && key != '\r' && key != '\n'; key = await nextKey()) {
      if (key == '\x7f' || key == '\b') {
        if (typed.isEmpty) continue;
        typed = typed.substring(0, typed.length - 1);
        if (_raw) stdout.write('\b \b');
      } else {
        typed += key;
        if (_raw) stdout.write(key);
      }
    }
    if (_raw) stdout.writeln();
    return typed;
  }

  void _wake() {
    final arrival = _arrival;
    _arrival = null;
    arrival?.complete();
  }

  void close() {
    unawaited(_subscription.cancel());
    if (_raw) {
      stdin
        ..lineMode = true
        ..echoMode = true;
    }
  }
}
