# Pairing

A TV accepts the remote session only from clients it has paired with. Pairing is done once per client identity and TV: the TV shows six characters, the user types them into the app, and the TV remembers the client's certificate. Pairing does not need anything else on the TV (no developer options, no app).

```dart
final pairing = await TvPairing.start(
  '192.168.1.30',
  identity: me,                 // the app's TvClientIdentity
  clientName: 'My Remote',      // shown on the TV: "Enter the following code on your My Remote…"
);
// The TV now shows the code; pairing.tv says which TV it is (model, fingerprint).

while (true) {
  final code = await askUserForCode();
  try {
    final paired = await pairing.finish(code);
    await store(paired.fingerprint);   // keep it: every later connection checks it
    break;
  } on TvWrongCodeException {
    // Mistyped: nothing was sent, the TV still shows its code. Ask again.
  }
}
```

## Steps

1. `TvPairing.start(host, identity:, clientName:)` connects to the pairing port (6467) and runs the exchange up to the point where the TV shows its code. It returns when the code is on screen. `pairing.tv` is the TV as its certificate describes it ([identity.md](identity.md)).
2. `pairing.finish(code)` checks the code against both keys first. A code that cannot be the TV's (not six hexadecimal characters, in either case, surrounding spaces ignored; or a first character pair that does not fit the keys) fails with `TvWrongCodeException`, **sends nothing** and leaves the pairing open: call `finish` again with the corrected code, as often as needed. Otherwise it sends the secret, and on the TV's acknowledgement returns a `TvPairingResult` with the TV's `fingerprint`. The pairing is then over.
3. `pairing.cancel()` ends the pairing at any time; the TV closes its dialog.

## Failures

| Exception | When | Then |
| --- | --- | --- |
| `TvUnreachableException` | The address does not answer | Check the address and the network |
| `TvNoServiceException` | Nothing listens on the pairing port | The TV has no remote service (see [compatibility.md](compatibility.md)) |
| `TvTimeoutException` | The TV accepted the connection but did not finish TLS (it is busy with another pairing), or a step was not answered in time | Make sure no other pairing is open, then try again |
| `TvWrongCodeException` | From `finish`: the code cannot be right; nothing was sent | Ask for the code again; the pairing is still open |
| `TvPairingRefusedException` | The TV refused the code (status 402; one wrong code in 256 gets past the local check), answered another error status, or closed the pairing (its user pressed Cancel, or its dialog went away) | Start a new pairing |
| `TvProtocolException` | The TV sent something malformed or unexpected, or a certificate without an RSA key | Report it if it repeats |
| `TvCancelledException` | `cancelOn` completed before `start` returned, or `cancel()` was called during `finish` | — |

`isOpen` tells whether `finish` can still be called. Every failure except `TvWrongCodeException` ends the pairing. `cancel()` while `finish` waits makes `finish` throw `TvCancelledException`. Calling `finish` while another `finish` runs, or after the pairing is over, is a programming error (`StateError`).

A `TvProtocolException` from `finish` can come after the TV already stored the client; pairing again is harmless.

## Behaviour of TVs

Seen on the Android TV emulator (remote service 7.00), expected of other TVs but not yet confirmed on them:

- The TV serves one pairing at a time. While a dialog is open, another `start` (from this or another app) waits for the TLS handshake and times out. Always `finish` or `cancel` a pairing: cancelling while the code is shown frees the port at once, while a pairing that failed before the code appeared kept the port busy for up to about two minutes on the emulator.
- The dialog shows the client name given to `start`. The certificate's name does not appear.
- The dialog stays up until the client finishes or cancels (still there after 15 minutes): the TV does not time it out, so an app that gives up must call `cancel`.
- One mistyped code in 256 passes the local check; the TV then answers 402 and the pairing is over. A correctly typed code that keeps failing the local check suggests that something relays the connection ([security.md](security.md)).
- Each successful pairing adds an entry on the TV; pairing the same identity again is harmless.

## Deadlines

`timeout` (default 10 seconds) limits the connection, the TLS handshake and each step of `start`; `finish` has its own `timeout` for the TV's answer. The time the user takes to read and type the code is not limited by the package.

## Reading a TV without pairing

`TvProbe.identify(host)` connects to the pairing port, reads the TV's certificate and closes without sending anything. Nothing appeared on the emulator's screen. A TV busy with a pairing does not answer the probe (`TvTimeoutException`), and probes made then keep its pairing port busy for tens of seconds after the pairing ended: do not probe or scan a TV while pairing with it. It gives the model, the network address and the key fingerprint, for example to show a name before pairing or to tell TVs apart. The handshake needs a client certificate: pass the app's `identity`, or the probe makes a throwaway one once per isolate (which takes a moment the first time).
