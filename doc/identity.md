# Identities

Two kinds of identity take part in every connection: the client's, which the app makes and keeps, and the TV's, which the package reads from the TV's certificate.

## The client's identity

A `TvClientIdentity` is an RSA-2048 private key and a self-signed certificate for it. The TV remembers the certificate when it pairs with the client, and from then on lets that certificate, and nothing else, open the remote session.

Once per app installation:

```dart
final me = await TvClientIdentity.generate(now: DateTime.now());
await secureStorage.write(key: 'tv-identity', value: me.toPem());
```

Every start:

```dart
final me = TvClientIdentity.fromPem((await secureStorage.read(key: 'tv-identity'))!);
```

- `generate` makes the key in a separate isolate (pure Dart key generation takes a fraction of a second on a desktop, possibly more on a phone). `validity` (default ten years, must be positive) can be changed; the TVs tested so far (remote service 7.00) did not check the dates. The name the TV shows in its pairing dialog is the client name given at pairing, not the certificate's.
- **The certificate's name must be unique.** The TV remembers paired clients by the name in their certificate: pairing a client whose certificate carries the same name as an earlier one makes the TV forget the earlier one, which then fails with `TvNotPairedException` (seen on the Android TV emulator, remote service 7.00). The default name is `androidtv_direct/` followed by 16 random hexadecimal digits, so every identity has its own. Pass `commonName` only with a value that is just as unique.
- `toPem()` gives the certificate followed by the private key (PKCS#8). `fromPem` takes that back, also with the blocks in the other order or with a PKCS#1 (`RSA PRIVATE KEY`) key, and refuses with a `FormatException` a text without exactly one certificate and one RSA key, or a key that does not belong to the certificate.
- `fingerprint` is the SHA-256 of the client's public key in lower-case hex: a name for the identity in logs. It is not secret.
- One identity serves any number of TVs and sessions. Keep it for as long as the app is installed: a new identity means pairing every TV again.

The certificate is self-signed, carries a random serial number and the basic constraint CA (a remote service has been seen to refuse certificates without it on the remote port; the version tested now accepts them).

### Storing it

The PEM holds the private key: whoever has a copy can control every TV paired with it, type into its fields and turn it off. The package never writes it anywhere; storing it is the app's job.

| Platform | Where |
| --- | --- |
| iOS, macOS | The Keychain (`kSecClassGenericPassword`), not synchronised (`kSecAttrSynchronizable` false), "after first unlock this device only" |
| Android | Encrypt it with an AES key that lives in the Android Keystore, and keep the ciphertext in the app's private storage. Exclude it from backups if the app does not want identities to move to other devices |
| Windows | DPAPI (`CryptProtectData`) or the Credential Manager |
| Linux | The Secret Service (libsecret) |

In Flutter, `flutter_secure_storage` does all of this.

### Why not in a hardware keystore

The key cannot be generated inside Android's Keystore or Apple's Secure Enclave, because `dart:io` needs the private key's bytes to set up TLS: the key is in the app's memory while it connects. On Android it would not help anyway: the TLS handshake signs with RSA-PSS, which Keystore RSA keys do not offer with the parameters TLS requires. Wrapping the stored PEM under a hardware-backed key, as above, protects it at rest, which is what matters.

## The TV's identity

A `TvIdentity` is what a TV's certificate says. The remote service makes the certificate itself, the first time it runs (the one seen so far is valid until 2038); no authority vouches for it.

```dart
final tv = TvIdentity.fromCertificate(certificateDer);
tv.fingerprint;   // SHA-256 of the TV's public key, lower-case hex
tv.model;         // "SHIELD Android TV", or null
tv.macAddress;    // "AA:BB:CC:DD:EE:FF", or null
```

- `fingerprint` identifies the TV's key. Pairing will return it, and every later connection check it (see [security.md](security.md)). It is taken over the public key alone (the certificate's `SubjectPublicKeyInfo`), so it stays the same if the TV re-issues its certificate with the same key. The same value comes out of `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | sha256sum`.
- `product`, `device`, `model` and `macAddress` are read from the certificate's subject, best-effort. TVs are known to write them as `dnQualifier=<product>/<device>/<model>, CN=atvremote/<MAC>` or `CN=atvremote/<product>/<device>/<model>/<MAC>`; a common name without the `atvremote` prefix is not read, another layout leaves the fields `null`, and some TVs leave the network address out. The model is a name to show before pairing; the network address is what Wake-on-LAN needs.
- Only RSA keys take part in the protocol: a certificate with another kind of key is refused with a `FormatException`.
