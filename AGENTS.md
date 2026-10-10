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
| `lib/services/launcher_controller.dart` | App list and pairs, search results, launch counts, stats, the grid, settings, export and import, Home presses, sync runs |
| `lib/services/app_pairs.dart` | `AppPair`: a saved pair is an app of its own, keyed `pair:<first>\|<second>` |
| `lib/services/settings_backup.dart` | The export file format (adapted from Quicklog's), validated before anything is written |
| `lib/services/fuzzy.dart` | The fzf-style scorer (greedy, word starts and runs score higher) |
| `lib/services/gestures.dart` | Swipe gestures: the stroke recognizer and the actions a gesture can run |
| `lib/services/home_grid.dart` | Pure placement rules for the home grid and the automatic grid size |
| `lib/services/launcher_store.dart` | Settings and state in SharedPreferences |
| `lib/services/sync.dart` | S3 sync: the per-phone file, sync keys, shared cells |
| `lib/services/s3_config.dart`, `s3_object_client.dart` | Copied from Quicklog (only the default bucket differs); keep them in step |
| `lib/screens/` | Home screen (clock line, grid, results, search box, gestures), settings, stats, sync |
| `packages/launcher_platform/` | Kotlin plugin: LauncherApps, icons and their disk cache, launching, package, profile and Home events, file dialogs, the accessibility service |

### Home grid rules

By default (`autoArrange`, Paul, 2026-10-10) the grid is arranged by
launches (`arrangeHome`): the most-launched app bottom right, then
leftwards, then the row above, ties by sync key so phones agree. With sync
it ranks by the summed counts, and an app the other phones show in a cell
but this phone lacks keeps its ranked cell as a ghost. Apps with no
launches put there by "Add to home" come after the ranked ones. Icons move
only while the home screen is not in front (`setInFront`, from the app
lifecycle) or on a Home press, never under a finger; until then a pass only
drops apps that left the grid.

With the setting off: a placed app keeps its cell; only uninstalling it,
hiding it, "Remove from home", or shrinking the grid below its cell frees
the cell. Free cells go to the most-launched apps without one, bottom row
first, left to right, ties by key so phones agree. "Remove from home" keeps
the app off the grid until "Add to home". The automatic size is one column
per 80 dp and one row per 96 dp (more with bigger labels); settings can
override either. The grid ignores the size while the keyboard is open, so
typing never cuts cells.

Each grid size keeps its own cells (`homeLayouts`, by `rowsxcols`):
rotating the screen changes the size, and turning back brings back that
size's cells as they were. A size the grid never had is arranged afresh.
"Add to home", an import, taking over another phone's grid and turning
"Arrange by launches" on or off forget the other sizes' cells.

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
* Swipes on the home area are gestures (`Gestures.recognize`): a chain of
  straight strokes coded `U`, `D`, `L`, `R`, e.g. `UR` for up then right.
  A plain swipe needs 80 dp or a fling; a stroke in a chain needs 40 dp.
  Settings map codes to actions (`gestures` in the settings JSON); the
  defaults are up for search and down for notifications. Settings from
  before gestures with `swipeNotifications: false` keep swipe down off.
* Notifications and quick settings use the service's global action when it
  is on, else the hidden `StatusBarManager.expandNotificationsPanel` or
  `expandSettingsPanel` with `EXPAND_STATUS_BAR`; any failure is silent.
  Recents, power menu, screenshot and split screen need the service. The
  flashlight uses `CameraManager.setTorchMode` (no permission); its torch
  callback is registered on the first toggle, not at start.
* `ScreenshotTileService` is a quick settings tile: it closes the shade
  (`GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE`, else the hidden
  `collapsePanels`), waits `SHADE_CLOSE_MILLIS` and asks the service for
  `GLOBAL_ACTION_TAKE_SCREENSHOT`, so it shoots whatever app is open. With
  the service off it opens the accessibility settings. The e2e adds and
  clicks it with `cmd statusbar add-tile` and `click-tile`.
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

### S3 sync

Quicklog's S3 client (`minio`, path-style, plain objects, no encryption of
our own). Each phone writes `turbolaunch/devices/<device id>.json` with its
own launch counts and home cells, and reads the others; nothing is merged
into one shared file, so phones never overwrite each other. The device id
is random, made on first use and never exported.

* Apps are matched across phones by sync key: the app key without the user
  serial, plus `#work` for another profile; pairs map both halves.
* Cells in the file count rows from the bottom.
* Counts are summed (`totals`); `counts` stays this phone's own.
* Arranged by launches (the default), every phone ranks by the summed
  counts, so the grids match without taking anything over; an app missing
  here keeps its ranked cell as a ghost. The rest of this list applies with
  the setting off.
* The first sync that finds other phones takes over the grid of the phone
  with the most launches, if that is another one (Paul, 2026-10-09). After
  that `placeHome` keeps placed icons; an unplaced app goes to its shared
  cell (the busiest phone wins disagreements) and a shared cell whose app is
  missing here shows a ghost (Paul, 2026-10-10): the app's name in a faded
  outline, taken from the `labels` in the other phone's file. A phone never
  writes its ghosts into its own file. Only when every other cell is taken
  does a local app borrow a ghost cell (Paul, 2026-10-10), kept in `lent`
  and given back when the ghost's app is installed; the borrower is drawn
  at 55 % opacity so it stands out. Cells lent by 0.2.0
  (which lent even with free cells) are placed again on the first start.
* Automatic syncs (5 s after start, 30 s after a launch, on Home after
  15 min) fail silently; only Sync now shows errors.
* With sync on, an import leaves the launch counts out (they would count
  twice).

`test/sync_test.dart` covers this with an in-memory bucket.
`test/s3_live_test.dart` runs three phones against a real bucket when
`S3_TEST_ACCESS_KEY_ID` and `S3_TEST_SECRET_KEY` are set (Paul's Garage
test bucket `turbolaunch-test`); the Android e2e does Sync now against it
with the same variables, and without them only checks that Sync now
reports an unreachable server.
`tool/sync_two_phones.sh`, run at the end of the e2e, boots a second
emulator (AVD `phone-b`, made from the first one's system image, port
5556) and checks two phones end to end: the phone with fewer launches takes over the other's grid
(same cells on screen), the other keeps its own and gets the new app in the
shared cell, both stats screens show the summed counts, and a disabled
Clock leaves a ghost in its cell on phone B and takes it back when enabled.

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

A release is: bump `version:`, write the three changelogs, commit and push
to main, then tag `vX.Y.Z`. A pushed tag starts the release workflow; an
agent, which cannot push tags, runs the workflow by hand with the tag
instead, and it creates the tag on the current commit after checking it
matches `version:` in `pubspec.yaml`.

## Screenshots

`tool/shots_android.sh` takes the screenshots and the recording in
`docs/guide/images/` (and F-Droid's `phoneScreenshots/`) on the emulator,
with its own apps only, so they hold no personal data. The Android e2e runs
it at its end, into `build/shots-android/`. CI artifacts cannot be reached
from the cloud container, so to refresh the shots from there, push a
temporary `export SHOTS_TO_LOG=1` near the top of `tool/e2e_android.sh`: it prints each file base64-encoded
between `=== SHOT name` and `=== END` lines at the tail of the job log.
The PNGs go to `docs/guide/images/` and, as `1.png` to `5.png` (home,
search, menu, settings, stats), to F-Droid's `phoneScreenshots/`. The GIF is made
from `search.mp4`:

```sh
ffmpeg -ss 2.2 -i search.mp4 -vf "fps=10,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" docs/guide/images/search.gif
```

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
3. **Profiles and polish** (done): work profile and multi-user, icon cache, settings
   export and import, stats screen, double-tap to lock, swipe for
   notifications, app pairs.
4. **Release** (done): first tag through snonux/fdroid, README and usage guide with
   screenshots and GIFs, fdroiddata merge request.
5. **S3 sync** (done): Quicklog's S3 client, per-device files, summed
   launch counts and shared cells, ghosts for apps a phone lacks.
