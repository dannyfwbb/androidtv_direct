# Scope

`androidtv_direct` aims to do everything the Android TV remote protocol (version 2) offers, from pure Dart, with every TV that speaks it. This page lists every area and its state.

States: **planned** (designed, not written), **in progress**, **built** (implemented and tested, not yet released), **done** (with the version that shipped it).

## Coverage

### Identity and pairing

| Area | State |
| --- | --- |
| The client's RSA key and self-signed certificate: generate, export and import as PEM | done (1.0.0) |
| Pairing with the six-character code the TV shows; the code checked before anything is sent | done (1.0.0) |
| The TV's key fingerprint from pairing, for pinning | done (1.0.0) |
| Cancelling a pairing (the TV closes its dialog) | done (1.0.0) |
| What the TV's certificate says (model, network address details) without pairing, if it shows nothing on the TV | done (1.0.0; nothing appears on the TV) |

### The session

| Area | State |
| --- | --- |
| Connect with a paired identity; "not paired" told apart from network trouble | done (1.0.0) |
| Pinning: refuse a TV whose key is not the paired one, before sending anything | done (1.0.0) |
| Feature negotiation (keys, text, power, volume, links, voice) | done (1.0.0) |
| The client's own device information sent to the TV (model, maker, OS, app and version) | done (1.0.0; the TV only logs it) |
| Device information (vendor, model, Android version, service version) | done (1.0.0) |
| Keepalive answers and detection of a TV that went away (silence in both directions) | done (1.0.0) |
| Deadlines on connect, start and every step; cancellation | done (1.0.0) |
| Raw access to messages the package does not wrap yet | done (1.0.0; experimental) |

### Remote control

| Area | State |
| --- | --- |
| Keys by name (every AOSP key code) and by number | done (1.0.0) |
| Short press, press and release (the TV repeats held keys) | done (1.0.0) |
| Power state and the power key | done (1.0.0) |
| Volume state (level, maximum, muted) and volume keys; setting a level | done (1.0.0) |
| Setting or adjusting the volume directly, and choosing the audio output | not offered: the emulator ignored a level request and the audio-output messages; one form of the adjust message moved the volume a step, which keys already do |
| Wake-on-LAN with the network address from the TV's certificate | not offered: a real TV did not wake from it; the power key through a session wakes a TV in standby |
| App links (deep links, store pages); a refused link reported as such | done (1.0.0) |

### Text

| Area | State |
| --- | --- |
| The focused text field as state: content, cursor, kind (password, action key), keyboard open or closed | done (1.0.0) |
| `setText`: bring the TV's field to the given text, any script and emoji | done (1.0.0) |
| Edits made on the TV with its own remote, reported back | done (1.0.0) |
| The field's action key (Search, Go, Done…) | done (1.0.0) |

### Voice

| Area | State |
| --- | --- |
| Voice sessions: start, stream 16-bit 8 kHz mono PCM, end, cancel | done (1.0.0; sessions checked on a real TV; recognition of real speech still to be checked) |

### Discovery

| Area | State |
| --- | --- |
| mDNS browsing for `_androidtvremote2._tcp`, IPv4 and IPv6 | done (1.0.0) |
| Recognition of TVs with the older protocol (`_androidtvremote._tcp`) | done (1.0.0) |
| A hook for platform browsers (iOS, Android) | done (1.0.0; with an example adapter) |
| A helper to probe addresses the app gives, a few at a time (which addresses stays with the app) | done (1.0.0) |

### Library qualities

| Area | State |
| --- | --- |
| One sealed exception type with stable codes | done (1.0.0) |
| Tracing by message kind and size; payloads only on request | done (1.0.0) |
| A fake TV and recorded byte exchanges in the tests | done (1.0.0): the package's own recordings of pairing, a session, text and voice; a fake TV with pairing, session, text field and voice |
| API documentation on every public member | done (1.0.0) |

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
