// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:androidtv_direct/src/protocol/varint.dart';
import 'package:meta/meta.dart';

/// The largest frame accepted by default: far above the largest message (a 20 KiB voice chunk).
const int defaultMaxFrameLength = 1 << 20;

/// [body] after its length as a varint: one message as it goes on the wire.
Uint8List encodeFrame(List<int> body) {
  final out = BytesBuilder(copy: false);
  writeVarint(out, body.length);
  out.add(body);
  return out.takeBytes();
}

/// Splits a byte stream into frames, whatever the chunks' boundaries.
///
/// Bytes are taken from a chunk only as far as the current frame needs them, and a frame's length is checked as soon
/// as it is read, so the reader never holds more than one frame of at most [maxFrameLength] bytes plus its prefix.
/// A longer frame is a [FormatException]; after that the reader is unusable.
final class FrameReader {
  /// Creates a reader that accepts frames up to [maxFrameLength] bytes.
  FrameReader({this.maxFrameLength = defaultMaxFrameLength}) {
    if (maxFrameLength < 0) throw ArgumentError.value(maxFrameLength, 'maxFrameLength', 'must not be negative');
  }

  /// The largest frame body accepted.
  final int maxFrameLength;

  Uint8List _buffer = Uint8List(64);
  int _length = 0;

  /// Bytes received that do not make a whole frame yet.
  int get pendingLength => _length;

  /// How many bytes the reader has allocated for pending bytes.
  @visibleForTesting
  int get capacity => _buffer.length;

  /// Adds [chunk] and returns the frames it completes, in order. Each frame is a fresh copy.
  List<Uint8List> add(List<int> chunk) {
    final frames = <Uint8List>[];
    var offset = 0;
    while (true) {
      final frame = _takeFrame();
      if (frame != null) {
        frames.add(frame);
      } else if (offset < chunk.length) {
        final take = min(chunk.length - offset, _wanted());
        _append(chunk, offset, take);
        offset += take;
      } else {
        return frames;
      }
    }
  }

  /// How many more bytes the incomplete pending frame needs: up to a whole length prefix, then the rest of the body.
  int _wanted() {
    final header = _header();
    if (header == null) return maxVarintLength - _length;
    return header.length + header.value - _length;
  }

  /// The pending frame's length prefix, or `null` while it is incomplete.
  VarintRead? _header() {
    final header = tryReadVarint(_buffer, 0, _length);
    if (header == null) {
      if (_length >= maxVarintLength) throw const FormatException('Frame length longer than ten bytes');
      return null;
    }
    if (header.value < 0 || header.value > maxFrameLength) {
      throw FormatException('Frame of ${header.value} bytes is over the limit of $maxFrameLength');
    }
    return header;
  }

  /// The pending frame if it is complete; whatever follows it stays pending.
  Uint8List? _takeFrame() {
    final header = _header();
    if (header == null) return null;
    final end = header.length + header.value;
    if (_length < end) return null;
    final frame = Uint8List.fromList(Uint8List.sublistView(_buffer, header.length, end));
    _buffer.setRange(0, _length - end, _buffer, end);
    _length -= end;
    return frame;
  }

  void _append(List<int> chunk, int offset, int count) {
    if (_buffer.length - _length < count) {
      _buffer = Uint8List(max(_buffer.length * 2, _length + count))..setRange(0, _length, _buffer);
    }
    _buffer.setRange(_length, _length + count, chunk, offset);
    _length += count;
  }
}
