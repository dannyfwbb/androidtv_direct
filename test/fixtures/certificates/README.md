# Certificates for parsing tests

Made with `openssl req -x509 -newkey rsa:2048 -subj …` (`ec.crt.pem` with a P-256 key) in the subject layouts TVs use, with made-up names and addresses:

- `all-in-cn.crt.pem`: everything in the common name, `atvremote/<product>/<device>/<model>/<MAC>`.
- `dnqualifier-run-on.crt.pem`: a dnQualifier that runs on into `/CN=atvremote/<MAC>`.
- `no-mac.crt.pem`: product, device and model, no network address.
- `unknown.crt.pem`: a layout no TV uses.
- `ec.crt.pem`: an elliptic-curve key, which the protocol cannot use.

The TV certificate of the emulator image is `../pairing/vector/tv.crt.pem`.
