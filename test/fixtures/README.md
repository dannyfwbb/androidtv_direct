# Test fixtures

- `remote/session.txt`: the package's own recording (`tool/record_fixture.dart`) of a pairing and a session with the Android TV Remote Service. The fake TV plays the TV's side from it, and a replay test checks the client's answers byte for byte.
- `remote/messages.txt`: messages recorded earlier from the Android TV Remote Service by another client, kept for the text and voice messages until the package records its own. The tests decode every line and encode it back to the same bytes.
- `pairing/vector/`: the certificates of a pairing a real remote service accepted, with the code and the secret (its `README.md`). Kept permanently.
- `identities/`: RSA-2048 keys with self-signed certificates for the fake TV and the tests, made once with `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -addext basicConstraints=critical,CA:TRUE`. Each file holds the certificate, then the private key. They are test keys, not secrets: nothing trusts them.
