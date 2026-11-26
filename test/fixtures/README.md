# Test fixtures

- `remote/session.txt`: the package's own recording (`tool/record_fixture.dart`) of a pairing and a session with the Android TV Remote Service. The fake TV plays the TV's side from it, and a replay test checks the client's answers byte for byte.
- `remote/text.txt`: the package's own recording of text input: a field gets the focus, the client types (Cyrillic, an emoji with a skin tone), deletes and empties it, the field loses the focus.
- `remote/voice.txt`: the package's own recording of a voice session: Search opens it, the client sends a sweep and closes it, the TV ends it.

The tests decode every line of every recording and encode it back to the same bytes.
- `pairing/vector/`: the certificates of a pairing a real remote service accepted, with the code and the secret (its `README.md`). Kept permanently.
- `identities/`: RSA-2048 keys with self-signed certificates for the fake TV and the tests, made once with `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -addext basicConstraints=critical,CA:TRUE`. `remote-tv.pem` has the subject a TV's remote service writes (`dnQualifier=product/device/Test TV, CN=atvremote/AA:BB:CC:DD:EE:FF`). Each file holds the certificate, then the private key. They are test keys, not secrets: nothing trusts them.
