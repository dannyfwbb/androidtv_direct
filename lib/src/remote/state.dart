// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';

import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:meta/meta.dart';

/// What the TV says about itself when a session starts.
@immutable
final class TvDevice {
  /// Creates the description.
  const TvDevice({this.vendor, this.model, this.androidRelease, this.serviceVersion});

  /// Reads it from the TV's setup message.
  factory TvDevice.fromInfo(DeviceInfo? info) => TvDevice(
    vendor: info?.vendor,
    model: info?.model,
    androidRelease: info?.androidRelease,
    serviceVersion: info?.serviceVersion,
  );

  /// The maker, such as `Google`.
  final String? vendor;

  /// The model, such as `SHIELD Android TV`.
  final String? model;

  /// The Android version, such as `14`.
  final String? androidRelease;

  /// The version of the TV's remote service, such as `7.00.999235495`.
  final String? serviceVersion;

  @override
  String toString() => 'TvDevice($vendor $model, Android $androidRelease, service $serviceVersion)';
}

/// The TV's volume.
@immutable
final class TvVolume {
  /// Creates the value.
  const TvVolume({required this.level, required this.maximum, required this.muted});

  /// The level, from 0 to [maximum].
  final int level;

  /// The highest level.
  final int maximum;

  /// Whether the sound is muted.
  final bool muted;

  @override
  bool operator ==(Object other) =>
      other is TvVolume && other.level == level && other.maximum == maximum && other.muted == muted;

  @override
  int get hashCode => Object.hash(level, maximum, muted);

  @override
  String toString() => 'TvVolume($level/$maximum${muted ? ', muted' : ''})';
}

/// The latest of everything the TV reported in a session. Fields the TV has not reported (or that the session did
/// not ask for) are `null`.
@immutable
final class TvState {
  /// Creates the state.
  const TvState({this.power, this.volume, this.app});

  /// Whether the TV is on.
  final bool? power;

  /// The volume.
  final TvVolume? volume;

  /// The package of the app in front, such as `com.google.android.youtube.tv`. TVs seen so far (remote service 7.00)
  /// report it only to sessions with `TvFeature.ime`.
  final String? app;

  /// This state with [message]'s report applied, or this same object if it changes nothing.
  ///
  /// A volume report missing some fields keeps the previous values of those; until the TV has reported a level and a
  /// maximum, [volume] stays `null`. A maximum below zero is taken as zero and a level outside the range as its
  /// nearest end, so [TvVolume] always holds a level from 0 to its maximum.
  TvState apply(RemoteEnvelope message) => switch (message) {
    PowerReport(:final on) => _with(power: on),
    VolumeReport() => _with(volume: _volumeAfter(message)),
    FocusReport(app: FocusedApp(:final packageName?)) => _with(app: packageName),
    _ => this,
  };

  /// This state with the given fields replaced, or this same object if nothing changes.
  TvState _with({bool? power, TvVolume? volume, String? app}) {
    final next = TvState(power: power ?? this.power, volume: volume ?? this.volume, app: app ?? this.app);
    return next == this ? this : next;
  }

  TvVolume? _volumeAfter(VolumeReport report) {
    final level = report.level ?? volume?.level;
    final reported = report.maximum ?? volume?.maximum;
    if (level == null || reported == null) return null;
    final maximum = max(reported, 0);
    final muted = report.muteState != null ? report.muted : (volume?.muted ?? false);
    return TvVolume(level: level.clamp(0, maximum), maximum: maximum, muted: muted);
  }

  @override
  bool operator ==(Object other) =>
      other is TvState && other.power == power && other.volume == volume && other.app == app;

  @override
  int get hashCode => Object.hash(power, volume, app);

  @override
  String toString() => 'TvState(power: $power, volume: $volume, app: $app)';
}
