# androidtv_direct

[![pub package](https://img.shields.io/pub/v/androidtv_direct.svg)](https://pub.dev/packages/androidtv_direct) [![pub points](https://img.shields.io/pub/points/androidtv_direct)](https://pub.dev/packages/androidtv_direct/score) [![CI](https://github.com/dannyfwbb/androidtv_direct/actions/workflows/ci.yml/badge.svg)](https://github.com/dannyfwbb/androidtv_direct/actions/workflows/ci.yml)

A remote control for Android TV and Google TV devices in pure Dart. It speaks the TV's own remote protocol (the one Google's TV remote apps use) directly: no app on the TV, no developer options, no ADB, no platform channels, no native code. One `dart:io` implementation for Android, iOS, macOS, Windows and Linux.

Tested against a fake TV with recorded byte exchanges, on the Android TV emulator and on a Philips Android TV ([doc/compatibility.md](doc/compatibility.md) lists what was checked where). [doc/scope.md](doc/scope.md) shows every area the package covers.

```
dart pub add androidtv_direct
```

```dart
import 'package:androidtv_direct/androidtv_direct.dart';

// Once per installation: the client's key and certificate. Store toPem() safely.
final me = await TvClientIdentity.generate(now: DateTime.now());

// Once per TV: the TV shows six characters, the user types them in.
final pairing = await TvPairing.start('192.168.1.30', identity: me, clientName: 'My Remote');
final paired = await pairing.finish(await askUserForCode());
// Keep paired.fingerprint: it identifies this TV from now on.

// Every time: connect and control.
final remote = await TvRemote.connect(
  '192.168.1.30',
  identity: me,
  fingerprint: paired.fingerprint,
  features: {...TvFeature.defaults, TvFeature.ime},   // ime: the TV's text field
);
print('${remote.device.vendor} ${remote.device.model}, on: ${remote.state.power}');

remote.press(TvKey.dpadDown);
remote.press(TvKey.volumeUp);
await remote.textField?.setText('nature documentaries');
remote.openLink('https://www.youtube.com');

await remote.close();
```

## What it does

Everything the TV's remote protocol offers:

- **Pairing** with the six-character code the TV shows; a mistyped code is caught before anything is sent, and the attempt stays open for another try.
- **Keys**: every Android key code (D-pad, Home, Back, media, channels, inputs, numbers, function keys…), as a short press or held down with the TV's own auto-repeat.
- **Power and volume**: the TV's power state and volume (level, maximum, muted) as they change; power and volume keys.
- **Text**: the text field that has the focus on the TV, as state: its content, cursor and kind (password, search…), `setText` that brings the TV's field to the given text, also with emoji and any script, and the field's action key (Search, Done…).
- **App links**: open a deep link or a store page on the TV.
- **Voice**: stream 16-bit PCM audio from the app's microphone to the TV's voice search.
- **Discovery**: an mDNS browser for TVs that announce the remote service, a hook for platform browsers, and recognition of TVs whose remote service is too old.
- **Device identity**: model and network address details from the TV's certificate, before pairing, without anything appearing on the TV; a helper to scan addresses the app chooses.

And what a library needs beyond that: the TV's key checked on every connection against the one stored at pairing (a required argument), so typed text cannot go to another device that took the TV's address; one sealed exception type with stable codes; deadlines on every step; detection of TVs that went away without closing the connection; no files, no global state; tracing that never logs typed text unless asked to.

## Platforms

Android, iOS, macOS, Windows and Linux: everything with `dart:io`, from Dart or Flutter. Not the web, where browsers open no raw TLS sockets.

- **Android** apps need the `INTERNET` permission; mDNS discovery also needs a multicast lock held by the app.
- **iOS** apps need the Local Network permission (`NSLocalNetworkUsageDescription`) and must list `_androidtvremote2._tcp` (and `_androidtvremote._tcp`, to recognise TVs with an outdated service) under `NSBonjourServices` to browse. Browsing mDNS from Dart needs Apple's multicast entitlement; without it, browse with the platform's browser and pass the results in.
- TVs need Google's Android TV Remote Service, which comes with most Android TV and Google TV devices. TVs without Google's services (and Fire TV devices) do not have it.

## Documentation

- [doc/README.md](doc/README.md): scope, protocol notes, errors, security model, compatibility.
- Every public class and member is documented in the API reference.
- [example/](example/): pairing, a remote control in the terminal, text, voice from a WAV file, discovery, a platform browser adapter.

## Versioning

The package will follow [semantic versioning](https://semver.org). Within a major version, public names and behaviour stay compatible, and no exception subclass or error code is added, so an exhaustive `switch` over them keeps compiling.

## Trademarks

Android, Android TV and Google TV are trademarks of Google LLC. This package is not affiliated with, endorsed by or sponsored by Google; the names only say which devices it works with.

## Security

Report vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE); the authors are listed in [AUTHORS](AUTHORS). The pairing follows the pairing protocol Google published in the Android Open Source Project, and the key table comes from AOSP's key codes; both are credited in [NOTICE](NOTICE).
