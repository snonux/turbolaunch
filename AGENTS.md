# Working on TurboLaunch

TurboLaunch is a Flutter app (Android only in production, Linux desktop for
development) that replaces the home screen. The stack and release process
follow [Quicklog](https://github.com/snonux/quicklog): Flutter for the UI and
logic, plus one small Kotlin plugin, `packages/launcher_platform`, for the
Android launcher APIs. The README is for people using the app; keep it short
and put build internals and conventions here.

Before calling anything done: `dart format`, `flutter analyze` and
`flutter test` must all be clean. For anything touching the Android build,
build a release APK too, `flutter build apk --release --split-per-abi`,
because the debug build hides signing and packaging problems. CI runs all of
this, plus the plugin's Kotlin unit tests, on every push.

Toolchain: Flutter from `.flutter-version`, JDK **17 or 21** (Gradle 8.14
rejects 25+).

## Layout

| Path | What |
| --- | --- |
| `lib/main.dart` | Picks the app source: Android, or a fake app list on Linux |
| `lib/services/app_source.dart` | `AppEntry`, the `AppSource` interface, its Android and fake implementations |
| `lib/services/launcher_controller.dart` | App list, search query, launching, Home presses |
| `lib/screens/` | Home screen and settings |
| `packages/launcher_platform/` | Kotlin plugin: LauncherApps, icons, launching, package and Home events, the accessibility service |

Apps are identified everywhere by the key `package/activity#userSerial`.
User serials survive reboots, user handles do not; later phases store launch
counts and home slots under this key.

The Linux build is the dev loop: `flutter run -d linux` shows the launcher
with a fixed list of fake apps (`FakeAppSource.demo()`), and the widget tests
use the same fake.

## Android notes

* `MainActivity` is `singleTask` with the HOME category. A Home press while
  the launcher is in front arrives as `onNewIntent`; the plugin forwards it to
  Dart as the `home` event, which clears the search and pops settings.
* The Flutter surface is transparent and the themes set
  `windowShowWallpaper`, so the system wallpaper shows through.
* App visibility comes from a `<queries>` entry for MAIN/LAUNCHER, so
  `QUERY_ALL_PACKAGES` is not needed.
* The accessibility service `TurboLaunchAccessibilityService` is opt-in and
  only performs global actions. It reads no window content.
* Cold start is measured from `Process.getStartElapsedRealtime()` to the
  first Flutter frame and shown in settings (and logged as
  `TurboLaunch cold start`).

### Phase 1 spike: app pairs

Settings has an "App pair test": pick a top and a bottom app and tap "Open
pair". It starts the first app, asks the accessibility service for
`GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN`, then starts the second app with
`FLAG_ACTIVITY_LAUNCH_ADJACENT`. Third-party launchers have no official
app-pair API, so this needs checking on a GrapheneOS phone before phase 3
builds app pairs on it. The 600 ms pause between steps
(`PAIR_STEP_MILLIS`) is a first guess. If it does not work, the fallback is
to open the first app and show Recents.

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

### One-time setup (Paul)

An agent's token cannot write `.github/workflows/`, so the release workflow
waits at `ci/workflows/release.yml`. Create the key, move the workflow and set
the secrets (fish):

```fish
mkdir -p keys
set pw (openssl rand -hex 16)
keytool -genkeypair -noprompt -keystore keys/turbolaunch-release.jks -storetype PKCS12 \
  -alias turbolaunch -keyalg RSA -keysize 4096 -validity 36500 \
  -dname "CN=TurboLaunch" -storepass $pw -keypass $pw
printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=turbolaunch\nkeyPassword=%s\n' \
  (realpath keys/turbolaunch-release.jks) $pw $pw > android/key.properties
chmod 600 keys/turbolaunch-release.jks android/key.properties
cp keys/turbolaunch-release.jks android/key.properties ~/.foostore-export/

git mv ci/workflows/release.yml .github/workflows/
git commit -m "Enable release workflow"; and git push

function get; sed -n "s/^$argv[1]=//p" android/key.properties; end
base64 -w0 (get storeFile) | gh secret set ANDROID_KEYSTORE
gh secret set ANDROID_KEY_ALIAS --body (get keyAlias)
gh secret set ANDROID_KEYSTORE_PASSWORD --body (get storePassword)
gh secret set ANDROID_KEY_PASSWORD --body (get keyPassword)
```

Optionally `gh secret set FDROID_DISPATCH_TOKEN` (Contents read/write on
snonux/fdroid) so a release shows up at once. Then a release is: bump
`version:`, write the three changelogs, commit, `git tag vX.Y.Z; and git push;
and git push --tags`.

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

1. **Skeleton** (this): project layout, plugin, HOME activity that lists and
   launches apps, release workflow and signing, app-pair spike, cold start
   measured.
2. **Daily driver**: fuzzy search, home grid filled by launch count (cells
   never move once placed), hide, long-press menu, wallpapers, light and dark,
   font sizes, app shortcuts in search, quick hide.
3. **Profiles and polish**: work profile and multi-user, icon cache, settings
   export and import, stats screen, double-tap to lock, swipe for
   notifications, app pairs.
4. **Release**: first tag through snonux/fdroid, README and usage guide with
   screenshots and GIFs, fdroiddata merge request.
5. **S3 sync**: Quicklog's S3 client and retry code, per-device files,
   merged launch counts and shared cells.
