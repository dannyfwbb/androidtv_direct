# Examples

| Example | What it does | Run |
| --- | --- | --- |
| [androidtv_direct_example.dart](androidtv_direct_example.dart) | Pairs once (the code the TV shows is typed in), then connects, prints the TV and its state, presses volume up and down | `dart run example/androidtv_direct_example.dart <host>` |
| [remote.dart](remote.dart) | A remote control in the terminal: arrows, Enter, Back, Home, volume, mute, power, typing into the focused field, links | `dart run example/remote.dart <host>` |
| [text.dart](text.dart) | Puts a text into the TV's focused field and prints what is typed on the TV | `dart run example/text.dart <host> <text>` |
| [voice.dart](voice.dart) | Sends a WAV recording (16-bit PCM, mono, 8 kHz) to the TV's voice search | `dart run example/voice.dart <host> <speech.wav>` |
| [discover.dart](discover.dart) | Lists TVs announcing their remote service, and optionally scans a /24 subnet; nothing appears on the TVs | `dart run example/discover.dart [192.168.0]` |
| [platform_browser.dart](platform_browser.dart) | Plugging a platform's service browser (iOS `NWBrowser`, Android NSD) into discovery | `dart run example/platform_browser.dart` |

The first example keeps the client's identity in `identity.pem` and the TV's fingerprint in `tv-<host>.fingerprint`, in the working directory; the remote, text and voice examples connect with them ([paired.dart](paired.dart)). Every pairing adds a client on the TV.
