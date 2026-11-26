// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/identity/tv_identity.dart';
import 'package:meta/meta.dart';

/// A TV a scan found.
@immutable
final class TvScanResult {
  /// Creates one.
  const TvScanResult(this.host, this.tv);

  /// The host tried.
  final Object host;

  /// What its certificate says.
  final TvIdentity tv;

  @override
  String toString() => 'TvScanResult($host, $tv)';
}

/// Probes [host], giving up when [cancelOn] completes.
typedef Identify = Future<TvIdentity> Function(Object host, Future<void> cancelOn);

/// Runs [identify] on every host of [hosts], at most [concurrency] at a time, and emits the ones that answer as a
/// TV's remote service, in the order they answer. Pausing the subscription stops new probes; cancelling stops the
/// running ones too. An error from [hosts] itself is reported and ends the scan.
Stream<TvScanResult> scanHosts(Iterable<Object> hosts, {required int concurrency, required Identify identify}) {
  if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  return _Scan(hosts.iterator, concurrency, identify).results;
}

final class _Scan {
  _Scan(this._pending, this._concurrency, this._identify) {
    _controller = StreamController(onListen: _next, onResume: _next, onCancel: _cancel.complete);
  }

  final Iterator<Object> _pending;
  final int _concurrency;
  final Identify _identify;
  final Completer<void> _cancel = Completer();
  late final StreamController<TvScanResult> _controller;
  int _running = 0;
  bool _exhausted = false;

  bool get _cancelled => _cancel.isCompleted;

  Stream<TvScanResult> get results => _controller.stream;

  /// Starts probes until [_concurrency] run, unless paused, cancelled or out of hosts; closes once all are done.
  void _next() {
    while (_mayStartAnother && _take()) {
      _running++;
      unawaited(_probe(_pending.current));
    }
    if (_allDone) unawaited(_controller.close());
  }

  bool get _active => !_cancelled && !_controller.isClosed;

  bool get _mayStartAnother => _active && !_controller.isPaused && !_exhausted && _running < _concurrency;

  bool get _allDone => _active && _exhausted && _running == 0;

  bool _take() {
    try {
      if (_pending.moveNext()) return true;
    } on Object catch (e, s) {
      _controller.addError(e, s);
    }
    _exhausted = true;
    return false;
  }

  Future<void> _probe(Object host) async {
    TvIdentity? tv;
    try {
      tv = await _identify(host, _cancel.future);
    } on Object {
      // Nothing there, something else there, or a bad host (an ArgumentError): not a result, and never one that
      // leaves the scan waiting for this probe.
    }
    _running--;
    if (_cancelled) return;
    if (tv != null && tv.isRemoteService) _controller.add(TvScanResult(host, tv));
    _next();
  }
}
