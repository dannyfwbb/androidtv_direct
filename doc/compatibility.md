# Compatibility

## Which TVs

TVs and streaming boxes running Android TV or Google TV with Google's **Android TV Remote Service**, version 5 or later. The service comes pre-installed on most such devices and updates itself from the Play Store. To check a TV: Settings → Apps → See all apps → Show system apps → Android TV Remote Service; the version is on its page.

Not supported:

- Devices without Google's services (plain AOSP boxes, most Fire TV devices): they have no remote service. Connecting fails with `noService`.
- TVs whose remote service is older than version 5: they speak an older protocol. Discovery reports them, and the app can ask the user to update the service.

## Checked so far

| Device | Remote service | Result |
| --- | --- | --- |
| Google TV emulator, Android 14 | 5.99, 7.00 | Everything the package offers (pairing, session, keys, power, volume, links, text, voice), on 7.00. The messages recorded from both versions are byte for byte the same apart from the version string |
| Philips UHD Android TV (2021/22 range), Android 11 | 7.00 | Probe, pairing, a client it does not know refused as `notPaired` (TLS 1.3 on both ports), session, keys, power (the session stays up in standby, pings go on; the power key wakes it), volume (out of 60), app reports, links (a bare package name refused with code 7), text in an app's search field (any script, emoji, 80 characters), voice sessions (speech recognition itself not tried) |

## Known differences between TVs

- **Text fields**: most fields insert what the client sends at the cursor; some apps' fields replace their content with each edit. The package works from the content the TV reports, so both reach the requested text.
- **Text edit revisions**: some TVs accept edits only with the revisions from the field's focus report. The package always uses those.
- **Voice**: message sizes that work differ between TVs; the package uses a size reported to work widely (20 480 bytes).
- **Sleep and Wake keys** did nothing on the devices checked; the power key toggles.
- **Volume** is reported out of the TV's own maximum: 15 on the emulator, 60 on the Philips.
- **Wake-on-LAN** with the address from the certificate did not wake the Philips from standby (its setting for waking over Wi-Fi was not changed); the power key through a session did, as the remote service stays reachable in standby. The package offers no Wake-on-LAN helper.
- **Keys right after connecting**: the TV sets up a virtual input device for each session, which takes it tens of milliseconds; `connect` returns only after that (`inputSettle`), since a key sent earlier is lost.
- **Older TVs (Android 9)**: some reject TLS connections from some clients where Google's own remote app works. Whether this package is affected is not known yet.
- **The TV's certificate** usually contains the TV's network (MAC) address; some TVs leave it out.

## Platforms

The package uses only `dart:io`. It is being developed and tested on Linux; Android, iOS, macOS and Windows use the same TLS library underneath (BoringSSL) and will be checked before 1.0.
