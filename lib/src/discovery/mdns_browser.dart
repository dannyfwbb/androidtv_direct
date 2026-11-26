// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/discovery/mdns_browser.dart.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:androidtv_direct/src/clock.dart';
import 'package:androidtv_direct/src/discovery/dns_message.dart';
import 'package:androidtv_direct/src/discovery/mdns_transport.dart';
import 'package:androidtv_direct/src/discovery/tv_service.dart';
import 'package:meta/meta.dart';

/// A DNS-SD browser on `dart:io` multicast (RFC 6762, 6763): desktop and Android.
///
/// It listens on port 5353 next to the system's responder (sharing the port) and hears announcements and goodbyes;
/// where the port cannot be shared it falls back to asking from a port of its own, and then notices a TV leaving
/// only when its records expire. It asks again at growing intervals (1 s, 2 s, 4 s, … up to [maxQueryInterval]),
/// refreshes records at 80 % and 90 % of their TTL, resolves what a PTR names (SRV, TXT, addresses), and keeps only
/// records that belong to the browsed types.
///
/// Works over IPv4 and IPv6. IPv4 queries leave through the system's default multicast interface, IPv6 queries through
/// every interface; a link-local address comes with the zone it was heard on, so it can be connected to. On Android the
/// app must hold a `WifiManager.MulticastLock` while browsing, or Wi-Fi drivers drop multicast. On iOS raw multicast
/// needs an entitlement: use a platform browser through [TvServiceBrowser] instead.
final class TvMdnsBrowser implements TvServiceBrowser {
  /// Creates a browser.
  TvMdnsBrowser({
    Duration maxQueryInterval = const Duration(seconds: 60),
    TvClock clock = TvClock.system,
    @visibleForTesting MdnsTransport? transport,
  }) : maxQueryInterval = _checkInterval(maxQueryInterval),
       _clock = clock,
       _transport = transport;

  /// The shortest [maxQueryInterval]: RFC 6762 5.2 asks for at least a second between questions.
  static const Duration minQueryInterval = Duration(seconds: 1);

  static Duration _checkInterval(Duration interval) {
    if (interval < minQueryInterval) {
      throw ArgumentError.value('$interval', 'maxQueryInterval', 'must be at least $minQueryInterval');
    }
    return interval;
  }

  /// The longest pause between two rounds of questions, at least [minQueryInterval].
  final Duration maxQueryInterval;

  final TvClock _clock;
  final MdnsTransport? _transport;

  @override
  Stream<TvServiceEvent> browse(List<String> types) {
    if (types.isEmpty) throw ArgumentError.value(types, 'types', 'is empty');
    late final _Session session;
    // Synchronous: events come from packet and timer callbacks, never from inside a caller's own call. Ends when the
    // subscriber cancels.
    // ignore: close_sinks
    final controller = StreamController<TvServiceEvent>(
      sync: true,
      onListen: () => session.start(),
      onCancel: () => session.stop(),
    );
    session = _Session(
      types: {for (final t in types) _normalType(t)},
      transport: _transport ?? IoMdnsTransport(),
      clock: _clock,
      maxInterval: maxQueryInterval,
      emit: controller.add,
      fail: controller.addError,
    );
    return controller.stream;
  }

  static String _normalType(String type) {
    final name = type.toLowerCase().replaceFirst(_trailingDots, '');
    return name.endsWith('.local') ? name : '$name.local';
  }

  static final RegExp _trailingDots = RegExp(r'\.+$');
}

/// A cached record from one sender.
final class _Entry {
  _Entry(this.record, {required this.received, required this.expires, required this.from})
    : name = record.name.toLowerCase();

  final DnsRecord record;

  /// The record's name, lower-case: names compare without case (RFC 6762 16).
  final String name;
  final Duration received;
  Duration expires;
  final String from;

  /// Refresh questions already sent for this lifetime (at 80 %, 90 %).
  int refreshes = 0;

  Duration get lifetime => Duration(seconds: record.ttl);
}

/// The cache as lookups need it.
final class _CacheView {
  _CacheView(Iterable<_Entry> entries, bool Function(DnsRecord) isBrowsedPtr) {
    for (final e in entries) {
      (byName[e.name] ??= []).add(e);
      if (e.record.data case DnsPointer(:final target) when isBrowsedPtr(e.record)) {
        if (instanceNames.add(target.toLowerCase())) instances.add(target);
      }
    }
    for (final e in entries) {
      if (e.record.data case DnsSrv(:final target) when instanceNames.contains(e.name)) hosts.add(target.toLowerCase());
    }
  }

  /// Entries by lower-case name.
  final Map<String, List<_Entry>> byName = {};

  /// The instances of the browsed types, once each, in the case of their latest announcement.
  final List<String> instances = [];

  /// [instances], lower-case.
  final Set<String> instanceNames = {};

  /// The hosts the instances' SRV records name, lower-case.
  final Set<String> hosts = {};
}

/// Bounds against a noisy or hostile network.
const int _maxEntries = 1024;
const int _maxTtl = 4500; // 75 minutes, Android's PTR TTL.

/// How often the cache is maintained, and the shortest gap between repeats of a question.
const Duration _second = Duration(seconds: 1);

/// The longest gap between repeats of a question (RFC 6762 5.2).
const Duration _maxQuestionGap = Duration(seconds: 60);

/// How long reports wait for the rest of an announcement.
const Duration _reportDelay = Duration(milliseconds: 100);

/// Maintenance ticks between looks for new interfaces.
const int _ticksPerInterfaceRefresh = 30;

typedef _CacheKey = ({String name, int type, String data, String sender});
typedef _Question = ({String name, int type});

final class _Session {
  _Session({
    required this.types,
    required this.transport,
    required this.clock,
    required this.maxInterval,
    required this.emit,
    required this.fail,
  });

  final Set<String> types;
  final MdnsTransport transport;
  final TvClock clock;
  final Duration maxInterval;
  final void Function(TvServiceEvent) emit;
  final void Function(Object) fail;

  /// Lower-case name, type, data and sender → entry, oldest first.
  final Map<_CacheKey, _Entry> _cache = {};

  /// What the cache holds, by name, built when first needed after the cache changed: every packet and tick looks
  /// names up, and a full cache (a flood) must not make each of them scan it once per instance.
  _CacheView? _index;

  _CacheView get _view => _index ??= _CacheView(_cache.values, _isBrowsedPtr);

  /// The entries named [name], in any case.
  List<_Entry> _named(String name) => _view.byName[name.toLowerCase()] ?? const [];

  /// Lowercase instance full name → service reported.
  final Map<String, TvService> _reported = {};

  /// Question (lower-case name) → when it may be asked again, and the gap that led there.
  final Map<_Question, ({Duration next, Duration gap})> _asked = {};

  Timer? _queryTimer;
  Timer? _tick;
  Timer? _reportTimer;
  Duration _interval = _second;
  bool _stopped = false;
  int _ticks = 0;

  /// Legacy answers live 10 s: ask at least this often then.
  static const Duration _legacyCap = Duration(seconds: 5);

  Duration get _cap => transport.hearsMulticast || maxInterval <= _legacyCap ? maxInterval : _legacyCap;

  Future<void> start() async {
    try {
      await transport.start(_onPacket, _onError);
    } on Object catch (e) {
      fail(e);
      return;
    }
    if (_stopped) {
      // Cancelled while the socket was being bound.
      await transport.close();
      return;
    }
    _round();
    _scheduleTick();
  }

  Future<void> stop() async {
    _stopped = true;
    _queryTimer?.cancel();
    _tick?.cancel();
    _reportTimer?.cancel();
    await transport.close();
  }

  void _onError(Object error) {
    if (!_stopped) fail(error);
  }

  void _scheduleTick() {
    _tick = clock.timer(_second, () {
      if (_stopped) return;
      _maintain();
      if (++_ticks % _ticksPerInterfaceRefresh == 0) {
        transport.refreshInterfaces().then((_) {}, onError: _onError).ignore();
      }
      _scheduleTick();
    });
  }

  /// One round of PTR questions, then the next one later.
  void _round() {
    if (_stopped) return;
    _send([for (final t in types) DnsQuestion(t, DnsType.ptr)]);
    final wait = _interval;
    _interval = shorter(_interval * 2, _cap);
    _queryTimer = clock.timer(wait, _round);
  }

  void _send(List<DnsQuestion> questions) {
    if (questions.isEmpty || _stopped) return;
    try {
      transport.send(DnsMessage.query(questions));
    } on Object {
      // A network that went away; the next round tries again.
    }
  }

  /// A question unless it was asked recently; each repeat waits twice as long, up to a minute (RFC 6762 5.2).
  DnsQuestion? _limited(String name, int type) {
    final now = clock.elapsed;
    final key = (name: name.toLowerCase(), type: type);
    final last = _asked[key];
    if (last != null && now < last.next) return null;
    final gap = last == null ? _second : shorter(last.gap * 2, _maxQuestionGap);
    _asked[key] = (next: now + gap, gap: gap);
    return DnsQuestion(name, type);
  }

  /// SRV/TXT of instances without an SRV, addresses of targets without one, each rate-limited; of [instances] only,
  /// or of every instance known.
  List<DnsQuestion> _missing([Iterable<String>? instances]) {
    final questions = <DnsQuestion>[];
    for (final instance in instances ?? _view.instances) {
      final srv = _srv(instance);
      if (srv == null) {
        questions.addAll([?_limited(instance, DnsType.srv), ?_limited(instance, DnsType.txt)]);
      } else if (_addresses(srv.target).isEmpty) {
        questions.addAll([?_limited(srv.target, DnsType.a), ?_limited(srv.target, DnsType.aaaa)]);
      }
    }
    // Forget limits for what is no longer asked.
    if (_asked.length > 4 * _maxEntries) _asked.clear();
    return questions;
  }

  void _onPacket(Uint8List packet, InternetAddress from) {
    if (_stopped) return;
    final DnsMessage message;
    try {
      message = DnsMessage.decode(packet);
    } on FormatException {
      return; // Somebody's malformed packet: not ours to fail on.
    }
    if (!message.isResponse || message.answers.isEmpty) return;

    final now = clock.elapsed;
    final sender = from.address;
    final answers = message.answers.where(_relevance(message.answers)).toList();
    final flushed = _flush(answers, sender, now);
    final stored = _store(answers, sender, now);
    _bound();
    if (flushed || stored) _scheduleReport();
    // Only what this packet named can need a question now; the tick asks for the rest.
    _send(_missing(_instancesIn(answers)));
  }

  /// The instances [answers] name: PTR targets and the owners of SRV and TXT records.
  Set<String> _instancesIn(List<DnsRecord> answers) => {
    for (final r in answers)
      ?switch (r.data) {
        DnsPointer(:final target) => target,
        DnsSrv() || DnsText() => r.name,
        _ => null,
      },
  };

  /// Only what belongs to the browsed types: their PTRs, the instances those name (in the cache or in [answers]), and
  /// the hosts their SRVs name. Everything else on the network is ignored.
  bool Function(DnsRecord) _relevance(List<DnsRecord> answers) {
    final view = _view;
    final newInstances = {
      for (final r in answers)
        if (r.data case DnsPointer(:final target) when _isBrowsedPtr(r)) target.toLowerCase(),
    };
    bool isInstance(String name) => view.instanceNames.contains(name) || newInstances.contains(name);
    final newHosts = {
      for (final r in answers)
        if (r.data case DnsSrv(:final target) when isInstance(r.name.toLowerCase())) target.toLowerCase(),
    };
    bool isHost(String name) => view.hosts.contains(name) || newHosts.contains(name);
    return (r) => switch (r.type) {
      DnsType.ptr => _isBrowsedPtr(r),
      DnsType.srv || DnsType.txt => isInstance(r.name.toLowerCase()),
      DnsType.a || DnsType.aaaa => isHost(r.name.toLowerCase()),
      _ => false,
    };
  }

  /// A PTR of a browsed type that names an instance of that type (`<Instance>.<type>`, RFC 6763 4.1); one pointing
  /// elsewhere would mix up the types of the services it names.
  bool _isBrowsedPtr(DnsRecord r) {
    if (r.data case DnsPointer(:final target) when r.type == DnsType.ptr) {
      final type = r.name.toLowerCase();
      final full = target.toLowerCase();
      return types.contains(type) && full.length > type.length + 1 && full.endsWith('.$type');
    }
    return false;
  }

  /// Cache-flush: the bit replaces the older records of the set from the same sender that are more than a second old
  /// (RFC 6762 10.2). True when something went.
  bool _flush(List<DnsRecord> answers, String sender, Duration now) {
    final before = _cache.length;
    for (final r in answers.where((r) => r.cacheFlush && r.ttl > 0)) {
      final name = r.name.toLowerCase();
      _cache.removeWhere(
        (key, e) => key.name == name && key.type == r.type && key.sender == sender && e.received < now - _second,
      );
    }
    if (_cache.length == before) return false;
    _index = null;
    return true;
  }

  /// Stores [answers]; a goodbye (TTL 0) makes this sender's record go in a second (RFC 6762 10.1), while the same
  /// record from another interface stays. True when something was stored.
  bool _store(List<DnsRecord> answers, String sender, Duration now) {
    var stored = false;
    for (final r in answers) {
      final key = (name: r.name.toLowerCase(), type: r.type, data: r.data.key, sender: sender);
      if (r.ttl == 0) {
        _cache[key]
          ?..expires = now + _second
          ..refreshes = 2;
        continue;
      }
      final record = r.ttl > _maxTtl ? r.withTtl(_maxTtl) : r;
      _index = null;
      // Removed first, so the map's order stays the order of arrival, which [_bound] relies on.
      _cache.remove(key);
      _cache[key] = _Entry(
        record,
        received: now,
        expires: now + Duration(seconds: record.ttl),
        from: sender,
      );
      stored = true;
    }
    return stored;
  }

  /// Drops the oldest entries beyond the bound.
  void _bound() {
    if (_cache.length <= _maxEntries) return;
    _index = null;
    final oldest = _cache.keys.take(_cache.length - _maxEntries).toList();
    oldest.forEach(_cache.remove);
  }

  /// Once a second: expiry, refresh questions at 80 % and 90 % of a record's TTL (RFC 6762 5.2), questions for what is
  /// still missing.
  void _maintain() {
    final now = clock.elapsed;
    final before = _cache.length;
    _cache.removeWhere((_, e) => e.expires <= now);
    if (_cache.length != before) _index = null;
    _send(_refreshQuestions(now));
    _send(_missing());
    if (_cache.length != before) _scheduleReport();
  }

  /// One question for each name and type with a record due for a refresh; counts the refresh.
  List<DnsQuestion> _refreshQuestions(Duration now) {
    final questions = <DnsQuestion>[];
    final asked = <_Question>{};
    for (final e in _cache.values) {
      final due = switch (e.refreshes) {
        0 => e.lifetime * 0.8,
        1 => e.lifetime * 0.9,
        _ => null,
      };
      if (due == null || now - e.received < due) continue;
      e.refreshes++;
      if (asked.add((name: e.name, type: e.record.type))) questions.add(DnsQuestion(e.record.name, e.record.type));
    }
    return questions;
  }

  /// Reports a little later, so the records of one announcement (often several packets, one per interface) arrive
  /// together.
  void _scheduleReport() {
    _reportTimer ??= clock.timer(_reportDelay, () {
      _reportTimer = null;
      if (!_stopped) _report();
    });
  }

  /// The newest record of [type] for [name].
  _Entry? _newest(String name, int type) {
    _Entry? newest;
    for (final e in _named(name).where((e) => e.record.type == type)) {
      if (newest == null || e.received >= newest.received) newest = e;
    }
    return newest;
  }

  DnsSrv? _srv(String instance) => switch (_newest(instance, DnsType.srv)?.record.data) {
    final DnsSrv srv => srv,
    _ => null,
  };

  /// The host's addresses, most useful first: IPv4 before IPv6, routable before link-local, loopback last; no
  /// duplicates.
  List<InternetAddress> _addresses(String host) {
    final found = {
      for (final e in _named(host))
        if (e.record.data case DnsAddress(:final address)) _inZoneOf(address, e.from),
    }.toList();
    return found..sort((a, b) {
      final byRank = _rank(a).compareTo(_rank(b));
      return byRank != 0 ? byRank : a.address.compareTo(b.address);
    });
  }

  /// Lower is more useful: IPv4 first, then routable before link-local, loopback last.
  static int _rank(InternetAddress a) =>
      (a.isLoopback ? 4 : 0) + (a.isLinkLocal ? 2 : 0) + (a.type == InternetAddressType.IPv4 ? 0 : 1);

  /// [address], with the zone of [sender] when it is an IPv6 link-local one: `fe80::` means nothing without the
  /// interface, and the record does not name it.
  static InternetAddress _inZoneOf(InternetAddress address, String sender) {
    if (address.type != InternetAddressType.IPv6 || !address.isLinkLocal || address.address.contains('%')) {
      return address;
    }
    final zone = sender.indexOf('%');
    if (zone < 0) return address;
    return InternetAddress.tryParse('${address.address}${sender.substring(zone)}') ?? address;
  }

  /// The pairs of the newest TXT record (RFC 6763 6.4: keys compare without case, the first occurrence wins, an empty
  /// key is ignored).
  Map<String, String> _txt(String instance) {
    final strings = switch (_newest(instance, DnsType.txt)?.record.data) {
      DnsText(:final strings) => strings,
      _ => const <String>[],
    };
    final txt = <String, String>{};
    for (final s in strings) {
      final eq = s.indexOf('=');
      final key = (eq < 0 ? s : s.substring(0, eq)).toLowerCase();
      if (key.isEmpty || txt.containsKey(key)) continue;
      txt[key] = eq < 0 ? '' : s.substring(eq + 1);
    }
    return txt;
  }

  /// Compares what the cache says now with what was reported.
  void _report() {
    final now = _currentServices();
    for (final MapEntry(:key, :value) in now.entries) {
      final before = _reported[key];
      if (before == null) {
        emit(TvServiceFound(value));
      } else if (!before.sameAs(value)) {
        emit(TvServiceUpdated(value));
      }
    }
    for (final MapEntry(:key, :value) in _reported.entries) {
      if (!now.containsKey(key)) emit(TvServiceLost(value));
    }
    _reported
      ..clear()
      ..addAll(now);
  }

  /// Every complete service in the cache, by lower-case full name.
  Map<String, TvService> _currentServices() {
    final services = <String, TvService>{};
    for (final e in _cache.values) {
      if (e.record.data case DnsPointer(:final target) when _isBrowsedPtr(e.record)) {
        final key = target.toLowerCase();
        if (services.containsKey(key)) continue;
        if (_service(e.name, target) case final service?) services[key] = service;
      }
    }
    return services;
  }

  /// The service [fullName] of [type] (`Living room TV._androidtvremote2._tcp.local`), once its SRV and an address are
  /// known. An SRV with port 0 says the service is not available (RFC 6763 6).
  TvService? _service(String type, String fullName) {
    final srv = _srv(fullName);
    if (srv == null || srv.port == 0) return null;
    final addresses = _addresses(srv.target);
    if (addresses.isEmpty) return null;
    return TvService(
      type: type.substring(0, type.length - '.local'.length),
      instance: fullName.substring(0, fullName.length - type.length - 1),
      port: srv.port,
      host: srv.target,
      addresses: addresses,
      txt: _txt(fullName),
    );
  }
}
