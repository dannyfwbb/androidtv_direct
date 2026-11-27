# Changelog

## 1.0.0 - 2026-11-27

First release.

- **Identity:** `TvClientIdentity`, the client's RSA key and self-signed certificate, generated in an isolate with a unique certificate name; PEM in and out.
- **Before pairing:** `TvIdentity` and `TvProbe.identify` read what a TV's certificate says (model, network address, key fingerprint) without anything appearing on the TV.
- **Pairing:** `TvPairing` with the code on the TV's screen; a mistyped code is caught before anything is sent, and the pairing stays open for another try.
- **Session:** `TvRemote.connect` with the TV's key pinned inside the TLS handshake. It returns once the TV takes keys; the TV sets up an input device for each session, so this is 150 ms after the setup at the least (`inputSettle`).
  - Features, device information both ways (`TvClientInfo` tells the TV which app and device connected), and state (power, volume, app in front) with its changes.
  - A two-way watchdog, and raw messages for what the package does not wrap.
- **Keys:** `press`, `hold`, `sendKeyCode` and the whole AOSP key table as `TvKey`.
- **Volume:** `setVolume`, by keys, with a press the TV loses pressed again.
- **App links:** `openLink`; a refused link is reported as `TvLinkRefusedException`.
- **Text:** `TvTextField`, the focused text field as state, with changes made on the TV reported back.
  - `setText` brings the field to any text, any script and emoji, with edits that name the range they replace, wherever the cursor is.
  - TVs that do not take ranges get Del keys and inserts at the cursor, and a batch of keys is never sent twice while it may still land.
- **Voice:** `startVoice` and `TvVoiceSession` send audio to the TV's voice search in 20 480-byte chunks, paced in real time, and follow the TV's own end of a session.
- **Discovery:**
  - `TvMdnsBrowser` for `_androidtvremote2._tcp`, and `_androidtvremote._tcp`, which marks an outdated remote service.
  - `TvServiceBrowser` for platform browsers.
  - `TvProbe.scan` over addresses the app chooses.
- **Slow networks:** the session measures how long the TV takes to answer, the way TCP measures its round trip, and waits for reports at least that long, at most 10 s. A report that comes after the wait is still recognised.
- **Errors and arguments:**
  - One sealed `TvRemoteException` with stable `TvErrorCode`s.
  - Wrong arguments fail at the call with an `ArgumentError` naming the parameter: a host, a port, a fingerprint, a timeout, a blank name.
- **Deadlines and cancellation:** on every operation. A connection given up during its TLS handshake is closed at once.
- **Tracing:** a hook that never carries typed text or audio unless asked to.
