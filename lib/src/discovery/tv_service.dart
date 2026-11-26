// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/discovery/adb_service.dart.

import 'dart:io';

import 'package:meta/meta.dart';

/// The DNS-SD service types TVs announce.
abstract final class TvServiceType {
  /// The remote service speaking the protocol this package implements (version 2). Its port is the remote port.
  static const String v2 = '_androidtvremote2._tcp';

  /// The remote service of a TV that speaks only the older protocol: its remote service needs an update.
  static const String v1 = '_androidtvremote._tcp';

  /// Both.
  static const List<String> all = [v2, v1];
}

/// The version of the remote protocol a TV's announcement says it speaks.
enum TvProtocol {
  /// The protocol this package speaks.
  v2,

  /// The older protocol, which this package does not speak: ask the user to update the TV's remote service.
  v1,
}

/// A TV's remote service, as an mDNS browser (or a platform one) found it.
@immutable
final class TvService {
  /// Creates one.
  TvService({
    required this.type,
    required this.instance,
    required this.port,
    this.host,
    List<InternetAddress> addresses = const [],
    Map<String, String> txt = const {},
  }) : addresses = List.unmodifiable(addresses),
       txt = Map.unmodifiable(txt);

  /// One of [TvServiceType]'s types.
  final String type;

  /// The instance name: the TV's name as its user set it ("Living room TV").
  final String instance;

  /// The port of the remote service (6466 on TVs seen). Pairing uses 6467, which TVs do not announce.
  final int port;

  /// The TV's host name, when known.
  final String? host;

  /// Its addresses, most useful first (IPv4, routable, loopback last).
  final List<InternetAddress> addresses;

  /// TXT key/value pairs (`bt` is the TV's Bluetooth address).
  final Map<String, String> txt;

  /// The protocol the announcement says the TV speaks.
  TvProtocol get protocol => type.toLowerCase() == TvServiceType.v1 ? TvProtocol.v1 : TvProtocol.v2;

  /// The TV's Bluetooth address from the TXT record, when it gives one.
  String? get bluetoothAddress => txt['bt'];

  /// The address to use: the first of [addresses].
  InternetAddress? get address => addresses.isEmpty ? null : addresses.first;

  /// Whether every field equals [other]'s: the equality of services (the class keeps identity equality, so services
  /// can be kept in sets by identity).
  bool sameAs(TvService other) =>
      other.type == type &&
      other.instance == instance &&
      other.port == port &&
      other.host == host &&
      _sameList(other.addresses, addresses) &&
      _sameMap(other.txt, txt);

  static bool _sameList(List<InternetAddress> a, List<InternetAddress> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  static bool _sameMap(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  String toString() => 'TvService($instance ${protocol.name} ${address?.address ?? host}:$port)';
}

/// What a browser reports.
sealed class TvServiceEvent {
  const TvServiceEvent(this.service);

  /// The service, as it is now (for [TvServiceLost], as it was last).
  final TvService service;
}

/// A service appeared (with a port and an address).
final class TvServiceFound extends TvServiceEvent {
  /// Creates the event.
  const TvServiceFound(super.service);

  @override
  String toString() => 'found $service';
}

/// A known service changed: port, addresses or TXT.
final class TvServiceUpdated extends TvServiceEvent {
  /// Creates the event.
  const TvServiceUpdated(super.service);

  @override
  String toString() => 'updated $service';
}

/// A service went away (a goodbye, or its records expired).
final class TvServiceLost extends TvServiceEvent {
  /// Creates the event.
  const TvServiceLost(super.service);

  @override
  String toString() => 'lost $service';
}

/// Anything that finds TVs' services: `TvMdnsBrowser` on `dart:io`, or an adapter over a platform browser (iOS
/// `NWBrowser`, Android NSD), which apps need where raw multicast is not allowed.
abstract interface class TvServiceBrowser {
  /// Services of [types] (from [TvServiceType]): found, updated, lost, until the subscription is cancelled.
  Stream<TvServiceEvent> browse(List<String> types);
}

/// Internal helper for implementations.
@internal
String fullType(String type) => type.endsWith('.local') ? type : '$type.local';
