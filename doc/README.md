# Documentation

| Document | What it covers |
| --- | --- |
| [scope.md](scope.md) | What the package does, what it leaves to the app, and the state of every area |
| [protocol.md](protocol.md) | The remote protocol as the package implements it: ports, TLS, framing, pairing, the session, every message, text, links, voice, discovery |
| [identity.md](identity.md) | The client's identity (making, storing, restoring it) and what a TV's certificate says |
| [pairing.md](pairing.md) | Pairing with a TV, its failures, and reading a TV without pairing |
| [session.md](session.md) | The remote session: connecting, features, state, staying alive, ending |
| [keys.md](keys.md) | Keys, the key table, power and volume |
| [links.md](links.md) | Opening app links, and the links TVs refuse |
| [errors.md](errors.md) | The error type, its codes and when each one is raised |
| [security.md](security.md) | The security model: what pairing proves, pinning the TV's key, storing the client's key, what is traced |
| [compatibility.md](compatibility.md) | Which TVs speak the protocol, service versions, known differences between TVs |

More pages arrive with the code: text, voice, discovery. Every public class and member is documented in the code; `dart doc` generates the API reference, which pub.dev shows.
