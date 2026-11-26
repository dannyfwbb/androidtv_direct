// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:androidtv_direct/src/errors.dart';

/// Runs [body]. When [cancelOn] completes before [body] does, [abort] runs (it should make [body] fail soon, for
/// example by closing its socket), and [body]'s failure is reported as [TvCancelledException]. Once [body] has
/// finished, [cancelOn] has no effect.
Future<T> cancellable<T>(
  Future<void>? cancelOn, {
  required String what,
  required Future<void> Function() abort,
  required Future<T> Function() body,
}) async {
  var finished = false;
  var cancelled = false;
  cancelOn?.whenComplete(() {
    if (finished) return;
    cancelled = true;
    unawaited(abort());
  }).ignore();
  try {
    return await body();
  } on TvRemoteException catch (e) {
    if (cancelled && e is! TvCancelledException) throw TvCancelledException('$what was cancelled', cause: e);
    rethrow;
  } finally {
    finished = true;
  }
}
