// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/fuzz.dart';
import '../support/hex.dart';

RemoteEnvelope decode(RecordedMessage m) =>
    m.outgoing ? RemoteEnvelope.fromClient(m.bytes) : RemoteEnvelope.fromTv(m.bytes);

/// The message called [name] that the TV sent, from the recording [file].
T fromTv<T extends RemoteEnvelope>(String name, [String file = 'session.txt']) =>
    RemoteEnvelope.fromTv(recorded(name, outgoing: false, file: file).bytes) as T;

void main() {
  final recordings = [
    for (final file in recordingFiles)
      for (final m in recordedMessages(file))
        if (m.port == 6466) m,
  ];

  test('every recorded remote message decodes to its kind and encodes to the same bytes', () {
    for (final recording in recordings) {
      final message = decode(recording);
      expect(message.kind, recording.name.split('.').first, reason: recording.name);
      expect(hex(message.encodeEnvelope()), hex(recording.bytes), reason: recording.name);
    }
  });

  test('what the client sends encodes to the recorded bytes', () {
    final sent = <(String, String), RemoteEnvelope>{
      ('setup', 'session.txt'): SetupMessage(
        features: 615,
        device: DeviceInfo(
          androidRelease: '1',
          packageName: 'atvremote',
          serviceVersion: '1.0.0',
          unknownFields: [ProtoField.varint(3, 1)],
        ),
      ),
      ('activate', 'session.txt'): ActivateMessage(features: 615),
      ('pong', 'session.txt'): PongMessage(id: 1),
      ('key', 'session.txt'): KeyMessage(code: 24, action: KeyAction.short),
      ('openLink', 'session.txt'): OpenLinkMessage(link: 'https://www.youtube.com'),
      ('voiceOpen', 'messages.txt'): VoiceOpenMessage(voiceId: 1),
      ('voiceClose', 'messages.txt'): VoiceCloseMessage(voiceId: 1),
      ('textEdit', 'text.txt'): TextEditMessage(
        keyboardRevision: 198,
        fieldRevision: 284,
        changes: [
          TextChange(
            kind: TextChangeKind.insert,
            replacement: TextReplacement(start: 2, end: 2, text: 'ab'),
          ),
        ],
      ),
    };
    for (final MapEntry(key: (name, file), value: message) in sent.entries) {
      expect(hex(message.encodeEnvelope()), hex(recorded(name, outgoing: true, file: file).bytes), reason: name);
    }
  });

  test('a volume level request and an explicit zero encode as the protocol writes them', () {
    expect(hex(VolumeLevelRequest(level: 10).encodeEnvelope()), '920302380a');
    expect(hex(PowerReport(state: 0).encodeEnvelope()), 'c202020800');
    expect(RemoteEnvelope.fromTv(unhex('c202020800')), isA<PowerReport>().having((p) => p.on, 'on', isFalse));
  });

  group("the TV's messages", () {
    test('setup describes the TV and offers features', () {
      final setup = fromTv<SetupMessage>('setup');
      expect(setup.features, 639);
      expect(setup.device!.model, 'AOSP TV on x86');
      expect(setup.device!.vendor, 'Google');
      expect(setup.device!.androidRelease, '14');
      expect(setup.device!.packageName, 'com.google.android.tv.remote.service');
      expect(setup.device!.serviceVersion, '7.00.999235495');
    });

    test('a refusal carries its code and the refused link', () {
      final refusal = fromTv<RefusalMessage>('refusal');
      expect(refusal.code, RefusalMessage.linkRefused);
      expect((refusal.refusedMessage! as OpenLinkMessage).link, 'com.android.tv.settings');
    });

    test('power, ping and volume', () {
      expect(fromTv<PowerReport>('powerReport').on, isTrue);
      expect(fromTv<PingMessage>('ping').id, 1);
      final volume = fromTv<VolumeReport>('volumeReport');
      expect((volume.level, volume.maximum, volume.muted, volume.outputName), (9, 15, false, 'AOSP TV on x86'));
    });

    test('a focused field reports its editor settings, content and cursor', () {
      final report = fromTv<FocusReport>('focusReport.3', 'text.txt');
      final app = report.app!;
      expect(app.packageName, 'com.android.tv.settings');
      expect((app.keyboardRevision, app.inputType, app.imeOptions), (198, 1, 0x1C000006));
      expect(app.privateImeOptions, 'escapeNorth');
      expect(app.viewId, 0x7F0A01C0);
      expect((report.textField!.fieldRevision, report.textField!.text), (284, ''));
    });

    test('an app without a focused field has no field', () {
      final report = fromTv<FocusReport>('focusReport.2', 'text.txt');
      expect(report.app!.packageName, 'com.android.tv.settings');
      expect(report.textField, isNull);
    });

    test('keyboard and field reports', () {
      expect(fromTv<KeyboardReport>('keyboardReport', 'text.txt').keyboardOpen, isTrue);
      expect(fromTv<KeyboardReport>('keyboardReport.2', 'text.txt').keyboardOpen, isFalse);
      final typed = fromTv<FieldReport>('fieldReport', 'text.txt').textField!;
      expect((typed.text, typed.selectionStart, typed.selectionEnd), ('ab', 2, 2));
      final cyrillic = fromTv<FieldReport>('fieldReport.4', 'text.txt').textField!;
      expect((cyrillic.text, cyrillic.selectionEnd), ('Привет, мир 👍🏽', 16));
    });

    test('one Del removes a whole emoji with its skin tone', () {
      final before = fromTv<FieldReport>('fieldReport.4', 'text.txt').textField!.text!;
      final after = fromTv<FieldReport>('fieldReport.5', 'text.txt').textField!.text!;
      expect(before.substring(after.length), '👍🏽');
    });

    test('a voice session names the voice app', () {
      final open = fromTv<VoiceOpenMessage>('voiceOpen', 'messages.txt');
      expect((open.voiceId, open.packageName), (1, 'com.google.android.katniss'));
    });
  });

  test('field 21 is a keyboard report from the TV and a text edit from the client', () {
    final bytes = recorded('keyboardReport', outgoing: false, file: 'text.txt').bytes;
    expect(RemoteEnvelope.fromTv(bytes), isA<KeyboardReport>());
    expect(RemoteEnvelope.fromClient(bytes), isA<TextEditMessage>());
  });

  test('voice audio carries the samples', () {
    final audio = VoiceAudioMessage(voiceId: 1, samples: Uint8List.fromList([1, 2, 3, 4]));
    expect(hex(audio.encodeEnvelope()), 'fa01080801120401020304');
    expect((RemoteEnvelope.fromClient(audio.encodeEnvelope()) as VoiceAudioMessage).samples, [1, 2, 3, 4]);
  });

  test('an unknown message is kept whole, whatever its wire type', () {
    for (final bytes in ['ba0f020801', 'b80f05']) {
      final message = RemoteEnvelope.fromTv(unhex(bytes));
      expect(message, isA<UnknownEnvelope>());
      expect(message.kind, 'unknown(247)');
      expect(hex(message.encodeEnvelope()), bytes);
    }
  });

  test('an envelope must have exactly one field', () {
    expect(() => RemoteEnvelope.fromTv(Uint8List(0)), throwsFormatException);
    expect(() => RemoteEnvelope.fromTv(unhex('42020801c202020801')), throwsFormatException);
  });

  test('a known message with a field of the wrong type is a format error', () {
    expect(() => RemoteEnvelope.fromTv(unhex('c2020301aaaa')), throwsFormatException);
    expect(() => RemoteEnvelope.fromTv(unhex('c00201')), throwsFormatException);
  });

  group('random and damaged input gives a message or a format error, and encodes stably', () {
    final seeds = [for (final r in recordings) r.bytes];

    Uint8List encodeAll(RemoteEnvelope message) {
      if (message is RefusalMessage) {
        try {
          message.refusedMessage;
        } on FormatException {
          // A damaged echo is the caller's FormatException, on demand.
        }
      }
      return message.encodeEnvelope();
    }

    test('envelopes from the TV', () => fuzz(RemoteEnvelope.fromTv, encode: encodeAll, seeds: seeds, seed: 1));
    test('envelopes from a client', () => fuzz(RemoteEnvelope.fromClient, encode: encodeAll, seeds: seeds, seed: 2));

    for (final (direction, decoders) in [('TV', remoteDecodersFromTv), ('client', remoteDecodersFromClient)]) {
      for (final MapEntry(key: field, value: decode) in decoders.entries) {
        final bodies = [for (final s in seeds) ?_bodyOf(s, field)];
        test('message $field from the $direction', () {
          fuzz(decode, encode: (m) => m.encode(), seeds: bodies, seed: field);
        });
      }
    }

    final nested = <String, (ProtoMessage Function(Uint8List), String)>{
      'device info': (DeviceInfo.decode, '0a0141120142220131'),
      'focused app': (FocusedApp.decode, '080c100118868080e001220165380040006201616801'),
      'text field state': (TextFieldState.decode, '0863120261621802200228 01'),
      'text change': (TextChange.decode, '0801120708011001 1a0161'),
      'text replacement': (TextReplacement.decode, '080b100b1a0161'),
    };
    for (final MapEntry(key: name, value: (decode, seed)) in nested.entries) {
      test(name, () => fuzz(decode, encode: (m) => m.encode(), seeds: [unhex(seed.replaceAll(' ', ''))]));
    }
  });
}

/// The body of envelope [bytes] if its field is [field].
Uint8List? _bodyOf(Uint8List bytes, int field) {
  final only = ProtoReader.read(bytes).single;
  return only.number == field ? only.asBytes : null;
}
