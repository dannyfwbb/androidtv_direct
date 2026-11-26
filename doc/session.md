# The remote session

After pairing, the app controls the TV through a session on the remote port (6466). A session needs the client's identity and the TV's fingerprint from pairing.

```dart
final remote = await TvRemote.connect(
  '192.168.1.30',
  identity: me,
  fingerprint: storedFingerprint,   // from TvPairingResult.fingerprint
);
print('${remote.device.vendor} ${remote.device.model}: on ${remote.state.power}, volume ${remote.state.volume}');
remote.changes.listen((state) => print(state));
final reason = await remote.done;   // null after remote.close(), else why it ended
```

## Connecting

`TvRemote.connect` opens TLS with the client's certificate, checks the TV's key, answers the TV's setup and activation, and returns once the TV has reported its power state. Until then it may fail with:

| Exception | When |
| --- | --- |
| `TvUnreachableException` | The address does not answer, or has no route |
| `TvNoServiceException` | Nothing listens on the remote port |
| `TvWrongTvException` | The device at the address has another key than the paired TV. Checked inside the TLS handshake, which is aborted before the client's certificate goes out: no session message is sent to it. `expected` and `actual` carry both fingerprints |
| `TvNotPairedException` | The TV refused the client's certificate (a TLS alert, or a close before its first message): it never paired with this identity, forgot it, or paired another client whose certificate has the same name since ([identity.md](identity.md)) |
| `TvTimeoutException` | TLS not finished within `connectTimeout` (5 s), or no power report within `startTimeout` (10 s) |
| `TvClosedException`, `TvProtocolException` | The TV closed the connection, or sent something malformed |
| `TvCancelledException` | `cancelOn` completed before `connect` returned |

### The fingerprint is required

`fingerprint` has no default. Passing `null` is possible, but then the session goes to whatever device answers at the address: addresses on home networks change, and another device that got the TV's old address would receive everything the app sends, typed passwords included. Store the fingerprint from pairing and always pass it.

### Telling the TV who connects

The setup carries a description of the client: `client: TvClientInfo(...)` with the device's model and maker, its operating system (`TvClientOs.android`, `ios` or `unspecified`) and version, and the app's id and version. The TV writes it to its log with each connection and was not seen to show or use it otherwise. The default, `TvClientInfo.standard`, is what clients of the protocol commonly send (Android, version `1`, app `atvremote` `1.0.0`).

```dart
final remote = await TvRemote.connect(
  host,
  identity: identity,
  fingerprint: fingerprint,
  client: const TvClientInfo(
    model: 'iPhone',
    vendor: 'Apple',
    os: TvClientOs.ios,
    osVersion: '18.1',
    appId: 'com.example.remote',
    appVersion: '1.4.0',
  ),
);
```

## Features

The session asks for a set of `TvFeature`s and the TV grants what it offers of it; `remote.features` is the result.

| Feature | Gives | Default |
| --- | --- | --- |
| `key` | Key presses | yes |
| `power` | Power reports (always asked for: the session is ready when the TV reports its power state) | yes |
| `volume` | Volume reports | yes |
| `appLink` | Opening links | yes |
| `ime` | The focused text field and text edits, **and the app in front** (`state.app`): TVs seen so far (remote service 7.00) send app reports only to sessions with this feature | no |
| `voice` | Voice sessions | no |

`ime` is not in the defaults because some TVs show a notice ("use the keyboard on your phone") while a client has it. Ask for it when the app needs the text field or the app in front.

## State and changes

`remote.state` is a `TvState` holding the latest of what the TV reported: `power` (on or off), `volume` (`level`, `maximum`, `muted`) and `app` (the package in front, with `ime`). Fields the TV has not reported are `null`; the TV sends its volume report around its power report, before or just after `connect` returns. `remote.changes` streams every new state as it happens and closes when the session ends. `remote.device` is what the TV said about itself: `vendor`, `model`, `androidRelease`, `serviceVersion`.

## Staying alive

The TV pings the client every five seconds while the client is quiet; the session answers each ping at once. Nothing is sent on the package's own initiative. When no message goes either way for `idleTimeout` (16 s by default), the TV is taken to be gone (switched off at the wall, off the network, frozen): the session ends with `TvTimeoutException`. Counting both directions matters: a TV does not ping a client that keeps sending, so a busy session is never idle. The other side of that: an app that keeps sending to a TV that went away learns it only when its writes fail.

## Ending

- `remote.close()` ends the session; `done` completes with `null`. Closing twice does nothing.
- Otherwise `done` completes once with what ended it: `TvTimeoutException` (silence), `TvClosedException` (the TV closed the connection), `TvProtocolException`, or `TvLinkRefusedException`. The TV closes the session after refusing any message; the package ends it at once: a refused link as `TvLinkRefusedException` (see [protocol.md](protocol.md)), anything else as `TvProtocolException`.
- After the end, every call that sends throws the same exception (`TvCancelledException` after `close`).

There is no reconnecting inside the package. A pattern that works: on any `done` other than `null`, wait 1, 2, 4, 8, 16 seconds, then every 30 seconds, and call `connect` again; stop on `TvWrongTvException` and `TvNotPairedException`, which need the user.

## Several sessions

One identity can hold several sessions, to one or more TVs. Several clients with their own identities can hold sessions with the same TV at once, each seeing the TV's reports (two clients of this package, on the Android TV emulator).

## Raw messages

`remote.rawMessages` gives every message from the TV as bytes, and `remote.sendRaw(field, body)` sends one in the given envelope field, for messages the package does not handle yet. Both are experimental.
