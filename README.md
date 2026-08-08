# Task Monster 🥚

A free, ad-free reward app for kids and families: finish a real-life task, press the button, and watch your monster evolve.

**Live app:** https://task-monster.ink

## How it works

1. A mystery egg appears. Nobody knows which creature is inside.
2. The child does a real task (homework, tidying up, brushing teeth…).
3. They press **I'M READY!** — the monster evolves with a burst of animation and sound.
4. A 60-second cooldown stops button-mashing before the next evolution.

Each creature grows through **15 stages**, from egg to an epic final form. There are five secret evolution lines — dragon, phoenix, leviathan, dino and alien — and every new egg (new profile, prestige, or reset) hatches a randomly chosen line, never the one just played, so the creature inside is always a surprise. Reaching the final stage earns a **Prestige** star and starts a fresh egg.

### Features

- **Multiple profiles** — each child gets their own monster, progress and prestige count.
- **Parent lock (optional)** — evolutions can be gated behind a 4-digit parent PIN (salted-hash stored, lockout after repeated wrong tries) or a fingerprint on Android.
- **Works offline** — a network-first service worker keeps the last-seen version launchable without a connection, while online loads always get the latest deploy.
- **No accounts, no backend** — everything is stored locally on the device.

## Tech stack

- **Flutter** (web + Android + iOS) with `provider` for state, `flutter_animate` for the evolution effects, `shared_preferences` for persistence and `audioplayers` for sound.
- Monsters are rendered as emoji (see `lib/data/stages.dart`) — no image assets to maintain.
- Hosted on **Firebase Hosting**; fully client-side.

Full functional and technical specs live in [`docs/specs.md`](docs/specs.md).

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d chrome   # or an Android device/emulator
```

Layout:

| Path | Purpose |
|---|---|
| `lib/data/` | Evolution lines and stage data |
| `lib/models/` | State: monster progress, profiles, parent lock |
| `lib/screens/` | Splash and home screens |
| `lib/widgets/` | Monster display, stage tracker, PIN pad |
| `lib/services/` | Parent gate, update checker, analytics, platform helpers |
| `test/` | Unit and widget tests (run before every commit) |

## Releasing

```bash
./scripts/release.sh "Optional commit message"
```

The script runs the full cycle: analyze + tests → patch version bump (`tool/bump_version.dart`) → commit & push → wait for GitHub CI to go green → build web → deploy to Firebase Hosting.

### iOS (App Store)

```bash
./scripts/release_ios.sh --upload
```

Archive → export → upload to App Store Connect. Export signing is **manual**
(`ios/ExportOptions.plist`): the release Mac has no Apple ID signed into
Xcode.app, and an App Store Connect API key cannot drive cloud-managed signing
either, so the export is pinned to the team's Apple Distribution identity and
the `Task Monster App Store` profile. Apple deletes that profile whenever the
distribution certificate is revoked — recreate it with `python3
scripts/mint_ios_profile.py --replace`. Uploading only puts the build in App
Store Connect; attaching it to a version and submitting for review is still
done there.

The donation ("Buy me a coffee") entry is hidden on iOS — App Store Review does
not allow it. Android and web keep it.

## Credits

Built by [Darumatic](https://darumatic.com). Task Monster is free and ad-free — if it helps your family, there's a "Buy me a coffee" link in the app's menu. ☕
