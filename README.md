<p align="center"><img src="logo-small.png" width="96" alt="TurboLaunch logo"></p>

# TurboLaunch

A small, search-first home screen for Android, made for GrapheneOS. Press
Home, type two or three letters, hit Enter, and the app opens. No tracking,
no Google Play Services; the only network use will be optional sync to your
own S3 bucket.

**Status: phase 1 of 5 (skeleton).** It lists and launches every app,
including work profile apps, with a search box docked at the bottom. Fuzzy
search, the self-filling home grid, wallpapers, S3 sync and the F-Droid
release follow; see the plan in [AGENTS.md](AGENTS.md#roadmap).

## Highlights

* Every installed app over your wallpaper, icons fully opaque
* Search box always on screen, within thumb reach; Enter launches the top match
* Home clears the search; Back never leaves the home screen
* Long-press for app info
* App pairs (test): open two apps side by side through an opt-in accessibility service

## Try it

Build and install a debug APK, then pick TurboLaunch under Settings, Apps,
Default apps, Home app (or tap "Set as home app" in its settings):

```sh
flutter build apk --release --split-per-abi
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

The stock launcher stays installed, so you can always switch back.

## More

* [AGENTS.md](AGENTS.md): building, testing, releasing, conventions
* Licence: [MIT](LICENSE)
