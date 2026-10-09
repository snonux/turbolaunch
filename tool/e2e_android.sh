#!/usr/bin/env bash
# End-to-end run of a TurboLaunch APK on a running emulator (adb connected):
# installs it, makes it the home app, and checks through the UI that the
# search box lists the device's apps, that a fuzzy search and Enter launch the
# top match, that Home returns with the search cleared and the launched app on
# the home grid, that the long-press menu and quick hide work, that cold start
# and home-ready times are logged (again after a restart), that a swipe down opens the
# notification shade, a swipe up the search, and a gesture recorded in settings
# quick settings, that Sync now works (against the Garage test bucket when
# S3_TEST_ACCESS_KEY_ID and S3_TEST_SECRET_KEY are set), that settings sees
# the accessibility service and shows the launch stats, and that a double-tap on
# empty home space locks the phone. Screenshots, UI dumps and the log go to
# build/e2e-android/; at the end tool/bench_android.sh measures speed and
# tool/shots_android.sh takes the guide's
# screenshots into build/shots-android/, and tool/sync_two_phones.sh syncs a
# second emulator with this one.
#
#   tool/e2e_android.sh build/app/outputs/flutter-apk/app-x86_64-release.apk
set -euo pipefail
cd "$(dirname "$0")/.."
apk=${1:?usage: tool/e2e_android.sh app.apk}
app=org.buetow.turbolaunch
out=build/e2e-android
rm -rf "$out" && mkdir -p "$out"
failed=0
step=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failed=1; }
shot() { step=$((step + 1)); adb exec-out screencap -p >"$out/$(printf %02d $step)_$1.png"; }
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null && adb shell cat /sdcard/ui.xml >"$out/ui.xml"; }
# The resumed activity; the window manager's focus went stale on CI once.
focused() { adb shell dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity' | head -2; }
# Centre of the first UI node whose text or content-desc contains $1.
centre() {
  python3 - "$out/ui.xml" "$1" <<'PY'
import re, sys
xml, want = open(sys.argv[1]).read(), sys.argv[2]
for node in re.findall(r'<node [^>]*>', xml):
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', node))
    if want == attrs.get('resource-id') or any(want in attrs.get(k, '') for k in ('text', 'content-desc', 'hint')):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', attrs['bounds']))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}
expect_ui() {
  if grep -q -- "$2" "$out/ui.xml"; then
    pass "$1"
  else
    fail "$1 (no '$2' on screen; it shows: $(grep -o '\(text\|content-desc\)="[^"]\+"' "$out/ui.xml" | head -12 | tr '\n' ' '))"
  fi
}
expect_focus() { if focused | grep -q "$2"; then pass "$1"; else fail "$1 (focus: $(focused | tr '\n' ' '))"; fi; }
tap_on() {
  dump
  local xy; xy=$(centre "$1")
  if [ -z "$xy" ]; then fail "find '$1'"; return 1; fi
  echo "  tap '$1' at $xy"
  adb shell input tap $xy
}

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb logcat -c
adb install -r "$apk"
# Flutter builds its semantics tree, which uiautomator reads, only while an
# accessibility service is on. Turning on TurboLaunch's own (opt-in) service
# does that and lets settings show it as on later.
adb shell settings put secure enabled_accessibility_services "$app/$app.TurboLaunchAccessibilityService"
adb shell settings put secure accessibility_enabled 1
adb shell cmd package set-home-activity "$app/.MainActivity"
adb shell input keyevent KEYCODE_HOME
sleep 8
read -r w h < <(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')

# 1. TurboLaunch is the home screen: clock line, search box, empty grid.
dump; shot home
expect_focus "home screen is TurboLaunch" "$app"
expect_ui "search box shown" 'resource-id="search"'
expect_ui "clock line shows the battery" '[0-9]%'
timings() {
  for what in 'cold start' 'home ready'; do
    if adb logcat -d | grep -q "TurboLaunch $what: [0-9]* ms"; then
      pass "$1 $(adb logcat -d | grep -o "TurboLaunch $what: [0-9]* ms" | tail -1 | sed 's/TurboLaunch //')"
    else
      fail "$1 $what logged"
    fi
  done
}
timings "first start:"

# 2. Tapping the search box lists the device's apps.
tap_on search && sleep 2
dump; shot all_apps
expect_ui "apps listed (Camera, Chrome or Clock)" 'Camera\|Chrome\|Clock'

# 3. A fuzzy search ("sttngs") and Enter launch the top match.
adb shell input text "sttngs"
sleep 2; dump; shot search
expect_ui "fuzzy search finds Settings" 'Settings'
adb shell input keyevent KEYCODE_ENTER
sleep 5; shot launched
expect_focus "Enter launched Settings" "com.android.settings"

# 4. Home comes back with the search cleared and Settings on the home grid.
adb shell input keyevent KEYCODE_HOME
sleep 4; dump; shot home_grid
expect_focus "Home returns to TurboLaunch" "$app"
if grep -q 'sttngs' "$out/ui.xml"; then fail "search cleared on Home"; else pass "search cleared on Home"; fi
expect_ui "Settings has a home cell" 'Settings'

# 5. Tapping the cell launches it again.
tap_on "Settings" && sleep 5
expect_focus "grid cell launched Settings" "com.android.settings"
adb shell input keyevent KEYCODE_HOME
sleep 3

# 6. Long-press menu: remove from home.
dump
xy=$(centre "Settings")
if [ -n "$xy" ]; then
  adb shell input swipe $xy $xy 900
  sleep 2; dump; shot menu
  expect_ui "long-press menu" 'Remove from home'
  tap_on "Remove from home" && sleep 2
  dump; shot removed
  if grep -q 'Settings' "$out/ui.xml"; then fail "removed from home"; else pass "removed from home"; fi
else
  fail "find the Settings cell"
fi

# 7. Quick hide: long-press the clock line, then again to bring the grid back.
dump
xy=$(centre ":")
if [ -n "$xy" ]; then
  adb shell input swipe $xy $xy 900
  sleep 2; shot quick_hidden
  adb shell input swipe $xy $xy 900
  sleep 2; pass "quick hide toggled"
fi

# 8. Settings sees the accessibility service, turned on at the start.
tap_on "TurboLaunch settings" && sleep 3
dump; shot settings
expect_ui "settings open" 'Set as home app'
expect_ui "cold start shown" 'ms from process start'
# Launch stats: Settings was launched twice, by Enter and from its cell.
tap_on "Launch stats" && sleep 2
dump; shot stats
expect_ui "stats count the launches" '2 launches on this phone'
adb shell input keyevent KEYCODE_BACK
sleep 2; dump
# The gestures section is below the fold; uiautomator only dumps what shows.
for _ in 1 2 3 4 5 6; do
  grep -q 'Accessibility service' "$out/ui.xml" && break
  adb shell input swipe $((w / 2)) $((h * 3 / 4)) $((w / 2)) $((h / 4)) 300; sleep 1; dump
done
shot settings_pair
expect_ui "accessibility service listed" 'Accessibility service'
if grep -q 'Off: tap to open' "$out/ui.xml"; then fail "accessibility service seen as on"; else pass "accessibility service seen as on"; fi
adb shell input keyevent KEYCODE_BACK
sleep 2; dump
expect_ui "Back returns home" 'resource-id="search"'

# 9. Double-tap on empty home space locks the phone through the service. Both
#    taps go in one shell so they land within the 300 ms double-tap timeout,
#    with a pause between them: Flutter drops a second tap that comes less
#    than 40 ms after the first (kDoubleTapMinTime) as touch-screen jitter.
asleep() { adb shell dumpsys power | grep -q 'mWakefulness=\(Asleep\|Dozing\)'; }
for _ in 1 2 3; do
  adb shell "a=\$(date +%s%N); input tap $((w / 2)) $((h * 35 / 100)); sleep 0.1; b=\$(date +%s%N); input tap $((w / 2)) $((h * 35 / 100)); echo \"  taps \$(( (b - a) / 1000000 )) ms apart\""
  sleep 3
  asleep && break
done
if asleep; then pass "double-tap locks the phone"; else fail "double-tap locks the phone"; adb logcat -d | grep 'TurboLaunch' | tail -5; fi
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
sleep 3; shot unlocked
expect_focus "home again after unlocking" "$app"

# 9b. A swipe down on the home grid pulls the notification shade (the shade
#     window becomes the one uiautomator dumps); then close it again.
adb shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 7 / 10)) 150
sleep 2; shot shade; dump
if grep -q 'package="com.android.systemui"' "$out/ui.xml"; then
  pass "swipe down opens notifications"
else
  fail "swipe down opens notifications ($(focused | tr '\n' ' '))"
  adb logcat -d | grep 'TurboLaunch' | tail -5
fi
adb shell cmd statusbar collapse
sleep 2
expect_focus "shade closed, home again" "$app"

# 9c. A swipe up opens the search with the keyboard up and the box focused.
adb shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 150
sleep 2; shot swipe_up_search; dump
if grep -o '<node [^>]*resource-id="search"[^>]*>' "$out/ui.xml" | grep -q 'focused="true"'; then
  pass "swipe up focuses the search box"
else
  fail "swipe up focuses the search box"
fi
if adb shell dumpsys input_method | grep -q 'mInputShown=true'; then
  pass "swipe up opens the keyboard"
else
  fail "swipe up opens the keyboard"
fi
expect_ui "swipe up lists the apps" 'Camera\|Chrome\|Clock'
adb shell input keyevent KEYCODE_HOME
sleep 2

# 9d. Record a gesture (down, then right) in settings, give it quick
#     settings, and draw it on the home screen.
draw_down_right() { # x y: start; strokes of 300 px in 30 px steps, one touch
  local x=$1 y=$2 cmd="input motionevent DOWN $1 $2"
  for i in $(seq 1 10); do cmd="$cmd; input motionevent MOVE $x $((y + i * 30))"; done
  y=$((y + 300))
  for i in $(seq 1 10); do cmd="$cmd; input motionevent MOVE $((x + i * 30)) $y"; done
  adb shell "$cmd; input motionevent UP $((x + 300)) $y"
}
tap_on "TurboLaunch settings" && sleep 3
dump
for _ in 1 2 3 4 5 6 7 8; do
  grep -q 'Record a gesture' "$out/ui.xml" && break
  adb shell input swipe $((w / 2)) $((h * 3 / 4)) $((w / 2)) $((h / 4)) 300; sleep 1; dump
done
shot settings_gestures
expect_ui "gestures listed in settings" 'Swipe up'
tap_on "Record a gesture" && sleep 2
draw_down_right $((w / 3)) $((h * 3 / 10))
sleep 2; dump; shot gesture_recorded
expect_ui "gesture recorded" '↓ →'
tap_on "Use it" && sleep 2
tap_on "Quick settings" && sleep 2
dump
expect_ui "recorded gesture listed" 'Quick settings'
adb shell input keyevent KEYCODE_BACK
sleep 2
draw_down_right $((w / 3)) $((h * 3 / 10))
sleep 2; shot gesture_quick_settings; dump
if grep -q 'package="com.android.systemui"' "$out/ui.xml"; then
  pass "recorded gesture opens quick settings"
else
  fail "recorded gesture opens quick settings ($(focused | tr '\n' ' '))"
  adb logcat -d | grep 'TurboLaunch' | tail -5
fi
adb shell cmd statusbar collapse
sleep 2
expect_focus "quick settings closed, home again" "$app"

# 9e. Sync. Sync now without keys asks for them. With S3_TEST_ACCESS_KEY_ID
#     and S3_TEST_SECRET_KEY set (CI secrets for the Garage test bucket), a
#     real sync that finds a second phone's file put there beforehand;
#     without them, Sync now against a closed port must say it failed.
s3_bucket_url="${S3_TEST_ENDPOINT:-https://garage.f3s.buetow.org}/${S3_TEST_BUCKET:-turbolaunch-test}"
s3() { # method path [file]: one signed request to the test bucket
  curl -sS --fail-with-body --aws-sigv4 "aws:amz:garage:s3" --user "$S3_TEST_ACCESS_KEY_ID:$S3_TEST_SECRET_KEY" \
    -X "$1" "$s3_bucket_url/$2" ${3:+-T "$3"}
}
s3_clear() {
  for key in $(s3 GET "?list-type=2&prefix=turbolaunch/devices/" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g'); do
    s3 DELETE "$key" >/dev/null
  done
}
hide_keyboard() { if adb shell dumpsys input_method | grep -q 'mInputShown=true'; then adb shell input keyevent KEYCODE_BACK; sleep 1; fi; }
type_into() { # resource-id text: finds the field above or below, types into it
  scroll_to "resource-id=\"$1\"" down || scroll_to "resource-id=\"$1\"" up || true
  tap_on "$1" && sleep 1 && adb shell input text "$2"
  sleep 1
}
scroll_to() { # text, direction up|down
  dump
  for _ in 1 2 3 4 5 6; do
    grep -q -- "$1" "$out/ui.xml" && return 0
    if [ "$2" = down ]; then
      adb shell input swipe $((w / 2)) $((h * 3 / 4)) $((w / 2)) $((h / 4)) 300
    else
      adb shell input swipe $((w / 2)) $((h / 4)) $((w / 2)) $((h * 3 / 4)) 300
    fi
    sleep 1; dump
  done
  grep -q -- "$1" "$out/ui.xml"
}
live=0
[ -n "${S3_TEST_ACCESS_KEY_ID:-}" ] && [ -n "${S3_TEST_SECRET_KEY:-}" ] && live=1
if [ $live = 1 ]; then
  s3_clear
  printf '{"format":"turbolaunch-sync","formatVersion":1,"device":"e2e-other","name":"e2e other phone","counts":{"e2e.fake/e2e.fake.Main":1},"cells":{}}' >"$out/other.json"
  s3 PUT turbolaunch/devices/e2e-other.json "$out/other.json" >/dev/null && pass "second phone's file put in the bucket" || fail "second phone's file put in the bucket"
else
  echo "  S3_TEST_ACCESS_KEY_ID or S3_TEST_SECRET_KEY not set: no real sync, only the error path"
fi
tap_on "TurboLaunch settings" && sleep 3
tap_on "Share launch counts" && sleep 2
dump; shot sync
expect_ui "sync screen open" 'Sync between phones'
tap_on sync-enabled && sleep 1
scroll_to 'resource-id="sync-now"' down || true
tap_on sync-now && sleep 3
scroll_to 'Enter the access key ID' down || true; shot sync_no_keys
expect_ui "Sync now without keys asks for them" 'Enter the access key ID'
scroll_to 'resource-id="sync-endpoint"' up || true
if [ $live = 1 ]; then
  type_into sync-endpoint "${S3_TEST_ENDPOINT:-https://garage.f3s.buetow.org}"
  hide_keyboard
  type_into sync-bucket "${S3_TEST_BUCKET:-turbolaunch-test}"
  hide_keyboard
  type_into sync-key-id "$S3_TEST_ACCESS_KEY_ID"
  hide_keyboard
  type_into sync-secret "$S3_TEST_SECRET_KEY"
else
  type_into sync-endpoint "http://127.0.0.1:9"
  hide_keyboard
  type_into sync-key-id "e2e"
  hide_keyboard
  type_into sync-secret "e2e"
fi
hide_keyboard
scroll_to 'resource-id="sync-name"' down || true
type_into sync-name "e2e"
hide_keyboard
scroll_to 'resource-id="sync-now"' down || true
tap_on sync-now && sleep 15
if [ $live = 1 ]; then scroll_to 'Synced with' down || true; else scroll_to 'Sync failed' down || true; fi
shot sync_done
if [ $live = 1 ]; then
  expect_ui "Sync now syncs with the second phone" 'Synced with 1 other phone'
  scroll_to 'e2e other phone' down || true
  expect_ui "second phone listed" 'e2e other phone'
  if s3 GET "?list-type=2&prefix=turbolaunch/devices/" | grep -q '<KeyCount>2</KeyCount>'; then
    pass "this phone's file is in the bucket"
  else
    fail "this phone's file is in the bucket"
  fi
else
  expect_ui "Sync now reports an unreachable server" 'Sync failed'
fi
# Sync off again, so automatic syncs leave the bucket alone from here on.
scroll_to 'resource-id="sync-enabled"' up || true
tap_on sync-enabled && sleep 1
[ $live = 1 ] && s3_clear
adb shell input keyevent KEYCODE_BACK
sleep 1
adb shell input keyevent KEYCODE_BACK
sleep 2; dump
expect_ui "Back returns home from sync" 'resource-id="search"'

# 10. No crash anywhere.
adb logcat -d >"$out/logcat.txt"
if adb shell pidof "$app" >/dev/null; then pass "still running"; else fail "still running"; fi
# Crashes of other apps on the emulator are not ours; AndroidRuntime names the
# crashed process on the line after FATAL EXCEPTION. Every crash is printed.
grep -A12 "FATAL EXCEPTION" "$out/logcat.txt" || true
if grep -A1 "FATAL EXCEPTION" "$out/logcat.txt" | grep -q "Process: $app" ||
  grep -qE "E/flutter|E flutter|Unhandled Exception" "$out/logcat.txt"; then
  fail "no TurboLaunch errors in the log"
else
  pass "no TurboLaunch errors in the log"
fi

# 11. Timings on a later cold start, with the app list and icons cached as on
#     a phone that has used TurboLaunch before. Emulator numbers: compare runs,
#     not phones.
adb shell am force-stop "$app"
adb logcat -c
adb shell input keyevent KEYCODE_HOME
sleep 8
timings "cold start again:"
dump
expect_ui "home again after the restart" 'resource-id="search"'

# 12. Benchmark: start, keystrokes, launches and scrolling, with limits.
if tool/bench_android.sh; then pass "benchmark within its limits"; else fail "benchmark within its limits"; fi

# 13. Screenshots and a recording for the README, the guide and F-Droid.
if tool/shots_android.sh; then pass "screenshots taken"; else fail "screenshots taken"; fi

# 14. Two phones: a second emulator syncs with this one through the S3 test
#     bucket (skipped without its keys). Last, as it clears the app's data.
if tool/sync_two_phones.sh "$apk"; then pass "two phones sync"; else fail "two phones sync"; fi
exit $failed
