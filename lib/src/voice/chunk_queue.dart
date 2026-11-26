// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

/// Bytes cut into chunks of [chunkBytes] as they are added.
final class ChunkQueue {
  /// A queue of [chunkBytes]-byte chunks.
  ChunkQueue(this.chunkBytes);

  /// The size of a chunk.
  final int chunkBytes;

  final Queue<Uint8List> _whole = Queue();
  final BytesBuilder _partial = BytesBuilder();

  /// Bytes waiting, whole chunks and the partial one.
  int get length => _whole.length * chunkBytes + _partial.length;

  /// Whether a whole chunk is waiting.
  bool get hasChunk => _whole.isNotEmpty;

  /// Adds [bytes].
  void add(List<int> bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      final take = min(chunkBytes - _partial.length, bytes.length - offset);
      _partial.add(bytes.getRange(offset, offset + take).toList());
      offset += take;
      if (_partial.length == chunkBytes) _whole.add(_partial.takeBytes());
    }
  }

  /// Pads the partial chunk, if any, to a whole one with zeros.
  void padLast() {
    if (_partial.isEmpty) return;
    _partial.add(Uint8List(chunkBytes - _partial.length));
    _whole.add(_partial.takeBytes());
  }

  /// The next whole chunk.
  Uint8List take() => _whole.removeFirst();

  /// Drops everything.
  void clear() {
    _whole.clear();
    _partial.clear();
  }
}
