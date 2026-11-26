// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// What a remote session can do. The client asks for a set; the TV grants what it offers of it.
enum TvFeature {
  /// Key presses.
  key(2),

  /// Text input: the focused field's reports and text edits, and the reports of the app in front (`TvState.app`), which
  /// TVs seen so far (remote service 7.00) send only with this feature. Some TVs show a notice ("use the keyboard on
  /// your phone") while a client has it, so it is not in [defaults].
  ime(4),

  /// Voice sessions.
  voice(8),

  /// Power reports.
  power(32),

  /// Volume reports.
  volume(64),

  /// Opening app links.
  appLink(512);

  const TvFeature(this.bit);

  /// Its bit in the protocol's feature mask.
  final int bit;

  /// What a session asks for unless told otherwise: everything but text input and voice.
  static const Set<TvFeature> defaults = {key, power, volume, appLink};

  /// The protocol's bit for pings, which every session asks for.
  static const int pingBit = 1;

  /// The mask a client sends for [features], pings included.
  static int maskOf(Iterable<TvFeature> features) => features.fold(pingBit, (mask, f) => mask | f.bit);

  /// The features whose bits are set in [mask].
  static Set<TvFeature> fromMask(int mask) => {
    for (final feature in values)
      if (mask & feature.bit != 0) feature,
  };
}
