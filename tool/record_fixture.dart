// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Records a pairing and a remote session with a TV into a fixture file, through the package's raw tracing.
///
/// ```
/// dart run tool/record_fixture.dart <host> <adb serial> <output file>
/// ```
///
/// The TV must be reachable on both ports and its screen readable over adb (the code is read with `uiautomator`). Every
/// run pairs a new identity, so it adds another client (shown as `androidtv_direct`) on the TV. The session then: waits
/// for a ping, presses volume up and down, opens a web link, goes home, and opens a bare package name, which the TV
/// refuses and ends the session with. Lines name messages by kind; a kind seen again gets `.2`, `.3`… Review the file
/// before committing it: it must not hold anything that identifies a real TV.
library;

import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';

import 'src/recording.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('Usage: dart run tool/record_fixture.dart <host> <adb serial> <output file>');
    exitCode = 64;
    return;
  }
  final [host, serial, output] = args;
  final recording = Recording();
  final tracer = TvTracer(recording.add, level: TvTraceLevel.raw);
  final identity = await TvClientIdentity.generate(now: DateTime.now());
  final fingerprint = await _pair(host, serial, identity, tracer);
  final remote = await TvRemote.connect(
    host,
    identity: identity,
    fingerprint: fingerprint,
    features: {...TvFeature.defaults, TvFeature.ime},
    tracer: tracer,
  );
  await _drive(remote);
  File(output).writeAsStringSync(recording.toFixture(header: _header(remote.device)));
  stdout.writeln('Wrote ${recording.length} messages to $output');
}

Future<String> _pair(String host, String serial, TvClientIdentity identity, TvTracer tracer) async {
  final pairing = await TvPairing.start(host, identity: identity, clientName: 'androidtv_direct', tracer: tracer);
  try {
    return (await pairing.finish(await readCodeFromScreen(serial))).fingerprint;
  } finally {
    await pairing.cancel();
  }
}

Future<void> _drive(TvRemote remote) async {
  Future<void> pause(int seconds) => Future<void>.delayed(Duration(seconds: seconds));
  void send(RemoteEnvelope message) => remote.sendRaw(message.field, message.encode());
  await pause(7);
  for (final key in [TvKey.volumeUp, TvKey.volumeDown]) {
    send(KeyMessage(code: key.code, action: KeyAction.short));
    await pause(1);
  }
  send(OpenLinkMessage(link: 'https://www.youtube.com'));
  await pause(3);
  send(KeyMessage(code: TvKey.home.code, action: KeyAction.short));
  await pause(2);
  send(OpenLinkMessage(link: 'com.android.tv.settings'));
  await remote.done.timeout(const Duration(seconds: 5), onTimeout: () => null);
  await remote.close();
}

String _header(TvDevice device) {
  final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  return 'Message bodies without the length prefix, recorded on $date from an Android TV Remote Service '
      '${device.serviceVersion} on Android ${device.androidRelease}. One per line: direction (out: client to TV), '
      "port (6467 pairing, 6466 remote), this package's name for the message (a kind seen again gets .2, .3…), hex.";
}
