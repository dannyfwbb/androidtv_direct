# Compatibility

## Which TVs

TVs and streaming boxes running Android TV or Google TV with Google's **Android TV Remote Service**, version 5 or later. The service comes pre-installed on most such devices and updates itself from the Play Store. To check a TV: Settings → Apps → See all apps → Show system apps → Android TV Remote Service; the version is on its page.

Not supported:

- Devices without Google's services (plain AOSP boxes, most Fire TV devices): they have no remote service. Connecting fails with `noService`.
- TVs whose remote service is older than version 5: they speak an older protocol. Discovery reports them, and the app can ask the user to update the service.

## Checked so far

| Device | Remote service | Result |
| --- | --- | --- |
| Google TV emulator, Android 14 | 5.99, 7.00 | Prototype: pairing, session, keys, volume, links, pings. The messages recorded from both versions (pairing, session start, volume, app reports) are byte for byte the same apart from the version string |

Real TVs will be listed here as they are tried.

## Known differences between TVs

- **Text fields**: most fields insert what the client sends at the cursor; some apps' fields replace their content with each edit. The package works from the content the TV reports, so both reach the requested text.
- **Text edit revisions**: some TVs accept edits only with the revisions from the field's focus report. The package always uses those.
- **Voice**: message sizes that work differ between TVs; the package uses a size reported to work widely (20 480 bytes).
- **Sleep and Wake keys** do nothing on some devices; the power key toggles.
- **Older TVs (Android 9)**: some reject TLS connections from some clients where Google's own remote app works. Whether this package is affected is not known yet.
- **The TV's certificate** usually contains the TV's network (MAC) address; some TVs leave it out.

## Platforms

The package uses only `dart:io`. It is being developed and tested on Linux; Android, iOS, macOS and Windows use the same TLS library underneath (BoringSSL) and will be checked before 1.0.
