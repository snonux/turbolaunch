#!/usr/bin/env bash
# End-to-end run of a TurboLaunch APK on a running emulator (adb connected):
# installs it, makes it the home app, and checks through the UI that it lists
# apps, that typing a search and Enter launches the top match, that Home
# returns to it with the search cleared, that cold start is logged, and that
# settings sees the accessibility service once it is turned on. Screenshots,
# UI dumps and the log go to build/e2e-android/.
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
    if want in attrs.get('text', '') or want in attrs.get('content-desc', '') or want in attrs.get('hint', ''):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', attrs['bounds']))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}
expect_ui() { if grep -q -- "$2" "$out/ui.xml"; then pass "$1"; else fail "$1 (no '$2' on screen)"; fi; }
expect_focus() { if focused | grep -q "$2"; then pass "$1"; else fail "$1 (focus: $(focused | tr '\n' ' '))"; fi; }
tap_on() {
  dump
  local xy; xy=$(centre "$1")
  if [ -z "$xy" ]; then fail "find '$1'"; return 1; fi
  adb shell input tap $xy
}

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb logcat -c
adb install -r "$apk"
adb shell cmd package set-home-activity "$app/.MainActivity"
adb shell input keyevent KEYCODE_HOME
sleep 8

# 1. TurboLaunch is the home screen and lists the device's apps.
dump; shot home
expect_focus "home screen is TurboLaunch" "$app"
expect_ui "search box shown" "Search apps"
expect_ui "apps listed (Settings)" 'Settings'
expect_ui "apps listed (Camera, Chrome or Clock)" 'Camera\|Chrome\|Clock'
if adb logcat -d | grep -q 'TurboLaunch cold start: [0-9]* ms'; then
  pass "cold start logged: $(adb logcat -d | grep -o 'TurboLaunch cold start: [0-9]* ms' | tail -1)"
else
  fail "cold start logged"
fi

# 2. Typing a search and Enter launches the top match.
tap_on "Search apps" && sleep 2
adb shell input text "sett"
sleep 2; dump; shot search
expect_ui "search narrows the list" 'Settings'
adb shell input keyevent KEYCODE_ENTER
sleep 5; shot launched
expect_focus "Enter launched Settings" "com.android.settings"

# 3. Home comes back to TurboLaunch with the search cleared.
adb shell input keyevent KEYCODE_HOME
sleep 4; dump; shot home_again
expect_focus "Home returns to TurboLaunch" "$app"
if grep -q 'sett' "$out/ui.xml"; then fail "search cleared on Home"; else pass "search cleared on Home"; fi

# 4. Settings sees the accessibility service once it is turned on.
adb shell settings put secure enabled_accessibility_services "$app/$app.TurboLaunchAccessibilityService"
adb shell settings put secure accessibility_enabled 1
sleep 3
tap_on "TurboLaunch settings" && sleep 3
dump; shot settings
expect_ui "settings open" 'Set as home app'
expect_ui "accessibility service seen as on" 'Accessibility service[^"]*On'
expect_ui "cold start shown" 'ms from process start'
adb shell input keyevent KEYCODE_BACK
sleep 2; dump
expect_ui "Back returns to the list" 'Search apps'

# 5. No crash anywhere.
adb logcat -d >"$out/logcat.txt"
if adb shell pidof "$app" >/dev/null; then pass "still running"; else fail "still running"; fi
if grep -E "FATAL EXCEPTION|E/flutter|Unhandled Exception" "$out/logcat.txt"; then fail "no errors in the log"; else pass "no errors in the log"; fi
exit $failed
