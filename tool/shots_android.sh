#!/usr/bin/env bash
# Screenshots and a short screen recording for the README, the guide and
# F-Droid, taken on an emulator where TurboLaunch is installed, is the home
# app and has its accessibility service on (tool/e2e_android.sh leaves it so,
# and calls this at its end). The emulator's own apps only, so no personal
# data. Launches a few apps through the search box to fill the home grid,
# then captures, at a phone-like 720x1600, into build/shots-android/:
#
#   home.png search.png menu.png settings.png stats.png search.mp4
#
# With SHOTS_TO_LOG=1 every file is also printed base64-encoded, in long
# lines between "=== SHOT name" and "=== END", so the files can be taken
# from the tail of a CI log when its artifacts are out of reach.
#
#   tool/shots_android.sh
set -euo pipefail
cd "$(dirname "$0")/.."
app=org.buetow.turbolaunch
out=build/shots-android
rm -rf "$out" && mkdir -p "$out"

dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null && adb shell cat /sdcard/ui.xml >"$out/ui.xml"; }
shot() { adb exec-out screencap -p >"$out/$1.png"; echo "shot $1.png"; }
# Centre of the first UI node whose text, content-desc or resource-id has $1.
centre() {
  python3 - "$out/ui.xml" "$1" <<'PY'
import re, sys
xml, want = open(sys.argv[1]).read(), sys.argv[2]
for node in re.findall(r'<node [^>]*>', xml):
    attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', node))
    if want == attrs.get('resource-id') or any(want in attrs.get(k, '') for k in ('text', 'content-desc')):
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', attrs['bounds']))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}
tap_on() {
  dump
  local xy; xy=$(centre "$1")
  if [ -z "$xy" ]; then echo "shots: '$1' not on screen" >&2; return 1; fi
  adb shell input tap $xy
}
home() { adb shell input keyevent KEYCODE_HOME; sleep 3; }
in_front() { adb shell dumpsys window | grep -E 'mCurrentFocus' | grep -q "$app"; }
# Types $1 one letter at a time, as a person would.
type_slowly() {
  local i
  for ((i = 0; i < ${#1}; i++)); do adb shell input text "${1:i:1}"; sleep 0.4; done
}
# Searches for $1 and launches the top match with Enter, $2 times.
launch() {
  local n
  for ((n = 0; n < $2; n++)); do
    home
    tap_on search || return 0
    adb shell input text "$1"
    sleep 1
    adb shell input keyevent KEYCODE_ENTER
    sleep 4
  done
  home
}

# A phone-sized screen (same dp as 1080x2400 at 420 dpi) and a tidy status
# bar: fixed clock, full battery and signal, no notification icons.
adb shell wm size 720x1600
adb shell wm density 280
adb shell settings put global sysui_demo_allowed 1
sleep 2
demo() { adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
demo enter
sleep 1
demo clock -e hhmm 0942
demo battery -e level 100 -e plugged false
demo network -e wifi show -e level 4 -e mobile show -e level 4 -e datatype none
demo notifications -e visible false
home
sleep 3

# Fill the home grid: a launch puts an app on it, the most-launched nearest
# the search box. Queries are fuzzy, as one would type them.
for q in clk:4 cam:3 chrm:3 cntcts:2 fls:2 msgs:2 phn:1 clndr:1 gall:1 mps:1 ytb:1 sttngs:1; do
  launch "${q%%:*}" "${q##*:}"
done
in_front || home
sleep 2
shot home

# Search: matched letters highlighted, app shortcuts among the results.
tap_on search
adb shell input text "ch"
sleep 2
shot search
home

# The long-press menu of a home cell.
dump
xy=$(centre "Camera")
if [ -n "$xy" ]; then
  adb shell input swipe $xy $xy 900
  sleep 2
  shot menu
  adb shell input keyevent KEYCODE_BACK
  sleep 1
fi
home

# Settings and the launch stats.
tap_on "TurboLaunch settings" && sleep 3 && shot settings
tap_on "Launch stats" && sleep 2 && shot stats
home

# A short recording: type "clk", Enter opens Clock, Home brings back the grid.
adb shell rm -f /sdcard/search.mp4
adb shell screenrecord --time-limit 12 --bit-rate 2000000 /sdcard/search.mp4 &
rec=$!
sleep 1.5
tap_on search
sleep 0.8
type_slowly clk
sleep 1
adb shell input keyevent KEYCODE_ENTER
sleep 3
adb shell input keyevent KEYCODE_HOME
wait $rec || true
sleep 1
adb pull /sdcard/search.mp4 "$out/search.mp4" >/dev/null && echo "recorded search.mp4"

demo exit
adb shell wm size reset
adb shell wm density reset
rm -f "$out/ui.xml"

if [ "${SHOTS_TO_LOG:-}" = 1 ]; then
  for f in "$out"/*; do
    echo "=== SHOT $(basename "$f")"
    base64 -w 16000 "$f"
    echo "=== END"
  done
fi
