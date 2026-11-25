# Security model

What the protocol protects, what it does not, and what the package and the app each do about it. To report a weakness, see [SECURITY.md](../SECURITY.md).

## What a paired client can do

Everything the TV's remote can: press any key, turn the TV off, type into any field (including passwords), open links, start voice search. A pairing is therefore worth protecting on both ends.

## Pairing

- The TV accepts any client certificate on the pairing port; the six characters on its screen are what proves that the user (who sees the screen) wants this client.
- The secret is a hash over both public keys and the code, and the code's first byte is itself a hash byte over the keys the TV sees. A device that relays the connection presents its own key to each side, so the code the TV shows does not fit the keys the client sees: the client's local check rejects it, and the package sends nothing.
- That check is only 8 bits. A relay passes it once in 256 attempts on average; it would then learn enough from the client's secret to pair its own key with the TV. Pairing is therefore strong against a passive listener and against mistakes, and only probabilistic against an active attacker on the network during pairing. Pair on a network you trust; a correctly typed code that the package reports as wrong (`wrongCode`) more than once is a warning sign, and apps may say so.
- The package checks the code's first byte locally and sends nothing for a mistyped code.

## Pinning the TV's key

The TV's certificate is self-signed; no authority vouches for it. After pairing, the only proof that a device is "the TV" is that it holds the same key as during pairing.

- `TvPairing.finish` returns the SHA-256 fingerprint of the TV's public key.
- `TvRemote.connect(fingerprint: …)` compares the key the device presents with it during the TLS handshake and, if they differ, fails with `wrongTv` **before sending anything**: the handshake is aborted as soon as the TV's key is seen.
- The fingerprint is a required argument. Passing `null` is possible, deliberately, and then the connection trusts whatever answers at the address. Addresses on home networks change (DHCP); another device that gets the TV's old address would receive whatever the user types next. Apps should always store and pass the fingerprint.
- A TV whose remote service data was cleared, or that was reset, is expected to have a new key (not verified yet on real TVs): it then fails with `notPaired` or `wrongTv`, and needs a new pairing. Apps should explain this rather than retry.

## The client's identity

- The identity is an RSA private key and a certificate. The TV recognises the client by it; whoever has a copy can control every TV paired with it.
- The package never writes it anywhere: `toPem()` gives it to the app, `fromPem()` takes it back. Store it in the platform's protected storage (Keychain on iOS and macOS; on Android, encrypt it under a key in the Android Keystore; DPAPI or the Credential Manager on Windows; libsecret on Linux) and keep it out of backups that leave the device if that matters to the app.
- The key cannot live inside a hardware keystore: `dart:io` needs the private key's bytes to set up TLS, so the key exists in memory while connecting. (Android's Keystore would not help anyway for this protocol: the TLS handshake needs RSA-PSS signatures with parameters it does not offer.)
- One identity can serve any number of TVs. Separate identities per TV are possible and limit what one stolen key controls.

## Addresses

The package connects where it is told. Apps that only ever talk to TVs on the local network may want to refuse public addresses before connecting; this is policy, so it is left to the app.

## Tracing

The tracing hook reports connection steps and message kinds and sizes. Message contents (typed text, voice audio, link targets) and key material appear only at an explicit raw level that the app turns on for debugging. Release builds should leave it off.
