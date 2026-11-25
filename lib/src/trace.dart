// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// How much a [TvTracer] sees.
enum TvTraceLevel {
  /// Connection steps and every message by kind and size. No typed text, voice audio, links or key material.
  messages,

  /// Also every message's bytes, which include typed text, voice audio and links. For debugging only.
  raw,
}

/// Receives what a pairing or a session does, for logs, debugging and recording.
///
/// [onEvent] is called synchronously on the event loop; keep it cheap. At [TvTraceLevel.messages], the default,
/// events never carry message contents.
final class TvTracer {
  /// Creates a tracer that hands events to [onEvent].
  const TvTracer(this.onEvent, {this.level = TvTraceLevel.messages});

  /// Called with every event.
  final void Function(TvTraceEvent event) onEvent;

  /// How much the events carry.
  final TvTraceLevel level;

  /// Whether events carry message bytes.
  bool get includesRaw => level == TvTraceLevel.raw;
}

/// One traced event.
sealed class TvTraceEvent {
  const TvTraceEvent(this.at);

  /// When it happened, on the connection's clock (monotonic; only differences are meaningful).
  final Duration at;
}

/// A message sent or received.
final class TvMessageTrace extends TvTraceEvent {
  /// Creates the event.
  const TvMessageTrace({
    required Duration at,
    required this.outgoing,
    required this.port,
    required this.kind,
    required this.length,
    this.raw,
  }) : super(at);

  /// Whether the client sent it.
  final bool outgoing;

  /// The TV's port: 6467 for pairing, 6466 for the remote session.
  final int port;

  /// The message's name, such as `key` or `volumeReport`, or `unknown(n)` for a message the package does not know.
  final String kind;

  /// The message's length in bytes, without the length prefix.
  final int length;

  /// The message's bytes without the length prefix, only at [TvTraceLevel.raw]. Do not modify them.
  final Uint8List? raw;

  @override
  String toString() => "${outgoing ? '>' : '<'} $port $kind ($length bytes)";
}

/// A change of connection state, or anything else worth a log line.
final class TvNoteTrace extends TvTraceEvent {
  /// Creates the event.
  const TvNoteTrace({required Duration at, required this.message}) : super(at);

  /// What happened.
  final String message;

  @override
  String toString() => message;
}
