# Keys, power and volume

A session with `TvFeature.key` (in the defaults) sends Android key events, as the TV's own remote does.

```dart
remote.press(TvKey.dpadDown);          // press and release
final hold = remote.hold(TvKey.dpadDown);
await Future<void>.delayed(const Duration(seconds: 1));
hold.release();                        // the TV repeated the key meanwhile
remote.sendKeyCode(338);               // a code newer than the table
```

## The key table

`TvKey` has every key code in AOSP's `keycodes.h` (Android 16: codes 0 to 337), named after AOSP's `AKEYCODE_…` names in lowerCamelCase: `dpadUp`, `dpadCenter`, `back`, `home`, `volumeUp`, `volumeMute`, `mediaPlayPause`, `channelUp`, `tvInputHdmi1`, `search`, `settings`, `guide`, `allApps`, `f1`…`f24`. A few names follow fixed rules because AOSP's are not Dart names: `digit0`…`digit9` for the number keys, `key11` and `key12` for 11 and 12, `mode3d`, `breakKey`, `newKey`. `TvKey.fromCode(int)` finds a key by code.

Common remote keys:

| Button | `TvKey` |
| --- | --- |
| Arrows, OK | `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight`, `dpadCenter` |
| Back, Home | `back`, `home` |
| Volume | `volumeUp`, `volumeDown`, `volumeMute` |
| Power | `power` (toggles) |
| Playback | `mediaPlayPause`, `mediaPlay`, `mediaPause`, `mediaStop`, `mediaRewind`, `mediaFastForward`, `mediaNext`, `mediaPrevious` |
| Channels, guide | `channelUp`, `channelDown`, `guide` |
| Inputs | `tvInput`, `tvInputHdmi1`…`tvInputHdmi4` |
| Settings, apps | `settings`, `allApps` |
| Search (voice) | `search` |
| Numbers | `digit0`…`digit9` |

## Sending keys

- `press(key)` sends one press (down and up together).
- `hold(key)` sends key down and returns a `TvKeyHold`; the TV repeats the key, as for a held button, until `release()`. Closing the session releases every held key first, so a key is never left down.
- `sendKeyCode(code, action:)` sends any code from 1 to 999 with a `TvKeyAction` (`down`, `up`, `press`), for keys newer than the table; `holdCode(code)` holds one as `hold` does. A key sent `down` with `sendKeyCode` is the caller's to send `up`. `TvKey.unknown` (code 0) is not a key and is refused with `RangeError`.
- On the Android TV emulator (remote service 7.00), codes the TV does not know were ignored: nothing came back for them.
- Without `TvFeature.key` in the session, these throw `TvNotSupportedException` before sending.

## Power

`remote.state.power` is the TV's power state, reported at the start and on every change; `remote.changes` tells when it changes. `press(TvKey.power)` toggles it. `sleep` and `wakeup` did nothing on the Android TV emulator; whether they work depends on the TV. A TV that is off often stays on the network and keeps the session; one in deep standby may drop off it (then the session ends with a timeout).

## Volume

`remote.state.volume` is a `TvVolume` with `level`, `maximum` and `muted`. The volume keys change it, and the TV reports the new level within milliseconds.

`await remote.setVolume(12)` brings the level to 12 with volume keys, one at a time, waiting for the TV's report after each: the emulator ignored a level sent directly. Mute is left as it is. A newer `setVolume` takes over from one still running, which then throws `TvCancelledException`. It needs `TvFeature.key` and `TvFeature.volume` and a volume report from the TV, takes a level from 0 to `maximum`, and fails with `TvTimeoutException` when a report does not come within `stepTimeout` (2 s) or the level is not reached within `timeout` (15 s). On a TV whose volume is handled by a sound bar over HDMI-CEC, the reports may describe the sound bar.
