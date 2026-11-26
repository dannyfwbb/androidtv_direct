# Voice

A session with `TvFeature.voice` can feed the TV's voice search with audio from the app's microphone. Voice is not in the default features; ask for it:

```dart
final remote = await TvRemote.connect(host, identity: me, fingerprint: fp, features: {...TvFeature.defaults, TvFeature.voice});

final voice = await remote.startVoice();       // presses Search; the TV opens its voice search
await voice.addStream(microphonePcm);          // 16-bit little-endian PCM, mono, 8 kHz
await voice.close();                           // the TV answers on its screen
```

## Steps

1. `startVoice()` presses Search and waits up to `timeout` (2 s) for the TV to open a voice session, which it acknowledges. It needs `TvFeature.voice` and `TvFeature.key`; one voice session per remote at a time (`StateError` otherwise). A TV whose voice search is still busy with the last session may not open a new one in time (`TvTimeoutException`): on the emulator, a Search right after a session ended timed out, one a few seconds later worked.
2. `add(pcm)` / `addStream(stream)` take the audio: 16-bit little-endian PCM, mono, 8000 samples a second (16 000 bytes a second). Recording it is the app's job (the package has no microphone code); most platforms record PCM directly, at 8 kHz or resampled to it.
3. The audio goes out in chunks of 20 480 bytes (1.28 seconds): TVs have been reported to close the connection on larger messages, to refuse smaller ones, and to recognise nothing in 8 KiB messages. With `pace: true` (the default) one chunk goes out every 1.28 seconds, as a microphone delivers audio; `add` waits while more than ten seconds of audio are waiting to go out. With `pace: false`, chunks go out as fast as they are added.
4. `close()` sends what is left, the last chunk padded with silence, and ends the session; `cancel()` drops what is left and ends it at once.
5. `done` completes when the session has ended: after `close` or `cancel`, or when the TV ended it (it sends a message for that; the voice search finished or gave up). Adding after the end throws `StateError`; if the remote session ends first, `add`, `close` and `done` fail with what ended it.

## Seen on the Android TV emulator (remote service 7.00)

- Search opened the voice session within 5-20 ms; the voice app is Google's (`com.google.android.katniss`).
- Three seconds of a test tone, paced and not paced, were taken; the emulator's assistant answered that it is not set up in its profile, so recognition itself was not tested there. Real speech on a real TV is still to be checked.
- After the client's voice end, the TV sent its own "ended" message.
