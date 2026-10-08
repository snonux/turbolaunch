# Working on TurboLaunch

TurboLaunch is a Flutter app for Android only (snonux, 2026-10-08: no Linux
build) that replaces the home screen. The stack and release process
follow [Quicklog](https://github.com/snonux/quicklog): Flutter for the UI and
logic, plus one small Kotlin plugin, `packages/launcher_platform`, for the
Android launcher APIs. The README is for people using the app; keep it short
and put build internals and conventions here.

Before calling anything done: `dart format`, `flutter analyze` and
`flutter test` must all be clean. For anything touching the Android build,
build a release APK too, `flutter build apk --release --split-per-abi`,
because the debug build hides signing and packaging problems. CI runs all of
this, plus the plugin's Kotlin unit tests, on every push.

**Every merge needs a full end-to-end run first** (snonux, 2026-10-08), not
just green CI: `tool/e2e_android.sh` on an Android emulator, which CI runs:

```sh
flutter build apk --release --split-per-abi
tool/e2e_android.sh build/app/outputs/flutter-apk/app-x86_64-release.apk  # emulator running
```

The Android script installs the APK, turns on the accessibility service
(uiautomator sees Flutter's text only then), makes it the home app, swipes
down for the shade, searches and launches Settings with Enter, presses Home,
checks the grid, menu, quick hide, settings and stats, double-taps to lock,
checks the log, and leaves screenshots in `build/e2e-android/`. Extend it with
each feature a PR adds; the widget tests in `test/` cover the logic on the
host with `FakeAppSource`. Anything that can only be checked on a real phone
(GrapheneOS, split screen) is said plainly in the PR.

Toolchain: Flutter from `.flutter-version`, JDK **17 or 21** (Gradle 8.14
rejects 25+).

## Layout

| Path | What |
| --- | --- |
| `lib/main.dart` | Starts the app with the Android app source |
| `lib/services/app_source.dart` | `AppEntry`, the `AppSource` interface, its Android and fake implementations |
| `lib/services/launcher_controller.dart` | App list and pairs, search results, launch counts, stats, the grid, settings, export and import, Home presses |
| `lib/services/app_pairs.dart` | `AppPair`: a saved pair is an app of its own, keyed `pair:<first>\|<second>` |
| `lib/services/settings_backup.dart` | The export file format (adapted from Quicklog's), validated before anything is written |
| `lib/services/fuzzy.dart` | The fzf-style scorer (greedy, word starts and runs score higher) |
| `lib/services/home_grid.dart` | Pure placement rules for the home grid and the automatic grid size |
| `lib/services/launcher_store.dart` | Settings and state in SharedPreferences |
| `lib/screens/` | Home screen (clock line, grid, results, search box, gestures), settings, stats |
| `packages/launcher_platform/` | Kotlin plugin: LauncherApps, icons and their disk cache, launching, package, profile and Home events, file dialogs, the accessibility service |

### Home grid rules

Cells are `(row, col)`. A placed app keeps its cell; only uninstalling it,
hiding it, "Remove from home", or shrinking the grid below its cell frees
the cell. Free cells go to the most-launched apps without one, bottom row
first, left to right, ties by key so phones agree. "Remove from home" keeps
the app off the grid until "Add to home". The automatic size is one column
per 80 dp and one row per 96 dp (more with bigger labels); settings can
override either. The grid ignores the size while the keyboard is open, so
typing never cuts cells.

Apps are identified everywhere by the key `package/activity#userSerial`.
User serials survive reboots, user handles do not; later phases store launch
counts and home slots under this key.

The widget tests run the real screens against `FakeAppSource`, an in-memory
app list, so most work needs no device.

## Android notes

* `MainActivity` is `singleTask` with the HOME category. A Home press while
  the launcher is in front arrives as `onNewIntent`; the plugin forwards it to
  Dart as the `home` event, which clears the search and pops settings.
* The Flutter surface is transparent and the themes set
  `windowShowWallpaper`, so the system wallpaper shows through.
* App visibility comes from a `<queries>` entry for MAIN/LAUNCHER, so
  `QUERY_ALL_PACKAGES` is not needed.
* The accessibility service `TurboLaunchAccessibilityService` is opt-in and
  only performs global actions: lock screen (double-tap on empty home
  space), notifications and split screen. It reads no window content.
* Swipe down (a fling, or a pull of at least 80 dp) uses the service's `GLOBAL_ACTION_NOTIFICATIONS` when it is on,
  else the hidden `StatusBarManager.expandNotificationsPanel` with
  `EXPAND_STATUS_BAR`; any failure is silent.
* Only empty cells listen for double-taps, because a double-tap detector
  holds single taps back for 300 ms; taps on apps stay instant.
* Icons are rendered once and kept as PNGs in the cache dir
  (`IconDiskCache`), named after the app's key and last update time.
* Work profile apps come from `LauncherApps.getProfiles()`; a paused profile
  still lists its apps, drawn grey, and starting one asks to resume work apps.
  Profile broadcasts (available, unavailable, added, removed) refresh the
  list. Secondary users each install and set up TurboLaunch on their own.
* Settings export and import use the system Create and Open document
  dialogs, so no storage permission.
* Cold start is measured from `Process.getStartElapsedRealtime()` to the
  first Flutter frame and shown in settings (and logged as
  `TurboLaunch cold start`); `TurboLaunch home ready` is the first frame with
  the apps. The Android e2e prints both, for the first start and for a
  restart with everything cached.

### Speed

What keeps it fast, and should stay that way:

* The app list from the last run is kept (`appSnapshot`), so a cold start
  draws the home grid on its first frame; the live list replaces it.
* The grid draws placed cells on the first frame, before the controller
  knows the size.
* Shortcuts load after the apps, never in front of them.
* Search folds each label once per app list, not per keystroke, and the
  scorer compares code units, not one-letter strings.
* The plugin remembers the activities `listApps` found, so icon and launch
  calls need no binder call to find the app again. An icon's cache stamp is
  its APK's file time (no binder call); a new system build empties the
  icon cache.

### App pairs

Settings saves a pair of a top and a bottom app; "Try it" opens one without
saving. A pair is an `AppEntry` of its own while both apps are installed, so
search, launch counts and the grid treat it like any app. Opening it starts
the first app, asks the accessibility service for
`GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN`, then starts the second app with
`FLAG_ACTIVITY_LAUNCH_ADJACENT`. Third-party launchers have no official
app-pair API, so this still needs checking on a GrapheneOS phone; the
emulator e2e does not cover it. The 600 ms pause between steps
(`PAIR_STEP_MILLIS`) is a first guess. Without the service only the first
app opens.

## Releasing

Releases follow Quicklog and the
[snonux/fdroid onboarding guide](https://github.com/snonux/fdroid/blob/main/docs/onboarding-flutter-app.md).
The traps that are easy to step on:

**Bump the build number.** `version:` in `pubspec.yaml` is
`<semver>+<counter>`. Forgetting to bump it means F-Droid reports "up to
date" and the release silently never ships.

**The per-ABI version code scheme is `counter * 10 + abi`** (1 armeabi-v7a,
2 arm64-v8a, 3 x86_64), set by the `applicationVariants` block at the bottom
of `android/app/build.gradle.kts`. Do not drop that block. CI checks the
codes of the built APKs; `test/version_test.dart` checks the pubspec line.

**Write the changelog three times**, one per ABI version code: for counter
`n`, `n1.txt`, `n2.txt` and `n3.txt` under
`fastlane/metadata/android/en-US/changelogs/` (counter 1 gives `11.txt`,
`12.txt`, `13.txt`). At most 500 characters each; the short description at
most 80 characters with no trailing period.

**Never remove the `dependenciesInfo` block** from
`android/app/build.gradle.kts`, or F-Droid's scanner rejects the APK.

**Release builds are path-sensitive**: build from `/tmp/build` against an
Android SDK at `/opt/android-sdk`, as Quicklog's AGENTS.md explains, so
official F-Droid can reproduce them byte for byte. The release workflow does
this.

**The signing key is the app's identity.** `android/key.properties` is
git-ignored and optional; without it release builds use the debug key and say
so. Keep the key at `keys/turbolaunch-release.jks` (git-ignored) and back it
and `key.properties` up in `~/.foostore-export/`.

### Signing and secrets (done)

The workflows live in `.github/workflows/` (an agent's token cannot write
there; Paul moves new ones). The release key and the four `ANDROID_*`
secrets are set up Quicklog-style, with the key in Paul's local foostore. An
agent never creates or replaces the key without Paul's OK.

A release is: bump `version:`, write the three changelogs, commit, `git tag
vX.Y.Z; and git push; and git push --tags`.

## Screenshots

The README screenshots in `docs/screenshots/` came from the former Linux
build, with demo apps and drawn stand-in icons, so they hold no personal data.
Phase 4 replaces them with shots taken on the Android emulator by script.

## Icons

`assets/logo/*.svg` are the sources (the speed T). The PNGs are rendered
from them, then the launcher icons regenerated:

```sh
python3 -c "import cairosvg as c; c.svg2png(url='assets/logo/logo.svg', write_to='logo.png', output_width=600, output_height=600)"
# likewise logo-foreground.svg -> assets/logo/foreground.png,
# logo-monochrome.svg -> assets/logo/monochrome.png (600 px),
# logo.svg -> logo-small.png (96 px) and fastlane/.../images/icon.png (512 px)
dart run flutter_launcher_icons
```

## Roadmap

From the plan, one PR per phase:

1. **Skeleton** (done): project layout, plugin, HOME activity that lists and
   launches apps, release workflow and signing, app-pair spike, cold start
   measured.
2. **Daily driver** (done): fuzzy search, home grid filled by launch count (cells
   never move once placed), hide, long-press menu, wallpapers, light and dark,
   font sizes, app shortcuts in search, quick hide.
3. **Profiles and polish** (this): work profile and multi-user, icon cache, settings
   export and import, stats screen, double-tap to lock, swipe for
   notifications, app pairs.
4. **Release**: first tag through snonux/fdroid, README and usage guide with
   screenshots and GIFs, fdroiddata merge request.
5. **S3 sync**: Quicklog's S3 client and retry code, per-device files,
   merged launch counts and shared cells.
