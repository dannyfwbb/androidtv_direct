# Test fixtures

- `remote/messages.txt`: messages recorded from the Android TV Remote Service, one per line (the header says how to read them). The tests decode every line and encode it back to the same bytes.
- `pairing/vector/`: the certificates of a pairing a real remote service accepted, with the code and the secret (its `README.md`). Kept permanently.
- `identities/`: RSA-2048 keys with self-signed certificates for the fake TV and the tests, made once with `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -addext basicConstraints=critical,CA:TRUE`. Each file holds the certificate, then the private key. They are test keys, not secrets: nothing trusts them.
