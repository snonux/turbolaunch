#!/usr/bin/env bash
# Two phones syncing through the S3 test bucket: the running emulator is
# phone A, and this starts a second emulator as phone B.
# Both get TurboLaunch fresh (app data cleared), launch different apps, and
# sync from the Sync screen:
#
#   A launches Settings 3x and Clock 2x, then syncs alone.
#   B launches Camera 1x, then syncs: it meets A, which has more launches,
#     so B takes over A's grid (Settings and Clock in the same cells).
#   A syncs again: it keeps its grid and gets Camera in B's cell.
#   Both stats screens show 6 launches on all phones.
#
# Needs S3_TEST_ACCESS_KEY_ID and S3_TEST_SECRET_KEY (it skips without them),
# and the first emulator's AVD (AVD, default "test", as
# reactivecircus/android-emulator-runner names it), whose system image the
# second AVD, phone-b, is made from. tool/e2e_android.sh runs
# it at its end. Screenshots and UI dumps go to build/sync-two-phones/.
#
#   tool/sync_two_phones.sh apks/app-x86_64-release.apk
set -euo pipefail
cd "$(dirname "$0")/.."
apk=${1:?usage: tool/sync_two_phones.sh app.apk}
app=org.buetow.turbolaunch
out=build/sync-two-phones
rm -rf "$out" && mkdir -p "$out"
if [ -z "${S3_TEST_ACCESS_KEY_ID:-}" ] || [ -z "${S3_TEST_SECRET_KEY:-}" ]; then
  echo "SKIP two phones: S3_TEST_ACCESS_KEY_ID or S3_TEST_SECRET_KEY not set"
  exit 0
fi
endpoint=${S3_TEST_ENDPOINT:-https://garage.f3s.buetow.org}
bucket=${S3_TEST_BUCKET:-turbolaunch-test}
a=emulator-5554 b=emulator-5556
failed=0
step=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failed=1; }
# Every adb call goes to the phone in $ANDROID_SERIAL; on A or B with `on`.
on() { export ANDROID_SERIAL=$1; }
shot() { step=$((step + 1)); adb exec-out screencap -p >"$out/$(printf %02d $step)_${ANDROID_SERIAL}_$1.png"; }
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null && adb shell cat /sdcard/ui.xml >"$out/ui.xml"; }
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
tap_on() {
  dump
  local xy; xy=$(centre "$1")
  if [ -z "$xy" ]; then fail "find '$1' on $ANDROID_SERIAL"; return 1; fi
  adb shell input tap $xy
}
scroll_to() { # text, up|down
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
hide_keyboard() { if adb shell dumpsys input_method | grep -q 'mInputShown=true'; then adb shell input keyevent KEYCODE_BACK; sleep 1; fi; }
type_into() { # resource-id text
  scroll_to "resource-id=\"$1\"" down || scroll_to "resource-id=\"$1\"" up || true
  tap_on "$1" && sleep 1 && adb shell input text "$2"
  sleep 1
  hide_keyboard
}
s3() { # method path [file]
  curl -sS --fail-with-body --aws-sigv4 "aws:amz:garage:s3" --user "$S3_TEST_ACCESS_KEY_ID:$S3_TEST_SECRET_KEY" \
    -X "$1" "$endpoint/$bucket/$2" ${3:+-T "$3"}
}
s3_clear() {
  for key in $(s3 GET "?list-type=2&prefix=turbolaunch/devices/" | grep -o '<Key>[^<]*</Key>' | sed 's/<[^>]*>//g'); do
    s3 DELETE "$key" >/dev/null
  done
}

# TurboLaunch fresh on the current phone: data cleared, home app, service on.
fresh() {
  adb shell settings put global window_animation_scale 0
  adb shell settings put global transition_animation_scale 0
  adb shell settings put global animator_duration_scale 0
  adb install -r "$apk" >/dev/null
  adb shell pm clear "$app" >/dev/null
  adb shell settings put secure enabled_accessibility_services "$app/$app.TurboLaunchAccessibilityService"
  adb shell settings put secure accessibility_enabled 1
  adb shell cmd package set-home-activity "$app/.MainActivity" >/dev/null
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  adb shell input keyevent KEYCODE_HOME
  sleep 8
}
# Launches the top match for $1 from the search box, $2 times.
launch() {
  for _ in $(seq "$2"); do
    tap_on search && sleep 1
    adb shell input text "$1"
    sleep 1
    adb shell input keyevent KEYCODE_ENTER
    sleep 4
    adb shell input keyevent KEYCODE_HOME
    sleep 3
  done
}
# Switches sync on with the test bucket's keys and names the phone $1.
setup_sync() {
  tap_on "TurboLaunch settings" && sleep 3
  tap_on "Share launch counts" && sleep 2
  tap_on sync-enabled && sleep 1
  type_into sync-endpoint "$endpoint"
  type_into sync-bucket "$bucket"
  type_into sync-key-id "$S3_TEST_ACCESS_KEY_ID"
  type_into sync-secret "$S3_TEST_SECRET_KEY"
  type_into sync-name "$1"
}
# Sync now on the open Sync screen; $1 is the result to expect.
sync_now() {
  scroll_to 'resource-id="sync-now"' down || true
  tap_on sync-now && sleep 12
  scroll_to "$1" down || true
  shot sync
  expect_ui "$ANDROID_SERIAL: Sync now says '$1'" "$1"
}
# Back from the Sync screen and settings to home.
home() {
  adb shell input keyevent KEYCODE_BACK; sleep 1
  adb shell input keyevent KEYCODE_BACK; sleep 1
  adb shell input keyevent KEYCODE_HOME; sleep 3
}
stats() { # expected text
  tap_on "TurboLaunch settings" && sleep 3
  tap_on "Launch stats" && sleep 2
  dump; shot stats
  expect_ui "$ANDROID_SERIAL: stats show '$1'" "$1"
  home
}
cell() { dump; centre "$1"; } # where $1's cell is on the home screen

# Phone B: a second emulator, on an AVD of its own made from the first one's
# system image (two emulators on one AVD never came up on CI).
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
avd_home=${ANDROID_AVD_HOME:-$HOME/.android/avd}
image=$(sed -n 's/^image.sysdir.1=//p' "$avd_home/${AVD:-test}.avd/config.ini" | sed 's:/*$::; s:/:;:g')
avdmanager=$sdk/cmdline-tools/latest/bin/avdmanager
[ -x "$avdmanager" ] || avdmanager=avdmanager
if ! echo no | "$avdmanager" create avd --force -n phone-b --package "$image" >"$out/avdmanager.log" 2>&1; then
  fail "second AVD made from $image"; tail -20 "$out/avdmanager.log"; exit 1
fi
printf 'hw.cpu.ncore=2\n' >>"$avd_home/phone-b.avd/config.ini"
"$sdk/emulator/emulator" -avd phone-b -port 5556 -no-window -gpu swiftshader_indirect -noaudio \
  -no-boot-anim -no-snapshot -no-metrics >"$out/emulator-b.log" 2>&1 &
emulator_pid=$!
trap 'adb -s $b emu kill >/dev/null 2>&1 || kill $emulator_pid 2>/dev/null || true' EXIT
if ! timeout 300 adb -s $b wait-for-device ||
  ! timeout 300 adb -s $b shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done'; then
  fail "second emulator booted"
  tail -30 "$out/emulator-b.log"
  exit 1
fi
pass "second emulator booted"
s3_clear

on $a
read -r w h < <(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')
fresh
launch sttngs 3
launch clock 2
dump; shot home
settings_a=$(centre Settings) clock_a=$(centre Clock)
[ -n "$settings_a" ] && [ -n "$clock_a" ] && pass "A: Settings and Clock on home" || fail "A: Settings and Clock on home"
setup_sync "phone A"
sync_now 'Synced with no other phones yet'
home

on $b
fresh
launch camera 1
dump; shot home
expect_ui "B: Camera on home" Camera
setup_sync "phone B"
sync_now 'Synced with 1 other phone'
scroll_to 'phone A' down || true
expect_ui "B: phone A listed" 'phone A'
home
dump; shot home_synced
settings_b=$(centre Settings) clock_b=$(centre Clock) camera_b=$(centre Camera)
if [ -n "$settings_b" ] && [ "$settings_b" = "$settings_a" ] && [ "$clock_b" = "$clock_a" ]; then
  pass "B took over A's grid (Settings at $settings_b, Clock at $clock_b)"
else
  fail "B took over A's grid (A: Settings $settings_a, Clock $clock_a; B: Settings $settings_b, Clock $clock_b)"
fi
[ -n "$camera_b" ] && pass "B: Camera kept a cell ($camera_b)" || fail "B: Camera kept a cell"
stats '6 launches on all phones, 1 here'

on $a
tap_on "TurboLaunch settings" && sleep 3
tap_on "On, 0 other phones" && sleep 2
sync_now 'Synced with 1 other phone'
home
dump; shot home_synced
if [ "$(centre Settings)" = "$settings_a" ] && [ "$(centre Clock)" = "$clock_a" ]; then
  pass "A kept its grid"
else
  fail "A kept its grid"
fi
camera_a=$(centre Camera)
if [ -n "$camera_a" ] && [ "$camera_a" = "$camera_b" ]; then
  pass "A: Camera in B's cell ($camera_a)"
else
  fail "A: Camera in B's cell (A: $camera_a, B: $camera_b)"
fi
stats '6 launches on all phones, 5 here'

# Both phones stop syncing before the files go, so nothing writes them again.
for phone in $a $b; do
  on $phone
  adb shell pm clear "$app" >/dev/null
done
s3_clear
unset ANDROID_SERIAL
exit $failed
