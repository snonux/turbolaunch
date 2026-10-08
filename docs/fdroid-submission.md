# Publishing TurboLaunch on F-Droid

TurboLaunch reaches phones two ways, as Quicklog does:

1. **The snonux F-Droid repository** (<https://github.com/snonux/fdroid>)
   serves the signed APKs that `.github/workflows/release.yml` attaches to
   each GitHub release. Registering the app there is a one-time change in
   that repo (below).
2. **Official F-Droid** builds the app itself from a tag with the recipe in
   [`fdroid/org.buetow.turbolaunch.yml`](fdroid/org.buetow.turbolaunch.yml)
   and, because the build is reproducible, ships our signed APKs. That
   needs a merge request to `fdroiddata` on GitLab, a manual step.

Quicklog's [`docs/fdroid-submission.md`](https://github.com/snonux/quicklog/blob/main/docs/fdroid-submission.md)
explains every detail of the recipe (the `/tmp/build` path, `scandelete`,
the JDK, the order of the build blocks); it applies here unchanged. Only
what differs or needs doing for TurboLaunch is below.

## What is in place

| Requirement | Where |
| --- | --- |
| FOSS licence | [`LICENSE`](../LICENSE), MIT |
| No proprietary dependencies | Flutter, `shared_preferences` and the in-repo `launcher_platform` plugin. No Google Play Services, analytics or network use; the app has no `INTERNET` permission. |
| Tag matches `versionName` | tag `vX.Y.Z` and `version: X.Y.Z+<counter>` in `pubspec.yaml`, checked by the release workflow |
| Version codes `counter * 10 + abi` | the `applicationVariants` block in `android/app/build.gradle.kts`, `VercodeOperation` in the recipe, `test/version_test.dart` and the CI APK job |
| Pinned Flutter SDK | [`.flutter-version`](../.flutter-version), read by the recipe |
| Store text, icon, screenshots, changelogs | `fastlane/metadata/android/en-US/` |

## Cutting a release

1. Bump `version:` in `pubspec.yaml`, both halves.
2. Write the changelog (at most 500 characters) for counter `n` as
   `n1.txt`, `n2.txt` and `n3.txt` in
   `fastlane/metadata/android/en-US/changelogs/`.
3. `dart format`, `flutter analyze`, `flutter test`, and a green Android
   e2e in CI.
4. Commit, then `git tag vX.Y.Z; and git push; and git push --tags`.
   The release workflow builds and signs the three APKs and attaches them
   to the GitHub release; snonux/fdroid picks them up.
5. Once official F-Droid has the app, `AutoUpdateMode: Version` finds new
   tags on its own.

## Registering in snonux/fdroid

`apps.yml`, under `apps:`:

```yaml
  - id: org.buetow.turbolaunch
    github: snonux/turbolaunch
    assets: '^app-.*-release\.apk$'
    fastlane: fastlane/metadata/android
```

`fdroid/metadata/org.buetow.turbolaunch.yml`:

```yaml
# Store text, icon, screenshots and changelogs come from the app repo's
# fastlane/ dir, synced into metadata/org.buetow.turbolaunch/ by scripts/sync_apps.py.
Categories:
  - System
  - Theming
License: MIT
AuthorName: Paul Buetow
AuthorWebSite: https://foo.zone
SourceCode: https://github.com/snonux/turbolaunch
IssueTracker: https://github.com/snonux/turbolaunch/issues
Changelog: https://github.com/snonux/turbolaunch/releases

AutoName: TurboLaunch
```

And TurboLaunch in the README's list of apps.

## Before the fdroiddata merge request

The recipe names the `v0.1.0` release: `commit:` is the full hash of the
tagged commit (`git rev-parse v0.1.0^{commit}`), and
`AllowedAPKSigningKeys:` the SHA-256 of the release certificate
(`d35952b4…`, CN=TurboLaunch), which the release workflow's "Signed with
the release key" step prints. For a later first submission, update the
build blocks and `CurrentVersion*` to that release.

Then follow Quicklog's "Submitting to fdroiddata": fork, copy the recipe to
`metadata/org.buetow.turbolaunch.yml`, `fdroid lint`, `fdroid rewritemeta`
(it reorders fields and drops comments; fdroiddata's CI fails on any diff
it would make), push and open the merge request.

## Things reviewers are likely to ask about

**The accessibility service.** "TurboLaunch actions" is opt-in and only
performs three global actions: lock screen, notifications and split
screen. It sets `canRetrieveWindowContent="false"` and listens only for
announcements, so it reads no window content
(`packages/launcher_platform/android/src/main/res/xml/turbolaunch_accessibility.xml`).
Worth saying up front in the merge request.

**`EXPAND_STATUS_BAR`** is a normal permission, used only for swipe down
when the accessibility service is off. **`REQUEST_DELETE_PACKAGES`** lets
the app menu ask Android to uninstall an app; Android still asks the user.

**Package visibility** comes from a `<queries>` entry for MAIN/LAUNCHER,
so there is no `QUERY_ALL_PACKAGES`.
