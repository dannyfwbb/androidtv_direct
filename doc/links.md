# App links

A session with `TvFeature.appLink` (in the defaults) can open links on the TV.

```dart
remote.openLink('https://www.youtube.com');
remote.openLink('market://details?id=com.google.android.youtube.tv');
```

The TV hands the link to Android as a "view" intent, and the app that handles it opens: web addresses that apps claim (`https://www.youtube.com`, `https://app.primevideo.com`), app schemes (`plex://…`) and store pages (`market://details?id=…`). A link no app handles does nothing, and the session goes on.

## Links the TV refuses

TVs refuse a bare package name (`com.example.app`) and, by reports, `intent:…`, `android-app://…` and `market://launch?id=…`, and **end the session** after refusing (the bare package name and an empty link were checked on the Android TV emulator, remote service 7.00). The session's `done` then completes with `TvLinkRefusedException`, which carries the `link` and the TV's `refusalCode`; connect again to go on. TVs updated since mid-2026 no longer open apps by package name: use their deep links. The package does not keep a table of deep links per app; they change with the apps.

## Checks before sending

`openLink` throws `ArgumentError` for an empty link or one longer than 8192 bytes in UTF-8, and `TvNotSupportedException` when the session lacks `TvFeature.appLink`. It does not try to guess what the TV will accept.
