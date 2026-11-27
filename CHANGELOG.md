# Changelog

## Unreleased

Nothing released yet. Built so far:

- `TvClientIdentity`: the client's RSA key and self-signed certificate, generated in an isolate, with a unique certificate name; PEM in and out.
- `TvIdentity` and `TvProbe.identify`: what a TV's certificate says (model, network address, key fingerprint), read without pairing and without anything on the TV.
- `TvPairing`: pairing with the code on the TV's screen; a mistyped code is caught before anything is sent and the pairing stays open.
- `TvRemote`: the remote session with the TV's key pinned in the TLS handshake, features, device information both ways (`TvClientInfo` tells the TV which app and device connected), state (power, volume, app in front) and changes, a two-way watchdog, raw messages.
- `connect` returns once the TV's input is ready for keys (`inputSettle`, 150 ms after the setup): a key sent at once was lost, as the TV registers a virtual input device for each session and Android adds it tens of milliseconds later.
- Keys (`press`, `hold`, `sendKeyCode`, the whole AOSP key table as `TvKey`), `setVolume` by keys (a lost press is pressed again), `openLink` with refused links reported as `TvLinkRefusedException`.
- `TvTextField`: the focused text field as state, `setText` that brings it to any text with edits that name the range they replace (wherever the cursor is, a 2000-character field emptied at once; Del keys for TVs without ranges, never sent twice while a batch may still land), changes made on the TV.
- `startVoice` and `TvVoiceSession`: audio for the TV's voice search in 20 480-byte chunks, paced in real time; the TV's own end of a session is followed; a session the TV opens when no start waits is closed again, unless it is the one already open.
- Discovery: `TvMdnsBrowser` for `_androidtvremote2._tcp` and `_androidtvremote._tcp` (an outdated remote service), `TvServiceBrowser` for platform browsers, `TvProbe.scan` over addresses the app chooses.
- A slow network: the session measures how long the TV takes to answer, from its start, and waits for text and volume reports at least that long (smoothed, with its variation, as TCP does, at most 10 s); a text edit whose report comes after the wait is recognised, and one the TV dropped meanwhile goes again.
- Wrong arguments (a host that is none, a port outside 1 to 65535, a fingerprint that is not 64 hexadecimal characters, a timeout not longer than zero, a blank client or certificate name, a host with spaces around it) fail at the call with an `ArgumentError` naming the parameter; fingerprints are taken in either case.
- One sealed `TvRemoteException` with stable `TvErrorCode`s; deadlines and cancellation (a connection given up during its TLS handshake, by timeout or cancellation, is closed at once; cancelling a scan stops its running probes); a tracing hook that never carries typed text unless asked to (what it throws goes to the zone, and the connection goes on); `TvInternalException` (code `internal`) when a bug in this package ends a session; held keys count as released when the session ends.
