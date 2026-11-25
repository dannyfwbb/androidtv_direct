# Errors

> Planned: the error type is designed and will be built in the first phases. Names may still change before 0.1.0.

Every failure of an operation on a TV will be a `TvRemoteException`. Parsing input the app gives (a PEM identity) throws `FormatException`, as Dart's own parsers do; invalid arguments throw `ArgumentError`.

`TvRemoteException` is a sealed class, so a `switch` over its subclasses is exhaustive; `code` (a `TvErrorCode`) gives the same information as a stable value for logs, and `cause` keeps the underlying error (an `OSError`, a TLS error, …) when there is one.

| `code` | When | What an app usually does |
| --- | --- | --- |
| `unreachable` | No connection could be opened in time, or there is no route to the address | "The TV doesn't answer": check it is on and on the same network; retry later |
| `noService` | The address answered but refused the port: the TV has no remote service, or it is turned off | Explain that this TV cannot be controlled this way |
| `notPaired` | The remote port refused the client's certificate: the TV does not know this client (never paired, or it forgot) | Pair again |
| `wrongTv` | The device at the address has another key than the paired TV; nothing was sent | Do not retry: another device has the TV's address, or the TV was reset. Ask the user |
| `wrongCode` | The code cannot be the one on the TV (wrong length, not hexadecimal, or it does not fit the keys); nothing was sent and the pairing stays open | Let the user type it again |
| `pairingRefused` | The TV ended the pairing: it refused the code, answered an error, or its user cancelled | Start the pairing again |
| `linkRefused` | The TV refused an app link; it closes the session right after | Reconnect; use a deep link the app on the TV handles |
| `outdatedService` | The TV speaks only the older protocol (recognised by discovery from its announcement) | Ask the user to update the Android TV Remote Service on the TV |
| `notSupported` | The TV did not offer what the call needs (keys, text, voice, links) | Hide the feature for this TV |
| `timeout` | The connection is open but the TV stopped answering: no message for 16 seconds, or no answer within a step's deadline | Treat the session as lost; reconnect |
| `closed` | The TV closed the connection | Reconnect |
| `protocol` | The TV sent something that breaks the protocol; the session is unusable | Reconnect; report it if it repeats |
| `cancelled` | The app cancelled the operation | — |

A timeout while opening the socket is `unreachable`; `timeout` is reserved for silence after the socket is open, which is what a TV that went away looks like.

Codes keep their meaning across versions. A new failure kind arrives as a new subclass with a new code, and only in a major version.
