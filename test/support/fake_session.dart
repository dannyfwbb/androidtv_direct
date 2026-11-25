// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/protocol/remote_messages.dart';

import 'fake_tv.dart';
import 'fixtures.dart';

/// How the fake TV's session start goes wrong.
enum SessionFault {
  /// Closes before its first message (what a TV that does not know the client does after TLS).
  closeFirst,

  /// Sends setup and activation but never its power state.
  noPower,

  /// Sends its setup, then bytes that are not a message.
  garbage,
}

/// The TV's side of a remote session: its setup (the recorded one, with [offered] features), the client's answers,
/// activation, the start reports, then whatever the test sends. Every message from the client lands in [fromClient].
final class FakeSession {
  /// A TV offering [offered] features, or misbehaving with [fault].
  FakeSession({this.offered = 639, this.fault});

  /// The feature bits the TV offers.
  final int offered;

  /// How the start goes wrong, if it does.
  final SessionFault? fault;

  /// The connection, once a client connected.
  final Completer<FakeTvConnection> connection = Completer();

  /// The client's messages, in order.
  final List<RemoteEnvelope> fromClient = [];

  /// Plays the TV's side on [c].
  Future<void> serve(FakeTvConnection c) async {
    connection.complete(c);
    if (fault == SessionFault.closeFirst) return c.close();
    send(c, _setup());
    if (fault == SessionFault.garbage) return send(c, const [0x0b]);
    while (true) {
      final bytes = await c.receive(timeout: const Duration(minutes: 5));
      if (bytes == null) return;
      final message = RemoteEnvelope.fromClient(bytes);
      fromClient.add(message);
      if (message is SetupMessage) send(c, ActivateMessage().encodeEnvelope());
      if (message is ActivateMessage && fault != SessionFault.noPower) _startReports(c);
    }
  }

  /// Sends [message] to the client now.
  Future<void> sendMessage(RemoteEnvelope message) async => send(await connection.future, message.encodeEnvelope());

  /// Sends [envelope] bytes to the client now.
  static void send(FakeTvConnection c, List<int> envelope) => c
    ..send(envelope)
    ..flush();

  List<int> _setup() {
    final recorded = RemoteEnvelope.fromTv(sessionMessage('setup', outgoing: false)) as SetupMessage;
    return SetupMessage(
      features: offered,
      device: recorded.device,
      unknownFields: recorded.unknownFields,
    ).encodeEnvelope();
  }

  void _startReports(FakeTvConnection c) {
    // In the order the TV sent them in the recording: volume before power.
    for (final name in ['volumeReport', 'focusReport', 'powerReport']) {
      send(c, sessionMessage(name, outgoing: false));
    }
  }
}
