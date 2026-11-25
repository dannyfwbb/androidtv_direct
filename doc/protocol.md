# The remote protocol

Notes on Android TV Remote protocol version 2 as this package implements it, for readers of the code and for anyone debugging a TV. The pairing part follows the protocol Google published in the Android Open Source Project (`platform/external/google-tv-pairing-protocol`); the rest is not published, and what is written here comes from recordings of the TV's remote service (versions 5.99 and 7.00, Android 14) made for this package. Field numbers are what TVs send; **field names are this package's**.

## Overview

| | Pairing | Remote |
| --- | --- | --- |
| Port | 6467 | 6466 |
| Transport | TLS, from the first byte | TLS, from the first byte |
| Client certificate | Any; the TV learns it here | Only one the TV paired with |
| Messages | pairing messages (`OuterMessage`, as published) | remote envelopes (see below) |
| Lifetime | One pairing, then closed | As long as the app wants; pings keep it alive |

The service on the TV is the Android TV Remote Service (`com.google.android.tv.remote.service`). It is updated from the Play Store on its own; version 5 and later speak version 2 of the protocol.

## TLS

- Both sides present certificates. The TV's is self-signed (subject `CN=atvremote/…`), RSA-2048, and the same on both ports. Nothing can verify it against a certificate authority: pairing binds it to the code on the screen, and the client pins it afterwards (see [security.md](security.md)).
- The client's certificate carries an RSA key (the pairing secret hashes RSA numbers, so other key types cannot pair). The package marks it as a CA (basic constraints): a remote service has been seen to pair with a certificate without that flag and then refuse it on the remote port, though current versions accept it. TVs do not check the certificate's dates.
- A client certificate the TV does not know: TLS 1.3 completes from the client's point of view, and the TV's refusal arrives as an alert on the client's first read (`certificate unknown`). Some older TVs have been reported to fail the handshake instead; whether that means "not paired" or a TLS incompatibility is not known yet.
- The remote port refuses connections that arrive from the TV's own loopback address (as a port forward through the TV would). Pairing accepts them.

## Framing

Each message is a Protocol Buffers message preceded by its length as a varint (7 bits per byte, least significant group first, high bit set on all bytes but the last). A message may arrive in several TCP reads, and several messages in one. The package refuses frames longer than 1 MiB and varints longer than 10 bytes.

Only two protobuf wire types occur: varint (0) and length-delimited (2). Unknown fields are skipped, whatever their wire type, so a newer service's additions do not break the client; the package keeps them, so a message it reads encodes back to the same bytes. Groups (wire types 3 and 4) are refused as malformed.

Fields are written in ascending field number, as every message recorded from the TV has them. The TV writes some zero values explicitly (a power report of "off", a keyboard report of "closed"); readers treat an absent field and a zero alike.

## Pairing (port 6467)

### The outer message

| Field | Meaning |
| --- | --- |
| 1 | Protocol version: **2** |
| 2 | Status: 200 OK, 400 error, 401 bad configuration, 402 bad secret. Any status but 200 ends the pairing |
| 10 | Pairing request |
| 11 | Pairing request acknowledgement |
| 20 | Options |
| 30 | Configuration |
| 31 | Configuration acknowledgement |
| 40 | Secret |
| 41 | Secret acknowledgement |

The published protocol carries the inner message's type in field 3 and its bytes in field 4. Version 2 puts each inner message directly into the field numbered after its type, as in the table. The Android TV emulator (remote service 7.00) answers a message in the published form with status 400.

### Inner messages

| Message | Fields |
| --- | --- |
| Pairing request | 1 service name (`atvremote`), 2 client name (shown on the TV) |
| Pairing request acknowledgement | 1 server name (often empty) |
| Options | 1 input encodings, 2 output encodings (each: 1 type, 2 symbol length), 3 preferred role |
| Configuration | 1 encoding (1 type, 2 symbol length), 2 client role |
| Configuration acknowledgement | empty |
| Secret | 1 the secret (bytes) |
| Secret acknowledgement | 1 the secret, echoed |

Encoding types: 0 unknown, 1 alphanumeric, 2 numeric, 3 hexadecimal, 4 QR code. Roles: 1 input (the client inputs the code the TV shows), 2 output.

### The exchange

| Client | TV |
| --- | --- |
| request (service `atvremote`, client name) | acknowledgement |
| options: input hexadecimal, 6 symbols, role input | options: output hexadecimal, 6 symbols, role input |
| configuration: hexadecimal, 6 symbols, role input | acknowledgement; **the TV shows six characters**, e.g. `76BBF0`, and "Enter the following code on your *client name*…" |
| secret | acknowledgement echoing the secret; the TV closes the dialog |

Seen on the Android TV emulator (remote service 7.00); not yet confirmed on other TVs:

- The TV accepts other service names than `atvremote`; every client sends that one.
- The TV serves **one pairing connection at a time**. While one is open (the dialog is up, or a connection was left half-way), a second connection is accepted but its TLS handshake is not answered until the first ends; the package reports that as a timeout. Closing a pairing while the code is shown closes the dialog and frees the port at once; a connection closed earlier in the exchange kept the port busy for up to about two minutes on the emulator.
- The TV's options offer only output, hexadecimal, six symbols.

### The secret

The six characters are three bytes, `c0 c1 c2`. (The published protocol splits codes differently and only allows an even number of bytes; version 2 TVs use the split below.) The client computes

```
alpha = SHA-256( client modulus ‖ client exponent ‖ TV modulus ‖ TV exponent ‖ c1 ‖ c2 )
```

where each number is written as unsigned big-endian bytes **without leading zero bytes** (65537 is `01 00 01`), the client's key comes first and the TV's key is the one in the certificate the TV presented during the TLS handshake. The client sends all 32 bytes of `alpha`.

`c0` must equal the first byte of `alpha`. This lets the client reject a mistyped code itself (255 times in 256) without telling the TV anything, so the user can simply type again. A wrong code that passes this check is refused by the TV with status 402, which ends the pairing.

Because the hash covers both public keys, the code ties the pairing to the two keys of the TLS connection. A device relaying the connection would present different keys to each side, and the code would fail the client's check, but only with the strength of one byte; [security.md](security.md) discusses what that means.

## The remote session (port 6466)

### Start

| TV | Client |
| --- | --- |
| setup: the features it offers, its device information | setup: the features it wants (masked by the offer), its own device information |
| activate | activate: the same features |
| focus report: the app in front | |
| power report: on or off | |
| volume report | |

The session is ready at the power report. On the Android TV emulator this took about 30 milliseconds after the TLS handshake; over a real network expect up to about a second.

### Features

| Bit | Value | Feature |
| --- | --- | --- |
| 0 | 1 | Pings |
| 1 | 2 | Keys |
| 2 | 4 | Text input (and reports of the app in front) |
| 3 | 8 | Voice |
| 4 | 16 | Offered by TVs, purpose unknown, not requested |
| 5 | 32 | Power state |
| 6 | 64 | Volume state |
| 9 | 512 | App links |

The emulator offers 639 (all of the above); real TVs may offer less, so the package checks the offer before using a feature. Some TVs show a "use the keyboard on your phone" notice whenever a client asks for text input; apps that do not type can leave it out.

### Keeping the session alive

While the client sends nothing, the TV sends a ping every 5 seconds; the client answers with the ping's first field. While the client is sending (keys every few seconds), the TV does not ping. A session is therefore considered lost after **16 seconds without any message in either direction**: counting only the TV's messages would end a busy session. On the emulator, a TV in standby keeps its connections and keeps pinging; whether real TVs in deep standby stay on the network differs from model to model and is not verified yet.

There is no goodbye message; either side closes the socket.

### Messages

Every message is an envelope that carries exactly one of these fields (the names are this package's). An envelope with no field or with several is malformed; a field number the package does not know is a message it does not know yet, reported to the tracing hook and otherwise ignored.

| Field | Message | Direction |
| --- | --- | --- |
| 1 | setup | both |
| 2 | activate | both |
| 3 | refusal | TV → client |
| 8 | ping | TV → client |
| 9 | pong | client → TV |
| 10 | key | client → TV |
| 20 | focus report: the app in front and the focused field | TV → client |
| 21 | keyboard report (TV → client) / text edit (client → TV) | both |
| 22 | field report: the field's content | TV → client |
| 30 | voice open | both |
| 31 | voice audio | client → TV |
| 32 | voice close | client → TV |
| 40 | power report | TV → client |
| 50 | volume report | TV → client (the same field from the client, a level request, is ignored) |
| 51 | volume adjust | client → TV (not verified) |
| 60, 61 | audio output, set and reset | client → TV (not verified) |
| 90 | open link | client → TV |

**setup** (1): 1 features; 2 device information: 1 model, 2 vendor, 3 (unknown, 1), 4 Android version (`14`), 5 package of the service, 6 its version. Clients send fields 3-6 of their own.

**activate** (2): from the TV empty; from the client 1 = its features.

**refusal** (3): 1 a number (7 for a refused app link), 2 the refused message, echoed. The TV closes the connection right after a refusal.

**ping** (8) and **pong** (9): the ping carries 1 a small number and 2 a growing one; the pong carries 1 = the ping's field 1.

**key** (10): 1 the Android key code (`KeyEvent`), 2 the action: 1 press, 2 release, 3 short press (both). Between press and release the TV repeats the key as a held button would.

**power report** (40): 1 = 1 on, 0 off. Sent at the start and whenever the power state changes.

**volume report** (50): 3 the output device's name, 6 maximum, 7 level, 8 muted; fields 1, 2, 4 and 5 describe the audio output and are not interpreted yet. Sent at the start and after every change.

**open link** (90): 1 the link.

### Text input

The TV reports the field that has the focus and its changes; the client sends edits.

| TV event | Message |
| --- | --- |
| An app comes to the front | 20 with only the app's package (field 1 → 12) |
| A text field gets the focus | 20 with the app information (1: keyboard revision, input type, IME options, package, …) and the field status (2) |
| The field loses the focus | 20 without a field status |
| The TV's keyboard opens or closes | 21 with 1 ≠ 0 (open) or 0 (closed), 2 the field counter |
| The field's content changes | 22 with the field status |

Field status: 1 the field's revision, 2 the whole text, 3 selection start, 4 selection end (the cursor), 5 (unknown). Positions count UTF-16 code units, as Android's and Dart's `String` indices do.

An edit from the client is message 21 with 1 the keyboard revision and 2 the field revision from the TV's last report on that field, and 3 one edit: 1 = 1 (insert), 2 = {1 position, 2 position, 3 text}, both positions being the inserted text's length. What the TV does with it:

- The text is **inserted at the cursor**; the field is not replaced. To replace text, delete it first with the Delete key (key code 67, which deletes before the cursor), once per character as the user sees it. When the cursor is not at the end of the field, the package moves it there first.
- The edit is accepted only with the field's **current revisions**, and every accepted edit or deletion changes the field revision. The new revision arrives with the TV's next report of the field. An edit sent before that report is dropped without an error. The package therefore keeps one change in flight and sends what the user typed in the meantime as one edit after the report.
- The revisions to use are those of the focus report (message 20); the keyboard report's are only a fallback. Some TVs ignore edits made with the latter.
- Some apps' fields replace their content with each edit instead of inserting. The package works from the content the TV reports, not from what it sent, so both kinds end up with the requested text.

The input type and IME options are Android's `EditorInfo` values: they tell password fields apart and name the field's action key (Go, Search, Send, Next, Done).

### App links

The link is given to Android as a "view" intent on the TV; the app that handles it opens. Web addresses that an app claims (`https://www.youtube.com`) and store pages (`market://details?id=…`) work. A link nobody handles does nothing. A bare package name, `intent:`, `android-app:` and `market://launch?id=` links are refused with a refusal message, **after which the TV closes the session**: reconnect to continue. Since 2026, TVs do not open apps by package name at all; apps are opened through their deep links.

### Voice

1. The client asked for the voice feature when the session started.
2. Client: the Search key (84), short.
3. TV: voice begin with 1 a session number and 2 the voice app's package.
4. Client: voice begin with the same session number.
5. Client: voice audio messages, 1 the session number, 2 samples: 16-bit little-endian PCM, mono, 8000 samples per second. The package sends 20 480 bytes per message (1.28 seconds of audio), the last one padded: some TVs close the connection on larger messages, some refuse smaller ones, and one recognised nothing in 8 KiB messages.
6. Client: voice end with the session number.

## Discovery

TVs announce the remote service over mDNS:

| Service type | Meaning |
| --- | --- |
| `_androidtvremote2._tcp` | Protocol version 2; port 6466; TXT `bt` = the TV's Bluetooth address; the instance name is the TV's name |
| `_androidtvremote._tcp` | The older protocol: the TV's remote service needs an update |

The pairing port, 6467, is not announced.

The TV's certificate identifies it before pairing: its subject holds the product, device and model names and usually the network (MAC) address, for example `dnQualifier=<product>/<device>/<model>, CN=atvremote/<MAC>`; some TVs put everything in the common name, some leave the address out.

## Reconnecting

A pattern that works for remote-control apps: connect when the remote screen is shown, close when the app goes to the background; after a lost session try again after 1, 2, 4, 8 and 16 seconds, then every 30 seconds, with a "try now" for the user. "Not paired" (the TV forgot the client, or its data was cleared) and "wrong TV" should not be retried: they need a new pairing or the user's attention.
