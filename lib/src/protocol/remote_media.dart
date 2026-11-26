// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

part of 'remote_messages.dart';

/// TV → client: the volume (field 50). Sent when the session starts and after every change.
final class VolumeReport extends RemoteEnvelope {
  /// Creates the message; [muteState] is 1 for muted and 0 for not.
  VolumeReport({
    this.outputName,
    this.maximum,
    this.level,
    this.muteState,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(fieldNumber, 'volumeReport', unknownFields);

  /// Reads the message.
  factory VolumeReport.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VolumeReport(
      outputName: fields.string(3),
      maximum: fields.integer(6),
      level: fields.integer(7),
      muteState: fields.integer(8),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 50;

  /// The audio output's name (field 3).
  final String? outputName;

  /// The highest level (field 6).
  final int? maximum;

  /// The level (field 7).
  final int? level;

  /// Whether the sound is muted, as sent (field 8): 1 muted, 0 not.
  final int? muteState;

  /// Whether the sound is muted.
  bool get muted => (muteState ?? 0) != 0;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalString(3, outputName)
    ..optionalVarint(6, maximum)
    ..optionalVarint(7, level)
    ..optionalVarint(8, muteState);
}

/// Client → TV: set the volume to a level (field 50). TVs seen ignore it.
final class VolumeLevelRequest extends RemoteEnvelope {
  /// Creates the message.
  VolumeLevelRequest({this.level, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'volumeLevelRequest', unknownFields);

  /// Reads the message.
  factory VolumeLevelRequest.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VolumeLevelRequest(level: fields.integer(7), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 50;

  /// The wanted level (field 7).
  final int? level;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(7, level);
}

/// Both directions: a voice session opens (field 30). The TV opens it after the search key; the client acknowledges
/// with the same [voiceId].
final class VoiceOpenMessage extends RemoteEnvelope {
  /// Creates the message.
  VoiceOpenMessage({this.voiceId, this.packageName, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'voiceOpen', unknownFields);

  /// Reads the message.
  factory VoiceOpenMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VoiceOpenMessage(voiceId: fields.integer(1), packageName: fields.string(2), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 30;

  /// The session's id (field 1).
  final int? voiceId;

  /// The TV's voice app (field 2; the client sends none).
  final String? packageName;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, voiceId)
    ..optionalString(2, packageName);
}

/// Client → TV: audio for a voice session (field 31): 16-bit little-endian PCM, mono, 8 kHz.
final class VoiceAudioMessage extends RemoteEnvelope {
  /// Creates the message.
  VoiceAudioMessage({this.voiceId, this.samples, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'voiceAudio', unknownFields);

  /// Reads the message.
  factory VoiceAudioMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VoiceAudioMessage(voiceId: fields.integer(1), samples: fields.bytes(2), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 31;

  /// The session's id (field 1).
  final int? voiceId;

  /// The audio (field 2).
  final Uint8List? samples;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, voiceId)
    ..optionalBytes(2, samples);
}

/// TV → client: the TV ended the voice session (field 31, the field the client sends audio in). Seen after the
/// client's [VoiceCloseMessage].
final class VoiceEndedMessage extends RemoteEnvelope {
  /// Creates the message.
  VoiceEndedMessage({this.voiceId, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'voiceEnded', unknownFields);

  /// Reads the message.
  factory VoiceEndedMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VoiceEndedMessage(voiceId: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 31;

  /// The session's id (field 1).
  final int? voiceId;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, voiceId);
}

/// Client → TV: the voice session ends (field 32).
final class VoiceCloseMessage extends RemoteEnvelope {
  /// Creates the message.
  VoiceCloseMessage({this.voiceId, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'voiceClose', unknownFields);

  /// Reads the message.
  factory VoiceCloseMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return VoiceCloseMessage(voiceId: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 32;

  /// The session's id (field 1).
  final int? voiceId;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, voiceId);
}
