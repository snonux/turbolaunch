<p align="center"><img src="logo-small.png" width="96" alt="TurboLaunch logo"></p>

# TurboLaunch

A small, search-first home screen for Android, made for GrapheneOS. Press
Home, type two or three letters, hit Enter, and the app opens. No tracking,
no Google Play Services; the only network use will be optional sync to your
own S3 bucket.

**[Read the guide](docs/guide/README.md)**: installing, then every
feature with screenshots and a short recording.

| | |
|---|---|
| ![Home screen: clock and battery on top, the most-launched apps near the bottom, the search box below](docs/guide/images/home.png) | ![Typing "clk", Enter opens Clock, Home comes back to the grid](docs/guide/images/search.gif) |
| The home screen | Type, Enter, done |

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

## Install

Add the [snonux F-Droid repository](https://github.com/snonux/fdroid) to
F-Droid (on the phone, tap
**[Add to F-Droid](https://fdroid.link/#https://snonux.github.io/fdroid/repo?fingerprint=04B05FB0565543E058372B867B3D3A699D9D668388CE670478EDD4116D736DF7)**)
and install TurboLaunch, or take an APK from the
[releases](https://github.com/snonux/turbolaunch/releases). Then press Home
and pick TurboLaunch. Your old launcher stays installed, so you can always
switch back. Details in [Installing](docs/guide/README.md#installing).

## More

* [The guide](docs/guide/README.md): every feature, privacy, building it
  yourself
* [AGENTS.md](AGENTS.md): building, testing, releasing, conventions
* [Publishing on F-Droid](docs/fdroid-submission.md)
* Licence: [MIT](LICENSE)
