// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:meta/meta.dart';

/// The operating system a [TvClientInfo] names, with its number on the wire.
enum TvClientOs {
  /// Not said.
  unspecified(0),

  /// Android.
  android(1),

  /// iOS.
  ios(2);

  const TvClientOs(this.code);

  /// The number the TV knows it by.
  final int code;
}

/// What the client tells the TV about itself when a session starts.
///
/// The TV writes it to its log with each connection; it was not seen on screen or used for anything else. Every field
/// is optional, and the defaults are what clients of the protocol commonly send ([TvClientInfo.standard]): change them
/// to tell the TV's log which app and device connected.
@immutable
final class TvClientInfo {
  /// Creates the description.
  const TvClientInfo({
    this.model,
    this.vendor,
    this.os = TvClientOs.android,
    this.osVersion = '1',
    this.appId = 'atvremote',
    this.appVersion = '1.0.0',
  });

  /// What clients of the protocol commonly send.
  static const TvClientInfo standard = TvClientInfo();

  /// The device's model, such as `Pixel 9`.
  final String? model;

  /// The device's maker, such as `Google`.
  final String? vendor;

  /// The device's operating system.
  final TvClientOs os;

  /// The operating system's version, such as `15`.
  final String? osVersion;

  /// The app's package name or bundle id.
  final String? appId;

  /// The app's version.
  final String? appVersion;

  /// The setup message's device field.
  @internal
  DeviceInfo toMessage() => DeviceInfo(
    model: model,
    vendor: vendor,
    os: os.code,
    androidRelease: osVersion,
    packageName: appId,
    serviceVersion: appVersion,
  );

  @override
  bool operator ==(Object other) =>
      other is TvClientInfo &&
      other.model == model &&
      other.vendor == vendor &&
      other.os == os &&
      other.osVersion == osVersion &&
      other.appId == appId &&
      other.appVersion == appVersion;

  @override
  int get hashCode => Object.hash(model, vendor, os, osVersion, appId, appVersion);

  @override
  String toString() => 'TvClientInfo(${[vendor, model, os.name, osVersion, appId, appVersion].nonNulls.join(' ')})';
}
