import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'app_source.dart';

/// Timings for tool/bench_android.sh, written to the log only when
/// `adb shell setprop debug.turbolaunch.bench 1` was run before the app
/// started. Off on every phone, where each call below returns at once.
class Bench {
  Bench._();

  static bool _on = false;

  /// Call once at start-up.
  static Future<void> init(AppSource source) async {
    _on = await source.benchMode();
    if (!_on) return;
    debugPrint('TurboLaunch bench: on');
    SchedulerBinding.instance.addTimingsCallback(_frames);
  }

  /// A keystroke in the search box: logs the time until the frame with its
  /// results is built (search, layout and paint on the UI thread).
  static void keystroke() {
    if (!_on) return;
    final watch = Stopwatch()..start();
    SchedulerBinding.instance.ensureVisualUpdate();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      debugPrint('TurboLaunch bench keystroke: ${watch.elapsedMicroseconds} us');
    });
  }

  /// From a tap or Enter to the platform call that starts the app returning.
  static Stopwatch? launchStarted() => _on ? (Stopwatch()..start()) : null;

  static void launchDone(Stopwatch? watch) {
    if (watch == null) return;
    debugPrint('TurboLaunch bench launch: ${watch.elapsedMicroseconds} us');
  }

  static void _frames(List<FrameTiming> timings) {
    for (final t in timings) {
      debugPrint(
        'TurboLaunch bench frame: build ${t.buildDuration.inMicroseconds} us, '
        'raster ${t.rasterDuration.inMicroseconds} us',
      );
    }
  }
}
