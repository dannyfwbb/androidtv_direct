// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';

import 'fake_field.dart';
import 'fake_tv.dart';
import 'fixtures.dart';
import 'wait.dart';

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
  FakeSession({this.offered = recordedFeatures, this.fault});

  /// The feature bits the recorded TV offers.
  static const int recordedFeatures = 639;

  /// The feature bits the TV offers.
  final int offered;

  /// How the start goes wrong, if it does.
  final SessionFault? fault;

  /// The connection, once a client connected.
  final Completer<FakeTvConnection> connection = Completer();

  /// The client's messages, in order.
  final List<RemoteEnvelope> fromClient = [];

  /// The client's messages of type [T], once at least [count] of them arrived.
  Future<List<T>> received<T>({int count = 1}) async {
    await until(() => fromClient.whereType<T>().length >= count);
    return fromClient.whereType<T>().toList();
  }

  /// How long the TV's messages take to reach the client (a slow network).
  Duration latency = Duration.zero;

  /// Plays the TV's side on [c].
  Future<void> serve(FakeTvConnection c) async {
    c.latency = latency;
    connection.complete(c);
    if (fault == SessionFault.closeFirst) return c.close();
    send(c, _setup());
    if (fault == SessionFault.garbage) return send(c, const [0x0b]);
    while (true) {
      final bytes = await c.receive(timeout: const Duration(minutes: 5));
      if (bytes == null) return;
      final message = RemoteEnvelope.fromClient(bytes);
      fromClient.add(message);
      if (!await _react(c, message, bytes)) return;
    }
  }

  /// The focused text field, if any: keys and text edits go to it.
  FakeField? field;

  /// Gives [newField] the focus and reports it.
  Future<void> focus(FakeField newField) async {
    field = newField;
    await sendMessage(newField.focusReport());
  }

  /// Takes the focus away from the field and reports it.
  Future<void> unfocus() async {
    field = null;
    await sendMessage(FocusReport(app: FocusedApp(packageName: 'com.example.tv')));
  }

  /// Whether the volume keys change [volume] and report it, as a TV does. Off to test a TV that does not answer.
  bool answerVolumeKeys = true;

  /// How many volume keys still to lose, as a TV that drops a key now and then.
  int loseVolumeKeys = 0;

  /// Whether the Search key opens a voice session (id 1, the recorded voice app), as the emulator's did.
  bool answerSearch = true;

  /// Whether a voice close is confirmed with the TV's own end message, as the emulator did.
  bool answerVoiceClose = true;

  /// Whether an unconfirmed close is confirmed late, right after the next voice open, as the emulator sometimes did.
  bool confirmCloseOnNextOpen = false;
  bool _closeUnconfirmed = false;

  /// The level the volume keys move, from the recorded start report; the maximum stays the recorded one.
  late int volume = _recordedVolume.level!;

  /// Whether the sound is muted: the emulator mutes at level 0.
  bool muted = false;

  /// Whether volume up while muted only unmutes, without a new level (as some TVs may), instead of both.
  bool upOnlyUnmutes = false;

  static final VolumeReport _recordedVolume =
      RemoteEnvelope.fromTv(sessionMessage('volumeReport', outgoing: false)) as VolumeReport;

  /// Answers [message] as the TV does; returns false once the TV closed the connection.
  Future<bool> _react(FakeTvConnection c, RemoteEnvelope message, List<int> bytes) async {
    switch (message) {
      case SetupMessage():
        send(c, ActivateMessage().encodeEnvelope());
      case ActivateMessage() when fault != SessionFault.noPower:
        _startReports(c);
      case KeyMessage(:final code?) when field != null && (code == TvKey.del.code || code == TvKey.moveEnd.code):
        final answer = field!.onKey(code);
        if (answer != null) send(c, answer.encodeEnvelope());
      case TextEditMessage() when field != null:
        final answer = field!.onEdit(message);
        if (answer != null) send(c, answer.encodeEnvelope());
      case VoiceCloseMessage() when answerVoiceClose:
        send(c, recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes);
      case VoiceCloseMessage():
        _closeUnconfirmed = true;
      case KeyMessage(:final code) when code == TvKey.search.code && answerSearch:
        send(c, recorded('voiceOpen', outgoing: false, file: 'voice.txt').bytes);
        if (_closeUnconfirmed && confirmCloseOnNextOpen) {
          send(c, recorded('voiceEnded', outgoing: false, file: 'voice.txt').bytes);
        }
        _closeUnconfirmed = false;
      case KeyMessage(:final code)
          when loseVolumeKeys > 0 && (code == TvKey.volumeUp.code || code == TvKey.volumeDown.code):
        loseVolumeKeys--;
      case KeyMessage(:final code, :final action) when answerVolumeKeys && action != KeyAction.release:
        _volumeKey(c, code);
      case OpenLinkMessage(:final link) when link == null || !link.contains(':'):
        return _refuse(c, RefusalCode.cannotAct, bytes);
      case UnknownEnvelope():
        return _refuse(c, RefusalCode.unknownMessage, bytes);
      default:
    }
    return true;
  }

  void _volumeKey(FakeTvConnection c, int? code) {
    final step = switch (code) {
      _ when code == TvKey.volumeUp.code => 1,
      _ when code == TvKey.volumeDown.code => -1,
      _ => 0,
    };
    if (step == 0) return;
    // As the emulator: volume up while muted reports the unmute at the same level first, then the new level; a key
    // at either end of the range changes nothing and reports nothing.
    if (step > 0 && muted) {
      muted = false;
      _reportVolume(c);
      if (upOnlyUnmutes) return;
    }
    final next = (volume + step).clamp(0, _recordedVolume.maximum!);
    if (next == volume) return;
    volume = next;
    muted = volume == 0;
    _reportVolume(c);
  }

  void _reportVolume(FakeTvConnection c) =>
      send(c, VolumeReport(maximum: _recordedVolume.maximum, level: volume, muteState: muted ? 1 : 0).encodeEnvelope());

  /// Refuses a message as the TV does: a refusal echoing it, then the connection closes.
  Future<bool> _refuse(FakeTvConnection c, RefusalCode code, List<int> bytes) async {
    send(c, RefusalMessage(code: code, refused: Uint8List.fromList(bytes)).encodeEnvelope());
    await c.close();
    return false;
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
