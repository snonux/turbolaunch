<p align="center"><img src="logo-small.png" width="96" alt="TurboLaunch logo"></p>

# TurboLaunch

A small, search-first home screen for Android, made for GrapheneOS. Press
Home, type two or three letters, hit Enter, and the app opens. No tracking,
no Google Play Services; the only network use will be optional sync to your
own S3 bucket.

**Status: phase 3 of 5 (profiles and polish).** The F-Droid release and S3
sync follow; see the roadmap in [AGENTS.md](AGENTS.md#roadmap).

## Highlights

* fzf-style search: letters in order, gaps allowed, so "orgm" finds Organic
  Maps; matched letters highlighted; Enter launches the top match
* A home grid that fills itself with your most-launched apps, nearest the
  thumb first, and never moves an icon once placed
* App shortcuts ("New note", "Navigate home") are search results too
* Search box always on screen at the bottom; Home clears it
* Long-press an app: remove from or add to home, hide, app info, uninstall
* Clock, date and battery on top; long-press it to hide the grid (quick hide)
* Double-tap empty home space to lock, swipe down for notifications
* App pairs: two apps side by side in split screen, searchable and on the
  grid like any app
* A stats screen with launch counts and where each app sits
* Home and lock screen wallpapers, grid size and three font sizes in settings
* Work profile apps included, with a badge (greyed while work apps are paused)
* Export and import of everything as one JSON file, for a new phone

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
