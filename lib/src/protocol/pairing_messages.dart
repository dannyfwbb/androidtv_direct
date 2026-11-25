// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The messages of the pairing port (6467).
///
/// They follow the pairing protocol in the Android Open Source Project (`external/google-tv-pairing-protocol`,
/// Copyright 2009 Google Inc., Apache-2.0), in the form version 2 of the protocol uses on the wire: instead of a type
/// and a payload, each inner message sits in the outer field whose number is its type. The class names follow AOSP's
/// message names, and their trace names ([PairingBody.kind]) are the class names in lowerCamelCase.
library;

import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/proto.dart';
import 'package:meta/meta.dart';

/// The protocol version both sides send.
const int pairingProtocolVersion = 2;

/// Status values of a [PairingMessage].
abstract final class PairingStatus {
  /// Everything is fine.
  static const int ok = 200;

  /// A generic error.
  static const int error = 400;

  /// The TV cannot use the offered configuration.
  static const int badConfiguration = 401;

  /// The secret is not the one the TV expected: the code was wrong.
  static const int badSecret = 402;
}

/// The roles a side can take: who shows the code and who types it in.
abstract final class PairingRole {
  /// Types in the code the other side shows (what clients do).
  static const int input = 1;

  /// Shows the code (what TVs do).
  static const int output = 2;
}

/// How a code is written.
abstract final class PairingEncodingType {
  /// Hexadecimal characters, the only encoding TVs have been seen to use.
  static const int hexadecimal = 3;
}

/// The envelope of every pairing message: version, status and at most one inner message.
final class PairingMessage extends ProtoMessage {
  /// Creates a message; [status] defaults to OK.
  PairingMessage({
    this.version = pairingProtocolVersion,
    this.status = PairingStatus.ok,
    this.body,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(unknownFields);

  /// Reads a message. Throws [FormatException] if it is malformed or carries two inner messages.
  factory PairingMessage.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    final bodies = [
      for (final MapEntry(key: number, value: decode) in pairingBodyDecoders.entries) ?fields.message(number, decode),
    ];
    if (bodies.length > 1) throw const FormatException('Pairing message with two inner messages');
    return PairingMessage(
      version: fields.integer(1),
      status: fields.integer(2),
      body: bodies.firstOrNull,
      unknownFields: fields.unknown,
    );
  }

  /// The protocol version (field 1).
  final int? version;

  /// The status (field 2); see [PairingStatus].
  final int? status;

  /// The inner message, or `null` (a status-only answer).
  final PairingBody? body;

  /// Whether [status] says OK.
  bool get isOk => status == PairingStatus.ok;

  /// The inner message's name, or `status` for a message without one, for traces.
  String get kind => body?.kind ?? 'status';

  @override
  void writeFields(ProtoWriter writer) {
    writer
      ..optionalVarint(1, version)
      ..optionalVarint(2, status);
    if (body case final body?) writer.message(body.field, body);
  }
}

/// The decoder of every inner message, by its field in [PairingMessage].
@visibleForTesting
final Map<int, PairingBody Function(Uint8List)> pairingBodyDecoders = {
  PairingRequest.fieldNumber: PairingRequest.decode,
  PairingRequestAck.fieldNumber: PairingRequestAck.decode,
  PairingOptions.fieldNumber: PairingOptions.decode,
  PairingConfiguration.fieldNumber: PairingConfiguration.decode,
  PairingConfigurationAck.fieldNumber: PairingConfigurationAck.decode,
  PairingSecret.fieldNumber: PairingSecret.decode,
  PairingSecretAck.fieldNumber: PairingSecretAck.decode,
};

/// An inner pairing message.
sealed class PairingBody extends ProtoMessage {
  PairingBody(this.field, this.kind, super.unknownFields);

  /// The field of [PairingMessage] it travels in.
  final int field;

  /// This package's name for it, for traces.
  final String kind;
}

/// Client → TV: start pairing (step 1).
final class PairingRequest extends PairingBody {
  /// Creates the request. [clientName] is shown in the TV's dialog.
  PairingRequest({required this.serviceName, this.clientName, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingRequest', unknownFields);

  /// Reads the message.
  factory PairingRequest.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingRequest(serviceName: fields.string(1), clientName: fields.string(2), unknownFields: fields.unknown);
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 10;

  /// The service asked for; `atvremote` in every client.
  final String? serviceName;

  /// The name the TV shows to the user.
  final String? clientName;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalString(1, serviceName)
    ..optionalString(2, clientName);
}

/// TV → client: the request is accepted.
final class PairingRequestAck extends PairingBody {
  /// Creates the answer.
  PairingRequestAck({this.serverName, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingRequestAck', unknownFields);

  /// Reads the message.
  factory PairingRequestAck.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingRequestAck(serverName: fields.string(1), unknownFields: fields.unknown);
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 11;

  /// The TV's name, if it sends one (TVs seen send none).
  final String? serverName;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalString(1, serverName);
}

/// A code format: its [type] (see [PairingEncodingType]) and [symbolLength].
final class PairingEncoding extends ProtoMessage {
  /// Creates the encoding.
  PairingEncoding({this.type, this.symbolLength, Iterable<ProtoField> unknownFields = const []}) : super(unknownFields);

  /// Six hexadecimal characters: what TVs use.
  PairingEncoding.hex6() : this(type: PairingEncodingType.hexadecimal, symbolLength: 6);

  /// Reads the message.
  factory PairingEncoding.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingEncoding(type: fields.integer(1), symbolLength: fields.integer(2), unknownFields: fields.unknown);
  }

  /// The kind of characters; see [PairingEncodingType].
  final int? type;

  /// How many characters the code has.
  final int? symbolLength;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalVarint(1, type)
    ..optionalVarint(2, symbolLength);
}

/// Both directions: the encodings a side can show or type in, and its preferred role (step 2).
final class PairingOptions extends PairingBody {
  /// Creates the options.
  PairingOptions({
    this.inputEncodings = const [],
    this.outputEncodings = const [],
    this.preferredRole,
    Iterable<ProtoField> unknownFields = const [],
  }) : super(fieldNumber, 'pairingOptions', unknownFields);

  /// Reads the message.
  factory PairingOptions.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingOptions(
      inputEncodings: fields.repeated(1, PairingEncoding.decode),
      outputEncodings: fields.repeated(2, PairingEncoding.decode),
      preferredRole: fields.integer(3),
      unknownFields: fields.unknown,
    );
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 20;

  /// Encodings this side can type in.
  final List<PairingEncoding> inputEncodings;

  /// Encodings this side can show.
  final List<PairingEncoding> outputEncodings;

  /// The role this side prefers; see [PairingRole].
  final int? preferredRole;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..repeatedMessage(1, inputEncodings)
    ..repeatedMessage(2, outputEncodings)
    ..optionalVarint(3, preferredRole);
}

/// Client → TV: the chosen encoding and role (step 3). The TV shows the code after it.
final class PairingConfiguration extends PairingBody {
  /// Creates the configuration.
  PairingConfiguration({this.encoding, this.clientRole, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingConfiguration', unknownFields);

  /// Reads the message.
  factory PairingConfiguration.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingConfiguration(
      encoding: fields.message(1, PairingEncoding.decode),
      clientRole: fields.integer(2),
      unknownFields: fields.unknown,
    );
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 30;

  /// The code's format.
  final PairingEncoding? encoding;

  /// The client's role; see [PairingRole].
  final int? clientRole;

  @override
  void writeFields(ProtoWriter writer) => writer
    ..optionalMessage(1, encoding)
    ..optionalVarint(2, clientRole);
}

/// TV → client: the configuration is accepted and the code is on screen.
final class PairingConfigurationAck extends PairingBody {
  /// Creates the answer.
  PairingConfigurationAck({Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingConfigurationAck', unknownFields);

  /// Reads the message.
  factory PairingConfigurationAck.decode(Uint8List bytes) =>
      PairingConfigurationAck(unknownFields: ProtoReader.read(bytes));

  /// Its field in [PairingMessage].
  static const int fieldNumber = 31;

  @override
  void writeFields(ProtoWriter writer) {}
}

/// Client → TV: the secret made from the code (step 4).
final class PairingSecret extends PairingBody {
  /// Creates the message.
  PairingSecret({this.secret, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingSecret', unknownFields);

  /// Reads the message.
  factory PairingSecret.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingSecret(secret: fields.bytes(1), unknownFields: fields.unknown);
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 40;

  /// The 32-byte secret.
  final Uint8List? secret;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalBytes(1, secret);
}

/// TV → client: the secret was right; the TV echoes it.
final class PairingSecretAck extends PairingBody {
  /// Creates the answer.
  PairingSecretAck({this.secret, Iterable<ProtoField> unknownFields = const []})
    : super(fieldNumber, 'pairingSecretAck', unknownFields);

  /// Reads the message.
  factory PairingSecretAck.decode(Uint8List bytes) {
    final fields = ProtoFields.read(bytes);
    return PairingSecretAck(secret: fields.bytes(1), unknownFields: fields.unknown);
  }

  /// Its field in [PairingMessage].
  static const int fieldNumber = 41;

  /// The client's secret, echoed.
  final Uint8List? secret;

  @override
  void writeFields(ProtoWriter writer) => writer.optionalBytes(1, secret);
}
