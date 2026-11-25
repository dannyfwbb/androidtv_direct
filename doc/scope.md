# Scope

`androidtv_direct` aims to do everything the Android TV remote protocol (version 2) offers, from pure Dart, with every TV that speaks it. This page lists every area and its state.

States: **planned** (designed, not written), **in progress**, **built** (implemented and tested, not yet released), **done** (with the version that shipped it).

## Coverage

### Identity and pairing

| Area | State |
| --- | --- |
| The client's RSA key and self-signed certificate: generate, export and import as PEM | planned |
| Pairing with the six-character code the TV shows; the code checked before anything is sent | planned |
| The TV's key fingerprint from pairing, for pinning | planned |
| Cancelling a pairing (the TV closes its dialog) | planned |
| What the TV's certificate says (model, network address details) without pairing, if it shows nothing on the TV | planned (verified first) |

### The session

| Area | State |
| --- | --- |
| Connect with a paired identity; "not paired" told apart from network trouble | planned |
| Pinning: refuse a TV whose key is not the paired one, before sending anything | planned |
| Feature negotiation (keys, text, power, volume, links, voice) | planned |
| Device information (vendor, model, Android version, service version) | planned |
| Keepalive answers and detection of a TV that went away (silence in both directions) | planned |
| Deadlines on connect, start and every step; cancellation | planned |
| Raw access to messages the package does not wrap yet | planned |

### Remote control

| Area | State |
| --- | --- |
| Keys by name (every AOSP key code) and by number | planned |
| Short press, press and release (the TV repeats held keys) | planned |
| Power state and the power key | planned |
| Volume state (level, maximum, muted) and volume keys | planned |
| App links (deep links, store pages); a refused link reported as such | planned |

### Text

| Area | State |
| --- | --- |
| The focused text field as state: content, cursor, kind (password, action key), keyboard open or closed | planned |
| `setText`: bring the TV's field to the given text, any script and emoji | planned |
| Edits made on the TV with its own remote, reported back | planned |

### Voice

| Area | State |
| --- | --- |
| Voice sessions: start, stream 16-bit 8 kHz mono PCM, end, cancel | planned |

### Discovery

| Area | State |
| --- | --- |
| mDNS browsing for `_androidtvremote2._tcp`, IPv4 and IPv6 | planned |
| Recognition of TVs with the older protocol (`_androidtvremote._tcp`) | planned |
| A hook for platform browsers (iOS, Android) | planned |
| A helper to probe addresses the app gives (scan policy stays with the app) | planned |

### Library qualities

| Area | State |
| --- | --- |
| One sealed exception type with stable codes | planned |
| Tracing by message kind and size; payloads only on request | planned |
| A fake TV and recorded byte exchanges in the tests | planned |
| API documentation on every public member | planned |

## Left to the app, on purpose

- **Storing** the client's identity and the TVs' fingerprints. The package gives and takes PEM and strings; it never writes files.
- **Reconnecting.** The package fails fast with typed errors; the app decides how often to try again. [protocol.md](protocol.md) describes a pattern that works.
- **Address policy**, for example accepting only private addresses.
- **The microphone.** Voice takes PCM bytes; recording them is platform code.
- **Deep links per app.** They change with the apps; the package sends what it is given.

## Not planned

- **The older protocol (version 1)**, spoken by TVs whose remote service has not been updated in years: such TVs are recognised and reported, so the app can ask the user to update the service. Implementing it is reconsidered if users need it.
- **Pointer, screen contents, the list of installed apps, "now playing"**: the protocol does not carry them.
- **Opening an app by its package name**: TVs stopped accepting it in 2026; apps are opened with their deep links.
- **Other TV platforms** (Samsung Tizen, LG webOS, Roku, Fire TV): different protocols.
