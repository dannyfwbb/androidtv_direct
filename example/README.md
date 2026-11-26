# Examples

| Example | What it does | Run |
| --- | --- | --- |
| [androidtv_direct_example.dart](androidtv_direct_example.dart) | Pairs once (the code the TV shows is typed in), then connects, prints the TV and its state, presses volume up and down | `dart run example/androidtv_direct_example.dart <host>` |
| [discover.dart](discover.dart) | Lists TVs announcing their remote service, and optionally scans a /24 subnet; nothing appears on the TVs | `dart run example/discover.dart [192.168.0]` |
| [voice.dart](voice.dart) | Sends a raw 8 kHz recording to the TV's voice search | `dart run example/voice.dart <host> <audio.raw>` |
| [platform_browser.dart](platform_browser.dart) | Plugging a platform's service browser (iOS `NWBrowser`, Android NSD) into discovery | `dart run example/platform_browser.dart` |

The first example keeps the client's identity in `identity.pem` and the TV's fingerprint in `tv-<host>.fingerprint`, in the working directory; `voice.dart` uses them. Every pairing adds a client on the TV.
