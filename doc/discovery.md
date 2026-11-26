# Finding TVs

## mDNS

TVs announce their remote service with DNS-SD over multicast DNS:

| Type | `TvServiceType` | `TvService.protocol` |
| --- | --- | --- |
| `_androidtvremote2._tcp` | `v2` | `TvProtocol.v2`: the protocol this package speaks |
| `_androidtvremote._tcp` | `v1` | `TvProtocol.v1`: an older protocol; the TV's Android TV Remote Service needs an update |

```dart
final sub = TvMdnsBrowser().browse(TvServiceType.all).listen((event) {
  switch (event) {
    case TvServiceFound(:final service):
      print('${service.instance} at ${service.address}:${service.port} (${service.protocol.name})');
    case TvServiceUpdated(:final service):
      print('${service.instance} changed');
    case TvServiceLost(:final service):
      print('${service.instance} left');
  }
});
```

`TvService` carries the instance name (the TV's name, as its user set it: "Living room TV"), the port of the remote service (6466), the host name, the addresses (IPv4 and routable first, loopback last), the TXT pairs and `bluetoothAddress` (TXT `bt`). The pairing port, 6467, is not announced: it is the convention, and `TvPairing` uses it by default.

`TvMdnsBrowser` shares port 5353 with the system's responder and hears announcements and goodbyes, so a TV that leaves is lost within about two seconds; where it cannot share the port it asks from a port of its own and notices a departure when the records expire. It asks again at growing intervals up to a minute, refreshes records before they expire, resolves what is missing (SRV, TXT, addresses), keeps only the records of the browsed types (bounded in number and age) and ignores malformed packets. A service is reported once its SRV and an address are known; an SRV with port 0 (not available) makes it lost, and a PTR naming an instance of another type is ignored. It works over IPv4 and IPv6; a link-local IPv6 address comes with its interface (`fe80::1%wlan0`). An emulated TV announces inside its own virtual network and is not found from outside it.

## Platform notes

- **Android:** hold a `WifiManager.MulticastLock` while browsing, or many Wi-Fi drivers drop multicast; the app needs the `INTERNET` and `CHANGE_WIFI_MULTICAST_STATE` permissions.
- **iOS:** raw multicast needs Apple's multicast entitlement (`com.apple.developer.networking.multicast`). Without it, browse with `NWBrowser` and hand the results over through `TvServiceBrowser` ([example/platform_browser.dart](../example/platform_browser.dart) shows an adapter). Either way the app declares both types under `NSBonjourServices` (`_androidtvremote2._tcp`, `_androidtvremote._tcp`) and gives `NSLocalNetworkUsageDescription`.
- **macOS, Windows, Linux:** the built-in browser works as it is (on Windows the system may own port 5353; the browser then asks from a port of its own).

## Without mDNS: probing

`TvProbe.identify(host)` connects to the pairing port, reads the TV's certificate and closes without sending anything; nothing appears on the TV. It gives the model, the network address and the key fingerprint ([identity.md](identity.md)).

`TvProbe.scan(hosts)` probes many hosts, at most `concurrency` (16) at once, each limited by `timeout` (1 s), and emits the hosts that answer as a TV's remote service: a TLS server on the pairing port whose certificate the remote service made. Which hosts to try (a subnet, addresses typed in) is the app's policy, as is whether to accept only private addresses. Cancelling the subscription ends the probes still running. A TV busy with a pairing does not answer, and a probe then keeps its pairing port busy for a while: do not scan while the app is pairing ([pairing.md](pairing.md)).

```dart
final hosts = [for (var i = 1; i < 255; i++) '192.168.0.$i'];
await for (final found in TvProbe.scan(hosts)) {
  print('${found.host}: ${found.tv.model}');
}
```
