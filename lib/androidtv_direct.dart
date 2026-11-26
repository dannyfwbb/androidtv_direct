// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A remote control for Android TV and Google TV devices in pure Dart, over the TV's own remote protocol.
///
/// In development: this version pairs with TVs, reads what their certificates say and holds remote sessions with their
/// state, keys, power, volume, links, text input, voice and discovery.
library;

export 'src/clock.dart' show TvClock, TvClockWaits;
export 'src/discovery/mdns_browser.dart' show TvMdnsBrowser;
export 'src/discovery/tv_service.dart'
    show
        TvProtocol,
        TvService,
        TvServiceBrowser,
        TvServiceEvent,
        TvServiceFound,
        TvServiceLost,
        TvServiceType,
        TvServiceUpdated;
export 'src/errors.dart';
export 'src/identity/client_identity.dart' show TvClientIdentity;
export 'src/identity/tv_identity.dart' show TvIdentity;
export 'src/pairing/pairing.dart' show TvPairing, TvPairingResult;
export 'src/probe/probe.dart' show TvProbe;
export 'src/probe/scan.dart' show TvScanResult;
export 'src/protocol/key_codes.dart' show TvKey;
export 'src/remote/features.dart' show TvFeature;
export 'src/remote/keys.dart' show TvKeyAction, TvKeyHold;
export 'src/remote/remote.dart' show TvRawMessage, TvRemote;
export 'src/remote/state.dart' show TvDevice, TvState, TvVolume;
export 'src/text/field_kind.dart' show TvFieldAction, TvTextFieldKind;
export 'src/text/text_field.dart' show TvSelection, TvTextField;
export 'src/trace.dart';
export 'src/voice/voice.dart' show TvVoiceSession;
