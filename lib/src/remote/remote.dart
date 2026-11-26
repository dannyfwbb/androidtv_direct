// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:androidtv_direct/src/cancel.dart';
import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/identity/client_identity.dart';
import 'package:androidtv_direct/src/protocol/key_codes.dart';
import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/client_info.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/keys.dart';
import 'package:androidtv_direct/src/remote/links.dart';
import 'package:androidtv_direct/src/remote/session.dart';
import 'package:androidtv_direct/src/remote/state.dart';
import 'package:androidtv_direct/src/remote/volume.dart';
import 'package:androidtv_direct/src/text/text_field.dart';
import 'package:androidtv_direct/src/trace.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';
import 'package:androidtv_direct/src/voice/voice.dart';

/// A remote session with a paired TV.
///
/// [connect] returns once the TV reported its power state. [state] then always holds the latest of what the TV
/// reported, [changes] tells when it changes, and [done] completes once when the session ends. The session answers
/// the TV's pings itself and ends with [TvTimeoutException] after [connect]'s `idleTimeout` without a message in
/// either direction (a TV that went away). Sending counts as activity, because a TV does not ping a client that
/// sends; an app that keeps sending to a TV that went away learns it only when the writes fail. There is no
/// reconnecting inside: the app decides when to connect again.
final class TvRemote {
  TvRemote._(this._session, Duration textGiveUp) : _text = TextInput(_session, textGiveUp);

  /// The remote port.
  static const int defaultPort = 6466;

  /// Connects to the TV at [host] with the paired [identity] and starts a session.
  ///
  /// [fingerprint] is the TV's key fingerprint from pairing (`TvPairingResult.fingerprint`): a device with another key
  /// is refused with [TvWrongTvException] during the TLS handshake, before anything is sent. It must be given; `null`
  /// deliberately accepts whatever device answers at [host], which then receives everything the app sends, typed
  /// passwords included.
  ///
  /// [features] is what the session asks for; the TV grants what it offers of it ([TvRemote.features]). Power reports
  /// are always asked for: the session is ready when the TV reports its power state. [textGiveUp] is how long a
  /// [TvTextField.setText] waits for the TV's report before taking the TV's text as it is. [client] is what the TV is
  /// told about this app and device; the TV only logs it.
  ///
  /// Throws [TvUnreachableException], [TvNoServiceException], [TvWrongTvException], [TvNotPairedException] (the TV does
  /// not know [identity]), [TvTimeoutException] (no TLS within [connectTimeout], or no start within [startTimeout]),
  /// [TvClosedException], [TvProtocolException] or, when [cancelOn] completes before this returns,
  /// [TvCancelledException].
  static Future<TvRemote> connect(
    Object host, {
    required TvClientIdentity identity,
    required String? fingerprint,
    Set<TvFeature> features = TvFeature.defaults,
    TvClientInfo client = TvClientInfo.standard,
    int port = defaultPort,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration startTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 16),
    Duration textGiveUp = const Duration(milliseconds: 1500),
    TvClock clock = TvClock.system,
    TvTracer? tracer,
    Future<void>? cancelOn,
  }) async {
    final socket = await TvSocket.connect(
      host,
      port,
      context: identity.securityContext(),
      timeout: connectTimeout,
      pin: fingerprint,
      clock: clock,
      tracer: tracer,
      cancelOn: cancelOn,
    );
    final session = RemoteSession(socket, features, clock: clock, idleTimeout: idleTimeout, client: client);
    await cancellable(cancelOn, what: 'Connecting', abort: session.close, body: () => session.start(startTimeout));
    return TvRemote._(session, textGiveUp);
  }

  final RemoteSession _session;
  late final KeyHolds _holds = KeyHolds(_session);
  late final VolumeControl _volume = VolumeControl(_session);
  final TextInput _text;
  TvVoiceSession? _voice;
  bool _voiceStarting = false;

  /// The TV, as it described itself when the session started.
  TvDevice get device => _session.device;

  /// What the session can do: what it asked for and the TV offered.
  Set<TvFeature> get features => _session.granted;

  /// The latest of everything the TV reported.
  TvState get state => _session.state;

  /// Every change of [state], as it happens. Closes when the session ends.
  Stream<TvState> get changes => _session.changes;

  /// Completes once when the session ends: with `null` after [close], otherwise with why it ended.
  Future<TvRemoteException?> get done => _session.done;

  /// Whether the session has ended.
  bool get isClosed => _session.isClosed;

  /// Presses and releases [key] once.
  ///
  /// Throws [TvNotSupportedException] when the session lacks [TvFeature.key], [RangeError] for [TvKey.unknown] (code
  /// 0, not a key), and what ended the session once it has ended. TVs seen so far ignore keys they do not know.
  void press(TvKey key) => sendKey(_session, key.code, TvKeyAction.press);

  /// Sends key [code] with [action]: for Android key codes the [TvKey] table does not have (1 to 999). Throws as
  /// [press], and [RangeError] for another code. A key sent down this way is the caller's to send up; [holdCode]
  /// tracks it instead.
  void sendKeyCode(int code, {TvKeyAction action = TvKeyAction.press}) => sendKey(_session, code, action);

  /// Holds [key] down: the TV repeats it, as for a held button, until [TvKeyHold.release]. Closing the session
  /// releases it. Throws as [press].
  TvKeyHold hold(TvKey key) => _holds.start(key.code);

  /// Holds key [code] (1 to 999) down, as [hold] does. Throws as [sendKeyCode].
  TvKeyHold holdCode(int code) => _holds.start(code);

  /// Opens [link] on the TV: a deep link or a web address that an app on the TV handles (`https://www.youtube.com`,
  /// `market://details?id=…`). A link no app handles does nothing.
  ///
  /// TVs refuse a bare package name and some link forms (`intent:`, `market://launch`) and then **end the session**:
  /// [done] completes with [TvLinkRefusedException]; connect again to go on. Throws [ArgumentError] for an empty link
  /// or one over 8192 bytes in UTF-8, [TvNotSupportedException] without [TvFeature.appLink], and what ended the
  /// session once it has ended.
  void openLink(String link) => sendLink(_session, link);

  /// Brings the volume to [level] (0 to the reported maximum) with volume keys, waiting for the TV's report after
  /// each (the emulator ignored a level sent directly). Mute is left as it is.
  ///
  /// Throws [TvNotSupportedException] without [TvFeature.key] or [TvFeature.volume], or before the TV reported its
  /// volume; [RangeError] for a level out of range; [TvTimeoutException] when a report does not come within
  /// [stepTimeout] or the level is not reached within [timeout]; [TvCancelledException] when a newer [setVolume]
  /// takes over; and what ended the session if it ends meanwhile.
  Future<void> setVolume(
    int level, {
    Duration stepTimeout = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 15),
  }) => _volume.set(level, stepTimeout: stepTimeout, timeout: timeout);

  /// Opens a voice session: presses Search and waits up to [timeout] for the TV's voice search to open it. Feed it the
  /// app's microphone audio (16-bit PCM, mono, 8 kHz) and [TvVoiceSession.close] it when the user stops talking.
  ///
  /// [pace] sends the audio in real time, as a microphone delivers it; without it, chunks go out as fast as they are
  /// added. Throws [TvNotSupportedException] without [TvFeature.voice] and [TvFeature.key] (voice is not in
  /// [TvFeature.defaults]: ask for it at [connect]), [TvTimeoutException] when the TV does not open the session in
  /// time, [StateError] while another voice session of this remote is starting or not [TvVoiceSession.done], and
  /// what ended the session.
  Future<TvVoiceSession> startVoice({Duration timeout = const Duration(seconds: 2), bool pace = true}) async {
    if (_voiceBusy) throw StateError('A voice session is open');
    _voiceStarting = true;
    try {
      final previous = _voice;
      return _voice = await startVoiceSession(
        _session,
        timeout: timeout,
        pace: pace,
        afterUnconfirmed: previous != null && !previous.endConfirmed,
      );
    } finally {
      _voiceStarting = false;
    }
  }

  /// Whether a voice session is starting, or started and not done.
  bool get _voiceBusy => _voiceStarting || (_voice != null && !_voice!.isDone);

  /// The text field that has the focus on the TV, or `null`. Always `null` without [TvFeature.ime] (TVs report text
  /// fields only to sessions with it); typing also needs [TvFeature.key].
  TvTextField? get textField => features.contains(TvFeature.ime) ? _text.current : null;

  /// The focused text field each time the focus changes: a new [TvTextField], or `null` when no field has the focus.
  /// Delivered asynchronously: a field may have stopped again by the time it arrives (check [TvTextField.isFocused]).
  Stream<TvTextField?> get textFieldChanges => _text.focus;

  /// Every message from the TV as raw bytes, for messages this package does not handle yet. Experimental: the shape
  /// may change in a minor version.
  Stream<TvRawMessage> get rawMessages =>
      _session.messages.map((received) => TvRawMessage(received.message.field, received.bytes));

  /// Sends a message this package does not offer yet: [body] in envelope field [field]. Experimental: the shape may
  /// change in a minor version. Throws what ended the session once it has ended.
  ///
  /// A TV refuses a field it does not know, or a malformed message, and ends the session ([done] completes with
  /// [TvProtocolException]).
  void sendRaw(int field, List<int> body) {
    final envelope = (ProtoWriter()..bytes(field, body)).toBytes();
    _session.sendBytes(envelope, kind: _kindOf(envelope, field));
  }

  /// The traced name of a raw message: its kind when the package knows it, else `raw(field)`.
  static String _kindOf(Uint8List envelope, int field) {
    try {
      final message = RemoteEnvelope.fromClient(envelope);
      return message is UnknownEnvelope ? 'raw($field)' : message.kind;
    } on FormatException {
      return 'raw($field)';
    }
  }

  /// Ends the session, releasing held keys first. Does nothing once it has ended.
  Future<void> close() async {
    try {
      _holds.releaseAll();
    } finally {
      await _session.close();
    }
  }
}

/// One message of the remote session as it was on the wire.
final class TvRawMessage {
  /// Creates the message.
  TvRawMessage(this.field, this.envelope);

  /// The envelope field it travels in: what kind of message it is.
  final int field;

  /// The whole envelope.
  final Uint8List envelope;

  @override
  String toString() => 'TvRawMessage($field, ${envelope.length} bytes)';
}
