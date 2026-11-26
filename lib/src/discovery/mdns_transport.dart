// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/discovery/mdns_transport.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// How mDNS packets come and go. Internal: tests replace it.
@internal
abstract interface class MdnsTransport {
  /// Starts receiving; [onPacket] gets every datagram from port 5353 and who sent it; [onError] a failure of the
  /// socket.
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  );

  /// Sends a query to the mDNS group.
  void send(Uint8List packet);

  /// Whether it hears multicast (announcements and goodbyes), or only the unicast answers to its own queries.
  bool get hearsMulticast;

  /// Joins the group on interfaces that came up since the last call.
  Future<void> refreshInterfaces();

  /// Stops.
  Future<void> close();
}

/// mDNS over `dart:io`, on IPv4 and IPv6 alike: port 5353 shared with the system responder when possible, else a port
/// of its own (legacy unicast answers, RFC 6762 6.7). A host without one of the two families works on the other.
@internal
final class IoMdnsTransport implements MdnsTransport {
  /// The mDNS port (RFC 6762).
  static const int _port = 5353;

  static final InternetAddress _group4 = InternetAddress('224.0.0.251');
  static final InternetAddress _group6 = InternetAddress('ff02::fb');

  RawDatagramSocket? _v4;
  RawDatagramSocket? _v6;
  bool _v4Shared = false;
  bool _v6Shared = false;
  final Set<String> _joined4 = {};

  /// The interfaces queries leave through on IPv6, by name. The group is link-local, so each needs its own copy.
  final Map<String, NetworkInterface> _links6 = {};

  @override
  bool get hearsMulticast =>
      (_v4 != null || _v6 != null) && _sharedIfOpen(_v4, _v4Shared) && _sharedIfOpen(_v6, _v6Shared);

  /// Whether [socket] is absent or bound to the shared port.
  static bool _sharedIfOpen(RawDatagramSocket? socket, bool shared) => socket == null || shared;

  @override
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  ) async {
    SocketException? failure;
    try {
      await _openV4();
    } on SocketException catch (e) {
      failure = e;
    }
    try {
      await _openV6();
    } on SocketException catch (e) {
      failure ??= e;
    }
    final v4 = _v4;
    final v6 = _v6;
    if (v4 == null && v6 == null) throw failure!;
    if (v4 != null) _listen(v4, onPacket, onError);
    if (v6 != null) _listen(v6, onPacket, (error) => _onV6Error(error, onError));
  }

  /// Losing IPv6 leaves IPv4 working; only the last socket's failure ends the browsing.
  void _onV6Error(Object error, void Function(Object error) onError) {
    if (_v4 == null) return onError(error);
    _v6?.close();
    _v6 = null;
  }

  Future<void> _openV4() async {
    RawDatagramSocket? shared;
    try {
      shared = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port, reusePort: !Platform.isWindows);
      _v4 = shared;
      _v4Shared = true;
      await _refreshV4();
      if (_joined4.isEmpty) shared.joinMulticast(_group4);
    } on SocketException {
      shared?.close();
      _v4 = null;
      _joined4.clear();
      _v4Shared = false;
      _v4 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _v4!.multicastLoopback = true;
  }

  Future<void> _openV6() async {
    // Hop limit 255, as RFC 6762 11 asks of every mDNS packet.
    try {
      _v6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, _port, reusePort: !Platform.isWindows, ttl: 255);
      _v6Shared = true;
    } on SocketException {
      _v6Shared = false;
      _v6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0, ttl: 255);
    }
    _v6!.multicastLoopback = true;
    await _refreshV6();
  }

  void _listen(
    RawDatagramSocket socket,
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  ) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) break;
        // Responses come from port 5353 (RFC 6762 6).
        if (datagram.port != _port) continue;
        try {
          onPacket(datagram.data, unmapped(datagram.address));
        } on Object catch (e) {
          // A packet's problems never end the isolate.
          onError(e);
        }
      }
    }, onError: onError);
  }

  /// [address] without its IPv4-mapped form (`::ffff:192.0.2.1`): a dual-stack socket may report an IPv4 sender so, and
  /// the same sender must not count as two.
  @visibleForTesting
  static InternetAddress unmapped(InternetAddress address) {
    final raw = address.rawAddress;
    if (address.type != InternetAddressType.IPv6 || raw.length != 16) return address;
    final mapped = raw.take(10).every((byte) => byte == 0) && raw[10] == 0xff && raw[11] == 0xff;
    return mapped ? InternetAddress.fromRawAddress(raw.sublist(12), type: InternetAddressType.IPv4) : address;
  }

  @override
  Future<void> refreshInterfaces() async {
    await _refreshV4();
    await _refreshV6();
  }

  Future<void> _refreshV4() async {
    final socket = _v4;
    if (socket == null || !_v4Shared) return;
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (_joined4.contains(nic.name)) continue;
      try {
        socket.joinMulticast(_group4, nic);
        _joined4.add(nic.name);
      } on SocketException {
        // An interface without multicast.
      }
    }
  }

  Future<void> _refreshV6() async {
    final socket = _v6;
    if (socket == null) return;
    final nics = await NetworkInterface.list(type: InternetAddressType.IPv6, includeLinkLocal: true);
    _links6.removeWhere((name, known) => !nics.any((n) => n.name == name && n.index == known.index));
    for (final nic in nics) {
      if (_links6.containsKey(nic.name)) continue;
      try {
        if (_v6Shared) socket.joinMulticast(_group6, nic);
        _links6[nic.name] = nic;
      } on SocketException {
        // An interface without multicast.
      }
    }
  }

  @override
  void send(Uint8List packet) {
    try {
      _v4?.send(packet, _group4, 5353);
    } on SocketException {
      // No IPv4 route; IPv6 may still have one.
    }
    final v6 = _v6;
    if (v6 == null) return;
    for (final nic in _links6.values) {
      try {
        v6
          ..setRawOption(
            RawSocketOption.fromInt(RawSocketOption.levelIPv6, RawSocketOption.IPv6MulticastInterface, nic.index),
          )
          ..send(packet, _group6, 5353);
      } on SocketException {
        // An interface that went down; the next refresh drops it.
      }
    }
  }

  @override
  Future<void> close() async {
    _v4?.close();
    _v6?.close();
    _v4 = null;
    _v6 = null;
  }
}
