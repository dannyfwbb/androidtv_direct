// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

part of 'remote_messages.dart';

/// Both directions: the features and the device (field 1). The TV sends it first; the client answers with the
/// features it wants.
final class SetupMessage extends RemoteEnvelope {
  /// Creates the message.
  SetupMessage({this.features, this.device, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'setup', unknownFields);

  /// Reads the message.
  factory SetupMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return SetupMessage(
      features: fields.integer(1),
      device: fields.message(2, DeviceInfo.decode),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 1;

  /// Feature bits (`TvFeature.maskOf`).
  final int? features;

  /// The sending device.
  final DeviceInfo? device;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, features)
    ..optionalMessage(2, device);
}

/// What a device says about itself in [SetupMessage.device].
final class DeviceInfo extends ProtoMessage {
  /// Creates the description.
  DeviceInfo({
    this.model,
    this.vendor,
    this.androidRelease,
    this.packageName,
    this.serviceVersion,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(unknownFields);

  /// Reads the message.
  factory DeviceInfo.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return DeviceInfo(
      model: fields.string(1),
      vendor: fields.string(2),
      androidRelease: fields.string(4),
      packageName: fields.string(5),
      serviceVersion: fields.string(6),
      unknownFields: fields.unknown,
    );
  }

  /// The model name (field 1).
  final String? model;

  /// The maker (field 2).
  final String? vendor;

  /// The Android version, such as `14` (field 4; clients send `1`).
  final String? androidRelease;

  /// The sending app's package (field 5).
  final String? packageName;

  /// The sending app's version (field 6).
  final String? serviceVersion;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalString(1, model)
    ..optionalString(2, vendor)
    ..optionalString(4, androidRelease)
    ..optionalString(5, packageName)
    ..optionalString(6, serviceVersion);
}

/// Both directions: the session is active (field 2). The TV's is empty; the client's repeats its features.
final class ActivateMessage extends RemoteEnvelope {
  /// Creates the message.
  ActivateMessage({this.features, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'activate', unknownFields);

  /// Reads the message.
  factory ActivateMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return ActivateMessage(features: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 2;

  /// Feature bits (`TvFeature.maskOf`).
  final int? features;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, features);
}

/// Why the TV refused a message, in a [RefusalMessage] (codes seen on the Android TV emulator, remote service 7.00).
extension type const RefusalCode(int value) implements int {
  /// The TV cannot act on the message: a link it refuses, an empty link, a key without a valid action.
  static const RefusalCode cannotAct = RefusalCode(7);

  /// The TV does not know the message (its envelope field).
  static const RefusalCode unknownMessage = RefusalCode(5);
}

/// TV → client: the TV refused a message (field 3). The TV closes the connection after it.
final class RefusalMessage extends RemoteEnvelope {
  /// Creates the message.
  RefusalMessage({this.code, this.refused, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'refusal', unknownFields);

  /// Reads the message.
  factory RefusalMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return RefusalMessage(
      code: fields.integer(1) as RefusalCode?,
      refused: fields.bytes(2),
      unknownFields: fields.unknown,
    );
  }

  /// Its envelope field.
  static const int fieldNumber = 3;

  /// Why.
  final RefusalCode? code;

  /// The refused message, a whole client envelope.
  final Uint8List? refused;

  /// [refused] decoded as a client's message, or `null` if absent. Throws [FormatException] if it is malformed.
  RemoteEnvelope? get refusedMessage => switch (refused) {
    final bytes? => RemoteEnvelope.fromClient(bytes),
    null => null,
  };

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, code)
    ..optionalBytes(2, refused);
}

/// TV → client: are you there (field 8)? Sent after five seconds of silence from the client.
final class PingMessage extends RemoteEnvelope {
  /// Creates the message.
  PingMessage({this.id, Iterable<ProtoField> unknownFields = const []}) : super(fieldNumber, 'ping', unknownFields);

  /// Reads the message.
  factory PingMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PingMessage(id: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 8;

  /// The value the answer echoes (field 1).
  final int? id;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, id);
}

/// Client → TV: the answer to a [PingMessage] (field 9).
final class PongMessage extends RemoteEnvelope {
  /// Creates the message.
  PongMessage({this.id, Iterable<ProtoField> unknownFields = const []}) : super(fieldNumber, 'pong', unknownFields);

  /// Reads the message.
  factory PongMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PongMessage(id: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 9;

  /// The ping's [PingMessage.id].
  final int? id;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, id);
}

/// What happens to a key in a [KeyMessage].
extension type const KeyAction(int value) implements int {
  /// Key down; the TV repeats the key until [release].
  static const KeyAction press = KeyAction(1);

  /// Key up.
  static const KeyAction release = KeyAction(2);

  /// Down and up at once.
  static const KeyAction short = KeyAction(3);
}

/// Client → TV: a key (field 10).
final class KeyMessage extends RemoteEnvelope {
  /// Creates the message.
  KeyMessage({this.code, this.action, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'key', unknownFields);

  /// Reads the message.
  factory KeyMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return KeyMessage(code: fields.integer(1), action: fields.integer(2) as KeyAction?, unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 10;

  /// The Android key code.
  final int? code;

  /// What happens to the key.
  final KeyAction? action;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, code)
    ..optionalVarint(2, action);
}

/// TV → client: the TV is on or off (field 40). Sent when the session starts and on every change.
final class PowerReport extends RemoteEnvelope {
  /// Creates the message; [state] is 1 for on and 0 for off.
  PowerReport({this.state, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'powerReport', unknownFields);

  /// Reads the message.
  factory PowerReport.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PowerReport(state: fields.integer(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 40;

  /// The power state as sent (field 1): 1 on, 0 off. The TV writes 0 explicitly.
  final int? state;

  /// Whether the TV is on.
  bool get on => (state ?? 0) != 0;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalVarint(1, state);
}

/// Client → TV: open a link (field 90).
final class OpenLinkMessage extends RemoteEnvelope {
  /// Creates the message.
  OpenLinkMessage({this.link, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'openLink', unknownFields);

  /// Reads the message.
  factory OpenLinkMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return OpenLinkMessage(link: fields.string(1), unknownFields: fields.unknown);
  }

  /// Its envelope field.
  static const int fieldNumber = 90;

  /// The link: a deep link or a web address.
  final String? link;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalString(1, link);
}
