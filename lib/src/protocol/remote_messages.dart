// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The messages of the remote port (6466).
///
/// Every message is an envelope with exactly one field set; the field's number says what it is. Field numbers are
/// facts of the wire; every name here is this package's own (`doc/protocol.md` lists them). Messages keep the fields
/// they do not model, so the TV's messages encode back to the same bytes.
library;

import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:meta/meta.dart';

part 'remote_session.dart';
part 'remote_text.dart';
part 'remote_media.dart';

/// One message of the remote port.
///
/// Decode with [RemoteEnvelope.fromTv] or [RemoteEnvelope.fromClient]: a few field numbers mean different messages in
/// each direction (21 is a keyboard report from the TV and a text edit from the client).
sealed class RemoteEnvelope extends ProtoMessage {
  RemoteEnvelope(this.field, this.kind, super.unknownFields);

  /// Reads a message the TV sent. Throws [FormatException] if it is malformed.
  factory RemoteEnvelope.fromTv(Uint8List bytes) => _decode(bytes, remoteDecodersFromTv);

  /// Reads a message a client sent. Throws [FormatException] if it is malformed.
  factory RemoteEnvelope.fromClient(Uint8List bytes) => _decode(bytes, remoteDecodersFromClient);

  /// The envelope field it travels in.
  final int field;

  /// This package's name for it, for traces.
  final String kind;

  /// The whole envelope in wire format.
  Uint8List encodeEnvelope() => (ProtoWriter()..message(field, this)).toBytes();

  @override
  String toString() => kind;

  static RemoteEnvelope _decode(Uint8List bytes, Map<int, RemoteEnvelope Function(Uint8List)> decoders) {
    final fields = ProtoReader.read(bytes);
    if (fields.length != 1) throw FormatException('Envelope with ${fields.length} fields, expected one');
    final field = fields.single;
    final decode = decoders[field.number];
    return decode == null ? UnknownEnvelope(field) : decode(field.asBytes);
  }
}

/// The decoder of every message the TV sends, by envelope field.
@visibleForTesting
final Map<int, RemoteEnvelope Function(Uint8List)> remoteDecodersFromTv = {
  SetupMessage.fieldNumber: SetupMessage.decode,
  ActivateMessage.fieldNumber: ActivateMessage.decode,
  RefusalMessage.fieldNumber: RefusalMessage.decode,
  PingMessage.fieldNumber: PingMessage.decode,
  FocusReport.fieldNumber: FocusReport.decode,
  KeyboardReport.fieldNumber: KeyboardReport.decode,
  FieldReport.fieldNumber: FieldReport.decode,
  VoiceOpenMessage.fieldNumber: VoiceOpenMessage.decode,
  VoiceEndedMessage.fieldNumber: VoiceEndedMessage.decode,
  PowerReport.fieldNumber: PowerReport.decode,
  VolumeReport.fieldNumber: VolumeReport.decode,
};

/// The decoder of every message a client sends, by envelope field.
@visibleForTesting
final Map<int, RemoteEnvelope Function(Uint8List)> remoteDecodersFromClient = {
  SetupMessage.fieldNumber: SetupMessage.decode,
  ActivateMessage.fieldNumber: ActivateMessage.decode,
  PongMessage.fieldNumber: PongMessage.decode,
  KeyMessage.fieldNumber: KeyMessage.decode,
  TextEditMessage.fieldNumber: TextEditMessage.decode,
  VoiceOpenMessage.fieldNumber: VoiceOpenMessage.decode,
  VoiceAudioMessage.fieldNumber: VoiceAudioMessage.decode,
  VoiceCloseMessage.fieldNumber: VoiceCloseMessage.decode,
  VolumeLevelRequest.fieldNumber: VolumeLevelRequest.decode,
  OpenLinkMessage.fieldNumber: OpenLinkMessage.decode,
};

/// A message this package does not know, kept as it was.
///
/// The TV's remote service updates itself and may add messages; they are reported, never an error.
final class UnknownEnvelope extends RemoteEnvelope {
  /// Wraps the envelope's only field.
  UnknownEnvelope(this.content) : super(content.number, 'unknown(${content.number})', const []);

  /// The envelope's field as it was read.
  final ProtoField content;

  @override
  Uint8List encodeEnvelope() => (ProtoWriter()..raw([content])).toBytes();

  /// The message without the envelope: the field's bytes. Throws [UnsupportedError] for a field that is not
  /// length-delimited, which has no message inside; [encodeEnvelope] writes any field.
  @override
  Uint8List encode() {
    if (content.wireType != WireType.lengthDelimited) {
      throw UnsupportedError('Envelope field $field is a ${content.wireType.name}, not a message');
    }
    return content.asBytes;
  }

  @override
  void writeFields(ProtoWriter writer) {
    // Never called: encode is overridden.
  }
}
