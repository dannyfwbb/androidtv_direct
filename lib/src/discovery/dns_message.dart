// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0
//
// Based on adb_direct's lib/src/discovery/dns_message.dart.

/// The part of DNS (RFC 1035) and multicast DNS (RFC 6762) that browsing for DNS-SD services (RFC 6763) needs: queries
/// out, PTR, SRV, TXT, A and AAAA records in, with name compression, the cache-flush bit and TTLs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Record types used here.
@internal
abstract final class DnsType {
  static const int a = 1;
  static const int ptr = 12;
  static const int txt = 16;
  static const int aaaa = 28;
  static const int srv = 33;
  static const int any = 255;
}

/// A question.
@internal
@immutable
final class DnsQuestion {
  const DnsQuestion(this.name, this.type, {this.unicastResponse = false});

  /// The name asked about, without the trailing dot.
  final String name;

  /// The record type.
  final int type;

  /// The QU bit: ask for a unicast answer (RFC 6762 5.4).
  final bool unicastResponse;
}

/// A resource record; [data] depends on [type].
@internal
@immutable
final class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    required this.cacheFlush,
    required this.data,
  });

  /// The owner name, without the trailing dot.
  final String name;

  /// The record type.
  final int type;

  /// Seconds to keep it; 0 is a goodbye (RFC 6762 10.1).
  final int ttl;

  /// The cache-flush bit: this record replaces older ones of its set.
  final bool cacheFlush;

  /// The record's content.
  final DnsData data;

  /// The same record with [ttl] seconds to live.
  DnsRecord withTtl(int ttl) => DnsRecord(name: name, type: type, ttl: ttl, cacheFlush: cacheFlush, data: data);

  @override
  String toString() => 'DnsRecord($name type $type ttl $ttl: $data)';
}

/// What a record holds.
@internal
@immutable
sealed class DnsData {
  const DnsData();

  /// Tells records of one set apart: names compare without case.
  String get key;
}

/// PTR data: the name pointed at, without the trailing dot.
@internal
final class DnsPointer extends DnsData {
  const DnsPointer(this.target);

  final String target;

  @override
  String get key => target.toLowerCase();

  @override
  String toString() => target;
}

/// SRV data.
@internal
final class DnsSrv extends DnsData {
  const DnsSrv({required this.priority, required this.weight, required this.port, required this.target});

  final int priority;
  final int weight;
  final int port;

  /// The host name, without the trailing dot.
  final String target;

  @override
  String get key => '${target.toLowerCase()}:$port';

  @override
  String toString() => '$target:$port';
}

/// TXT data: its strings, empty ones left out.
@internal
final class DnsText extends DnsData {
  const DnsText(this.strings);

  final List<String> strings;

  @override
  String get key => strings.join('\u0000');

  @override
  String toString() => strings.join(' ');
}

/// A or AAAA data.
@internal
final class DnsAddress extends DnsData {
  const DnsAddress(this.address);

  final InternetAddress address;

  @override
  String get key => address.address;

  @override
  String toString() => address.address;
}

/// Data of any other type, as it came.
@internal
final class DnsRaw extends DnsData {
  const DnsRaw(this.bytes);

  final Uint8List bytes;

  @override
  String get key => bytes.join(',');
}

/// A decoded message.
@internal
final class DnsMessage {
  DnsMessage({required this.id, required this.isResponse, this.questions = const [], this.answers = const []});

  /// Reads a message. Throws [FormatException] when it is malformed.
  factory DnsMessage.decode(Uint8List bytes) => _Reader(bytes).message();

  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;

  /// Answers, authority and additional records together (mDNS treats the additional ones as answers too).
  final List<DnsRecord> answers;

  /// A query for [questions] (mDNS: id 0, no flags).
  static Uint8List query(List<DnsQuestion> questions, {int id = 0}) {
    final out = BytesBuilder();
    final header = ByteData(12)
      ..setUint16(0, id)
      ..setUint16(4, questions.length);
    out.add(header.buffer.asUint8List());
    for (final q in questions) {
      out
        ..add(encodeName(q.name))
        ..add(
          (ByteData(4)
                ..setUint16(0, q.type)
                ..setUint16(2, (q.unicastResponse ? 0x8000 : 0) | 1))
              .buffer
              .asUint8List(),
        );
    }
    return out.takeBytes();
  }

  /// [name] as DNS labels (no compression).
  static Uint8List encodeName(String name) {
    final out = BytesBuilder();
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      final bytes = utf8.encode(label);
      if (bytes.length > 63) throw ArgumentError.value(name, 'name', 'has a label over 63 bytes');
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    out.addByte(0);
    return out.takeBytes();
  }
}

final class _Reader {
  _Reader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  DnsMessage message() {
    _need(12);
    final id = _view.getUint16(0);
    final flags = _view.getUint16(2);
    final counts = [for (var i = 0; i < 4; i++) _view.getUint16(4 + 2 * i)];
    _offset = 12;
    final questions = <DnsQuestion>[];
    for (var i = 0; i < counts[0]; i++) {
      final name = _name();
      _need(4);
      final type = _view.getUint16(_offset);
      final klass = _view.getUint16(_offset + 2);
      _offset += 4;
      questions.add(DnsQuestion(name, type, unicastResponse: klass & 0x8000 != 0));
    }
    final records = <DnsRecord>[];
    for (var i = 0; i < counts[1] + counts[2] + counts[3]; i++) {
      final record = _record();
      if (record != null) records.add(record);
    }
    return DnsMessage(id: id, isResponse: flags & 0x8000 != 0, questions: questions, answers: records);
  }

  /// A record, or null for classes other than IN.
  DnsRecord? _record() {
    final name = _name();
    _need(10);
    final type = _view.getUint16(_offset);
    final klass = _view.getUint16(_offset + 2);
    final ttl = _view.getUint32(_offset + 4);
    final length = _view.getUint16(_offset + 8);
    _offset += 10;
    _need(length);
    final end = _offset + length;
    final DnsData data;
    switch (type) {
      case DnsType.ptr:
        data = DnsPointer(_name());
      case DnsType.srv:
        _need(6);
        final priority = _view.getUint16(_offset);
        final weight = _view.getUint16(_offset + 2);
        final port = _view.getUint16(_offset + 4);
        _offset += 6;
        data = DnsSrv(priority: priority, weight: weight, port: port, target: _name());
      case DnsType.txt:
        data = DnsText(_strings(end));
      case DnsType.a when length == 4:
        data = DnsAddress(InternetAddress.fromRawAddress(_bytes.sublist(_offset, end), type: InternetAddressType.IPv4));
      case DnsType.aaaa when length == 16:
        data = DnsAddress(InternetAddress.fromRawAddress(_bytes.sublist(_offset, end), type: InternetAddressType.IPv6));
      case DnsType.a || DnsType.aaaa:
        // An address of the wrong size: skipped, never stored as one.
        _offset = end;
        return null;
      default:
        data = DnsRaw(Uint8List.fromList(_bytes.sublist(_offset, end)));
    }
    if (_offset > end) throw const FormatException('A record overruns');
    _offset = end;
    if (klass & 0x7fff != 1) return null;
    return DnsRecord(name: name, type: type, ttl: ttl, cacheFlush: klass & 0x8000 != 0, data: data);
  }

  /// TXT character-strings up to [end].
  List<String> _strings(int end) {
    final strings = <String>[];
    while (_offset < end) {
      final n = _bytes[_offset++];
      if (_offset + n > end) throw const FormatException('A bad TXT');
      if (n > 0) strings.add(utf8.decode(_bytes.sublist(_offset, _offset + n), allowMalformed: true));
      _offset += n;
    }
    return strings;
  }

  /// A name, following compression pointers (at most 64 of them).
  String _name() {
    final labels = <String>[];
    var offset = _offset;
    int? resume;
    var jumps = 0;
    while (true) {
      if (offset >= _bytes.length) throw const FormatException('A cut name');
      final length = _bytes[offset];
      if (length == 0) {
        offset++;
        break;
      }
      if (length & 0xc0 == 0xc0) {
        if (offset + 1 >= _bytes.length) throw const FormatException('A cut pointer');
        resume ??= offset + 2;
        offset = ((length & 0x3f) << 8) | _bytes[offset + 1];
        if (++jumps > 64) throw const FormatException('A pointer loop');
        continue;
      }
      if (length & 0xc0 != 0) throw const FormatException('A bad label');
      if (offset + 1 + length > _bytes.length) throw const FormatException('A cut label');
      labels.add(utf8.decode(_bytes.sublist(offset + 1, offset + 1 + length), allowMalformed: true));
      offset += 1 + length;
    }
    _offset = resume ?? offset;
    return labels.join('.');
  }

  void _need(int n) {
    if (_offset + n > _bytes.length) throw const FormatException('A truncated DNS message');
  }
}
