// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Stable identifiers for every way an operation on a TV can fail.
///
/// The names never change meaning. Codes are added only together with a new [TvRemoteException] subclass, in a major
/// version, so an exhaustive `switch` stays exhaustive within a major version.
enum TvErrorCode {
  /// No connection could be opened in time, or there is no route to the address.
  unreachable,

  /// The address answered but refused the port: the TV has no remote service, or it is off.
  noService,

  /// The TV refused the client's certificate: it does not know this client.
  notPaired,

  /// The device at the address has another key than the paired TV; nothing was sent.
  wrongTv,

  /// The code cannot be the one the TV shows; nothing was sent and the pairing stays open.
  wrongCode,

  /// The TV ended the pairing: it refused the code, answered an error, or its user cancelled.
  pairingRefused,

  /// The TV refused an app link; it closes the session right after.
  linkRefused,

  /// The TV speaks only the older version of the protocol.
  outdatedService,

  /// The TV did not offer what the call needs.
  notSupported,

  /// The connection is open but the TV stopped answering in time.
  timeout,

  /// The TV closed the connection.
  closed,

  /// The TV sent something that breaks the protocol.
  protocol,

  /// The caller cancelled the operation.
  cancelled,
}

/// The single exception type of this library for failures of operations on a TV.
///
/// Every failure is one of the subclasses, so a `switch` over a [TvRemoteException] is exhaustive. Subclasses are
/// added only in major versions. [code] gives the same information as a stable value for logs, and [cause] keeps the
/// underlying error (an `OSError`, a `TlsException`, …) when there is one.
sealed class TvRemoteException implements Exception {
  const TvRemoteException(this.message, {this.cause});

  /// What went wrong, in words meant for developers.
  final String message;

  /// The error that led to this one, if any.
  final Object? cause;

  /// The stable identifier of this failure.
  TvErrorCode get code;

  @override
  String toString() {
    final buffer = StringBuffer('TvRemoteException(${code.name}): $message');
    if (cause != null) buffer.write(' (cause: $cause)');
    return buffer.toString();
  }
}

/// No connection could be opened in time, or there is no route to the address.
final class TvUnreachableException extends TvRemoteException {
  /// Creates the exception.
  const TvUnreachableException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.unreachable;
}

/// The address answered but refused the port: the TV has no remote service, or it is off.
final class TvNoServiceException extends TvRemoteException {
  /// Creates the exception.
  const TvNoServiceException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.noService;
}

/// The TV refused the client's certificate: it does not know this client.
final class TvNotPairedException extends TvRemoteException {
  /// Creates the exception.
  const TvNotPairedException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.notPaired;
}

/// The device at the address has another key than the paired TV; nothing was sent.
final class TvWrongTvException extends TvRemoteException {
  /// Creates the exception.
  const TvWrongTvException(super.message, {required this.expected, required this.actual, super.cause});

  /// The fingerprint the caller expected (the paired TV's).
  final String expected;

  /// The fingerprint of the key the device presented.
  final String actual;

  @override
  TvErrorCode get code => TvErrorCode.wrongTv;
}

/// The code cannot be the one the TV shows; nothing was sent and the pairing stays open.
final class TvWrongCodeException extends TvRemoteException {
  /// Creates the exception.
  const TvWrongCodeException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.wrongCode;
}

/// The TV ended the pairing: it refused the code, answered an error, or its user cancelled.
final class TvPairingRefusedException extends TvRemoteException {
  /// Creates the exception.
  const TvPairingRefusedException(super.message, {this.status, super.cause});

  /// The status the TV answered (400, 401, 402 for a wrong code), or `null` if it closed the connection.
  final int? status;

  @override
  TvErrorCode get code => TvErrorCode.pairingRefused;
}

/// The TV refused an app link; it closes the session right after.
final class TvLinkRefusedException extends TvRemoteException {
  /// Creates the exception.
  const TvLinkRefusedException(super.message, {required this.link, this.refusalCode, super.cause});

  /// The refused link.
  final String link;

  /// The code of the TV's refusal (7 for a refused link), if it sent one.
  final int? refusalCode;

  @override
  TvErrorCode get code => TvErrorCode.linkRefused;
}

/// The TV speaks only the older version of the protocol.
final class TvOutdatedServiceException extends TvRemoteException {
  /// Creates the exception.
  const TvOutdatedServiceException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.outdatedService;
}

/// The TV did not offer what the call needs.
final class TvNotSupportedException extends TvRemoteException {
  /// Creates the exception.
  const TvNotSupportedException(super.message, {required this.feature, super.cause});

  /// The feature the TV did not offer, by name (`key`, `ime`, `voice`, `appLink`, …).
  final String feature;

  @override
  TvErrorCode get code => TvErrorCode.notSupported;
}

/// The connection is open but the TV stopped answering in time.
final class TvTimeoutException extends TvRemoteException {
  /// Creates the exception.
  const TvTimeoutException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.timeout;
}

/// The TV closed the connection.
final class TvClosedException extends TvRemoteException {
  /// Creates the exception.
  const TvClosedException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.closed;
}

/// The TV sent something that breaks the protocol.
final class TvProtocolException extends TvRemoteException {
  /// Creates the exception.
  const TvProtocolException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.protocol;
}

/// The caller cancelled the operation.
final class TvCancelledException extends TvRemoteException {
  /// Creates the exception.
  const TvCancelledException(super.message, {super.cause});

  @override
  TvErrorCode get code => TvErrorCode.cancelled;
}
