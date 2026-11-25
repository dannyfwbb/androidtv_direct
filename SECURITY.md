# Security

androidtv_direct talks to TVs over the network, holds the key a TV trusts, carries what users type (passwords included) and their voice, and parses what TVs and networks send. Reports of weaknesses are welcome.

## Reporting a vulnerability

Report it privately through GitHub: **Security → Report a vulnerability** on the repository. Please do not open a public issue for it.

Say what is affected (versions, platform, the call or protocol path), how to reproduce it, and what an attacker gains. A first answer comes within a week. Once a fix is released, the advisory is published with credit to the reporter, unless they prefer otherwise.

## Supported versions

Nothing is released yet. From the first release on, fixes go into the latest release of the current major version.

## In scope

- Anything a TV, a network peer or an mDNS announcement can send that makes the package crash, hang, use unbounded memory or CPU, or accept a connection it should refuse.
- Pinning: any way to make `TvRemote.connect` with a fingerprint talk to a device whose key differs, or to send anything before the check.
- Pairing: anything that lets a third party learn the code, pair in the user's place, or make the client accept a pairing the TV did not confirm.
- Key handling: the private key leaving the process through the package, or certificates made wrongly.
- Typed text, voice or keys appearing in logs or traces without the app asking for that level.

## Known limits, not vulnerabilities

These follow from the protocol and are documented:

- The TV's certificate is self-signed; nothing can verify it against a CA. Trust comes from the pairing code (it covers both keys) and from pinning the TV's key afterwards. An app that connects without a stored fingerprint trusts whatever answers.
- The client's private key is kept by the app; the package never stores it. Protecting it at rest (keychain, keystore) is the app's job.
- A paired client can do anything the TV's remote can: press keys, type, open links, use voice search.
