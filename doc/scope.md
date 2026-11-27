# Scope

`androidtv_direct` aims to do everything the Android TV remote protocol (version 2) offers, from pure Dart, with every TV that speaks it. This page lists every area and its state.

States: **planned** (designed, not written), **in progress**, **built** (implemented and tested, not yet released), **done** (with the version that shipped it).

## Coverage

### Identity and pairing

| Area | State |
| --- | --- |
| The client's RSA key and self-signed certificate: generate, export and import as PEM | built |
| Pairing with the six-character code the TV shows; the code checked before anything is sent | built |
| The TV's key fingerprint from pairing, for pinning | built |
| Cancelling a pairing (the TV closes its dialog) | built |
| What the TV's certificate says (model, network address details) without pairing, if it shows nothing on the TV | built (nothing appears on the TV) |

### The session

| Area | State |
| --- | --- |
| Connect with a paired identity; "not paired" told apart from network trouble | built |
| Pinning: refuse a TV whose key is not the paired one, before sending anything | built |
| Feature negotiation (keys, text, power, volume, links, voice) | built |
| The client's own device information sent to the TV (model, maker, OS, app and version) | built (the TV only logs it) |
| Device information (vendor, model, Android version, service version) | built |
| Keepalive answers and detection of a TV that went away (silence in both directions) | built |
| Deadlines on connect, start and every step; cancellation | built |
| Raw access to messages the package does not wrap yet | built (experimental) |

### Remote control

| Area | State |
| --- | --- |
| Keys by name (every AOSP key code) and by number | built |
| Short press, press and release (the TV repeats held keys) | built |
| Power state and the power key | built |
| Volume state (level, maximum, muted) and volume keys; setting a level | built |
| Setting or adjusting the volume directly, and choosing the audio output | not offered: the emulator ignored a level request and the audio-output messages; one form of the adjust message moved the volume a step, which keys already do |
| Wake-on-LAN with the network address from the TV's certificate | not offered: a real TV did not wake from it; the power key through a session wakes a TV in standby |
| App links (deep links, store pages); a refused link reported as such | built |

### Text

| Area | State |
| --- | --- |
| The focused text field as state: content, cursor, kind (password, action key), keyboard open or closed | built |
| `setText`: bring the TV's field to the given text, any script and emoji | built |
| Edits made on the TV with its own remote, reported back | built |
| The field's action key (Search, Go, Done…) | built |

### Voice

| Area | State |
| --- | --- |
| Voice sessions: start, stream 16-bit 8 kHz mono PCM, end, cancel | built (sessions checked on a real TV; recognition of real speech still to be checked) |

### Discovery

| Area | State |
| --- | --- |
| mDNS browsing for `_androidtvremote2._tcp`, IPv4 and IPv6 | built |
| Recognition of TVs with the older protocol (`_androidtvremote._tcp`) | built |
| A hook for platform browsers (iOS, Android) | built (with an example adapter) |
| A helper to probe addresses the app gives, a few at a time (which addresses stays with the app) | built |

### Library qualities

| Area | State |
| --- | --- |
| One sealed exception type with stable codes | built |
| Tracing by message kind and size; payloads only on request | built |
| A fake TV and recorded byte exchanges in the tests | built: the package's own recordings of pairing, a session, text and voice; a fake TV with pairing, session, text field and voice |
| API documentation on every public member | built |

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
