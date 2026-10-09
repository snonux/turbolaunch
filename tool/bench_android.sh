#!/usr/bin/env bash
# Benchmark of TurboLaunch on an emulator (or phone) where it is installed,
# is the home app and has its accessibility service on, as tool/e2e_android.sh
# leaves it (and calls this). It switches on the app's benchmark log with
# `setprop debug.turbolaunch.bench 1`, restarts the app and measures:
#
#   cold start   force-stopped, Home pressed: process start to the first frame
#                with the home grid ("home ready"), and Android's TotalTime
#   warm Home    Home pressed while another app is in front (TotalTime)
#   keystroke    a letter typed in the search box to the frame with its
#                results built
#   launch       Enter to the call that starts the app returning, and
#                Android's "Displayed" time of the app that opened
#   scroll       frame build and raster times while flinging the app list
#
# It prints a table of medians and 90th percentiles, writes it to
# build/bench-android/results.md, and fails when a number passes its limit
# below. Emulator numbers: compare runs on the same machine, not phones.
#
#   RUNS=5 tool/bench_android.sh
set -euo pipefail
cd "$(dirname "$0")/.."
app=org.buetow.turbolaunch
out=build/bench-android
rm -rf "$out" && mkdir -p "$out"
runs=${RUNS:-5}

# Limits for the CI emulator (software GPU), from its measured numbers with
# room for its noise; a regression past one fails the run. Times in ms.
limit_cold_home_ready=${LIMIT_COLD_HOME_READY:-2000}
limit_warm_home=${LIMIT_WARM_HOME:-200}
limit_keystroke_p90=${LIMIT_KEYSTROKE_P90:-16}
limit_launch_p90=${LIMIT_LAUNCH_P90:-100}
limit_scroll_build_p90=${LIMIT_SCROLL_BUILD_P90:-4}

dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null && adb shell cat /sdcard/ui.xml >"$out/ui.xml"; }
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
tap_on() { dump; local xy; xy=$(centre "$1"); [ -n "$xy" ] && adb shell input tap $xy; }
home_intent() { adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.HOME; }
total_time() { tr -d '\r' | sed -n 's/^TotalTime: *\([0-9]*\).*/\1/p'; }
log() { adb logcat -d -s flutter:I ActivityTaskManager:I; }
# Collects numbers (one per line) into $out/<name>.txt.
record() { cat >>"$out/$1.txt"; }
# grep finds nothing on a bad run; the summary reports missing samples.
nums() { grep -o "$1" | grep -o '[0-9]*$' || true; }
settings_front() { adb shell am start -W -n com.android.settings/.Settings >/dev/null; sleep 2; }

adb shell setprop debug.turbolaunch.bench 1
read -r w h < <(adb shell wm size | grep -o '[0-9]*x[0-9]*' | tail -1 | tr x ' ')

# Cold start: with another app in front Android does not restart the stopped
# launcher by itself, so the Home press below starts it from scratch.
for ((i = 0; i < runs; i++)); do
  settings_front
  adb shell am force-stop "$app"
  adb logcat -c
  home_intent | total_time | record cold_total
  sleep 5
  log | nums 'TurboLaunch home ready: [0-9]*' | tail -1 | record cold_home_ready
done
if ! log | grep -q 'TurboLaunch bench: on'; then
  echo "bench: the app did not switch on its benchmark log" >&2
  exit 1
fi

# Warm Home: TurboLaunch is running behind another app.
for ((i = 0; i < runs; i++)); do
  settings_front
  home_intent | total_time | record warm_home
  sleep 1
done

# Keystrokes: type app names letter by letter, as a person would.
adb shell input keyevent KEYCODE_HOME
sleep 2
for q in settings clock camera contacts chrome; do
  tap_on search
  sleep 1
  adb logcat -c
  for ((i = 0; i < ${#q}; i++)); do adb shell input text "${q:i:1}"; sleep 0.3; done
  sleep 0.5
  log | nums 'bench keystroke: [0-9]*' | awk '{ print $1 / 1000 }' | record keystroke
  adb shell input keyevent KEYCODE_HOME
  sleep 1.5
done

# Launch: search, Enter; then Home. Clock is stopped first, so each launch
# starts it and Android logs its "Displayed" time.
for ((i = 0; i < runs; i++)); do
  adb shell am force-stop com.google.android.deskclock
  adb shell am force-stop com.android.deskclock
  tap_on search
  sleep 1
  adb shell input text clk
  sleep 1
  adb logcat -c
  adb shell input keyevent KEYCODE_ENTER
  sleep 4
  log | nums 'bench launch: [0-9]*' | awk '{ print $1 / 1000 }' | record launch
  log | python3 -c 'import re, sys; [print(int(s or 0) * 1000 + int(ms)) for s, ms in re.findall(r"Displayed \S+[^+]*: \+(?:(\d+)s)?(\d+)ms", sys.stdin.read())]' | record launch_displayed
  adb shell input keyevent KEYCODE_HOME
  sleep 2
done

# Scrolling: the full app list, flung up and down.
tap_on search
sleep 2
adb logcat -c
for ((i = 0; i < 6; i++)); do
  adb shell input swipe $((w / 2)) $((h * 55 / 100)) $((w / 2)) $((h * 15 / 100)) 120
  sleep 0.6
  adb shell input swipe $((w / 2)) $((h * 15 / 100)) $((w / 2)) $((h * 55 / 100)) 120
  sleep 0.6
done
sleep 1
log | sed -n 's/.*bench frame: build \([0-9]*\) us, raster \([0-9]*\) us.*/\1 \2/p' >"$out/frames.txt"
awk '{ print $1 / 1000 }' "$out/frames.txt" | record scroll_build
awk '{ print $2 / 1000 }' "$out/frames.txt" | record scroll_raster
adb shell input keyevent KEYCODE_HOME
adb shell setprop debug.turbolaunch.bench 0

python3 - "$out" <<PY
import statistics, sys
out = sys.argv[1]
def nums(name):
    try:
        return sorted(float(x) for x in open(f"{out}/{name}.txt").read().split())
    except FileNotFoundError:
        return []
def pct(v, p):
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else float('nan')
rows = [
    ("Cold start to home grid", "cold_home_ready", "p50", $limit_cold_home_ready),
    ("Cold start, Android TotalTime", "cold_total", None, None),
    ("Home with an app in front", "warm_home", "p50", $limit_warm_home),
    ("Search keystroke to frame", "keystroke", "p90", $limit_keystroke_p90),
    ("Enter to app start call", "launch", "p90", $limit_launch_p90),
    ("Launched app displayed", "launch_displayed", None, None),
    ("Scroll frame build", "scroll_build", "p90", $limit_scroll_build_p90),
    ("Scroll frame raster", "scroll_raster", None, None),
]
lines = ["| Measure | n | median ms | p90 ms | max ms | limit |", "|---|---|---|---|---|---|"]
failed = []
for title, name, which, limit in rows:
    v = nums(name)
    p50, p90 = pct(v, 50), pct(v, 90)
    shown = f"{which} < {limit}" if limit else ""
    if not v:
        failed.append(f"{title}: no samples")
    elif limit and (p50 if which == "p50" else p90) > limit:
        failed.append(f"{title}: {which} {p50 if which == 'p50' else p90:.1f} ms > {limit} ms")
    lines.append(f"| {title} | {len(v)} | {p50:.1f} | {p90:.1f} | {max(v) if v else float('nan'):.1f} | {shown} |")
frames = nums("scroll_build")
if frames:
    raster = nums("scroll_raster")
    slow = sum(1 for l in open(f"{out}/frames.txt") if sum(int(x) for x in l.split()) > 16667)
    lines.append(f"\nScroll: {len(frames)} frames, {slow} over 16.7 ms build+raster.")
text = "\n".join(lines)
open(f"{out}/results.md", "w").write(text + "\n")
print(text)
for f in failed:
    print(f"FAIL bench {f}")
sys.exit(1 if failed else 0)
PY
