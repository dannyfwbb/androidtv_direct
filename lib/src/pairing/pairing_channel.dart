// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:androidtv_direct/src/errors.dart';
import 'package:androidtv_direct/src/protocol/pairing_messages.dart';
import 'package:androidtv_direct/src/transport/tv_socket.dart';

/// The pairing port's request and answer, with the pairing's failures.
final class PairingChannel {
  /// Speaks over [_socket].
  PairingChannel(this._socket);

  final TvSocket _socket;

  /// Whether the connection has ended.
  bool get isClosed => _socket.isClosed;

  /// Closes the connection.
  Future<void> close() => _socket.close();

  /// Sends [body] and returns the TV's answer, which must be OK and a [T], within [timeout].
  ///
  /// Throws [TvPairingRefusedException] when the TV answers a status other than OK or closes the connection,
  /// [TvTimeoutException] when it does not answer in time, and [TvProtocolException] for anything malformed or
  /// unexpected.
  Future<T> exchange<T extends PairingBody>(PairingBody body, {required Duration timeout}) async {
    final message = PairingMessage(body: body);
    _socket.send(message.encode(), kind: message.kind);
    final answer = await _receive(timeout);
    if (!answer.isOk) throw _refusal(answer.status);
    final answerBody = answer.body;
    if (answerBody is! T) throw TvProtocolException('The TV answered ${answer.kind} where $T was expected');
    return answerBody;
  }

  Future<PairingMessage> _receive(Duration timeout) async {
    final Uint8List bytes;
    try {
      bytes = await _socket.receive(timeout: timeout);
    } on TvClosedException catch (e) {
      throw TvPairingRefusedException('The TV closed the pairing', cause: e);
    }
    try {
      final message = PairingMessage.decode(bytes);
      _socket.traceReceived(bytes, kind: message.kind);
      return message;
    } on FormatException catch (e) {
      throw TvProtocolException('The TV sent a malformed pairing message', cause: e);
    }
  }

  static TvPairingRefusedException _refusal(int? status) => TvPairingRefusedException(
    status == PairingStatus.badSecret ? 'The TV refused the code' : 'The TV answered status $status',
    status: status,
  );
}
