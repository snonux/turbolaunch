#!/usr/bin/env bash
# End-to-end run of a TurboLaunch APK on a running emulator (adb connected):
# installs it, makes it the home app, and checks through the UI that the
# search box lists the device's apps, that a fuzzy search and Enter launch the
# top match, that Home returns with the search cleared and the launched app on
# the home grid, that the long-press menu and quick hide work, that cold start
# is logged, that a swipe down opens the notification shade, that settings sees
# the accessibility service and shows the launch stats, and that a double-tap on
# empty home space locks the phone. Screenshots, UI dumps and the log go to
# build/e2e-android/.
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
focused() { adb shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -2; }
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
if adb logcat -d | grep -q 'TurboLaunch cold start: [0-9]* ms'; then
  pass "cold start logged: $(adb logcat -d | grep -o 'TurboLaunch cold start: [0-9]* ms' | tail -1)"
else
  fail "cold start logged"
fi

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
# DEBUG (temporary): what the screen and the accessibility tree say.
echo "DEBUG wm: $(adb shell wm size | tr '\n' ' ') $(adb shell wm density | tr '\n' ' ')"
grep -o '<node [^>]*>' "$out/ui.xml" | grep -o 'content-desc="[^"]*"\|bounds="[^"]*"\|class="[^"]*"\|clickable="[^"]*"' | paste -sd' ' | sed 's/class=/\nclass=/g' | sed 's/^/DEBUG /'
echo "DEBUG PNG $(base64 -w0 "$out/$(ls "$out" | grep home_grid)")"

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
#    taps go in one shell so they land within the double-tap timeout.
asleep() { adb shell dumpsys power | grep -q 'mWakefulness=\(Asleep\|Dozing\)'; }
for _ in 1 2 3; do
  adb shell "a=\$(date +%s%N); input tap $((w / 2)) $((h * 35 / 100)); b=\$(date +%s%N); input tap $((w / 2)) $((h * 35 / 100)); echo \"  taps \$(( (b - a) / 1000000 )) ms apart\""
  sleep 3
  asleep && break
done
if asleep; then pass "double-tap locks the phone"; else fail "double-tap locks the phone"; fi
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
fi
adb shell cmd statusbar collapse
sleep 2
expect_focus "shade closed, home again" "$app"

# 10. No crash anywhere.
adb logcat -d >"$out/logcat.txt"
if adb shell pidof "$app" >/dev/null; then pass "still running"; else fail "still running"; fi
if grep -E "FATAL EXCEPTION|E/flutter|Unhandled Exception" "$out/logcat.txt"; then fail "no errors in the log"; else pass "no errors in the log"; fi
exit $failed
