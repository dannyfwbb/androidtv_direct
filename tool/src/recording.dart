// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Collecting traced messages into a fixture file, and reading a pairing code off a TV's screen.
library;

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';

/// Traced messages, in order.
final class Recording {
  final List<TvMessageTrace> _messages = [];

  /// How many messages were recorded.
  int get length => _messages.length;

  /// Keeps [event] if it is a message with its bytes.
  void add(TvTraceEvent event) {
    if (event is TvMessageTrace && event.raw != null) _messages.add(event);
  }

  /// The fixture text: [header] as comment lines wrapped at 116 characters, then one line per message.
  String toFixture({required String header}) {
    final seen = <String, int>{};
    final out = StringBuffer();
    for (final line in _wrap(header, 116)) {
      out.writeln('# $line');
    }
    for (final m in _messages) {
      final direction = m.outgoing ? 'out' : 'in';
      final key = '$direction ${m.port} ${m.kind}';
      final count = seen[key] = (seen[key] ?? 0) + 1;
      final name = count == 1 ? m.kind : '${m.kind}.$count';
      out.writeln('$direction ${m.port} $name ${hexEncode(m.raw!)}');
    }
    return out.toString();
  }

  static List<String> _wrap(String text, int width) {
    final lines = <String>[];
    var line = '';
    for (final word in text.split(' ')) {
      if (line.isNotEmpty && line.length + 1 + word.length > width) {
        lines.add(line);
        line = word;
      } else {
        line = line.isEmpty ? word : '$line $word';
      }
    }
    return [...lines, if (line.isNotEmpty) line];
  }
}

/// The six-character pairing code on the screen of the TV with adb [serial], read with `uiautomator`.
Future<String> readCodeFromScreen(String serial) async {
  final adb = Platform.environment['ADB'] ?? 'adb';
  for (var attempt = 0; attempt < 20; attempt++) {
    await Process.run(adb, ['-s', serial, 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml']);
    final xml = (await Process.run(adb, ['-s', serial, 'shell', 'cat', '/sdcard/ui.xml'])).stdout as String;
    final code = RegExp(r'text="([0-9A-F]{6})"').firstMatch(xml)?.group(1);
    if (code != null) return code;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('No pairing code on the screen');
}
