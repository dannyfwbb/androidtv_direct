# Changelog

## Unreleased

Nothing released yet. Built so far:

- `TvClientIdentity`: the client's RSA key and self-signed certificate, generated in an isolate, with a unique certificate name; PEM in and out.
- `TvIdentity` and `TvProbe.identify`: what a TV's certificate says (model, network address, key fingerprint), read without pairing and without anything on the TV.
- `TvPairing`: pairing with the code on the TV's screen; a mistyped code is caught before anything is sent and the pairing stays open.
- `TvRemote`: the remote session with the TV's key pinned in the TLS handshake, features, device information, state (power, volume, app in front) and changes, a two-way watchdog, raw messages.
- Keys (`press`, `hold`, `sendKeyCode`, the whole AOSP key table as `TvKey`), `setVolume` by keys, `openLink` with refused links reported as `TvLinkRefusedException`.
- `TvTextField`: the focused text field as state, `setText` that brings it to any text, changes made on the TV.
- One sealed `TvRemoteException` with stable `TvErrorCode`s; deadlines and cancellation; a tracing hook that never carries typed text unless asked to.
