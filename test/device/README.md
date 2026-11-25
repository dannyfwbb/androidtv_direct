# Device tests

Tests tagged `device` run against a real Android TV Remote Service and are skipped unless both variables are set:

```bash
ANDROIDTV_DIRECT_TEST_HOST=127.0.0.1 ANDROIDTV_DIRECT_TEST_SERIAL=emulator-5554 dart test -t device
```

- `ANDROIDTV_DIRECT_TEST_HOST`: the TV's address. For an Android TV emulator, forward both ports with `adb emu redir add tcp:6466:6466` and `adb emu redir add tcp:6467:6467` (not `adb forward`: the remote port refuses connections from the TV's own loopback address) and use `127.0.0.1`.
- `ANDROIDTV_DIRECT_TEST_SERIAL`: the TV's adb serial; the tests read the pairing code from the screen with `uiautomator`. `ADB` may point at the adb binary.

Every pairing adds a client on the TV. Use an emulator or a TV you own; on an emulator, `adb shell pm clear com.google.android.tv.remote.service` forgets every client (and every phone paired with it).
