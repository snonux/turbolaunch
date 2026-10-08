import 'package:flutter/widgets.dart';

import 'app_source.dart';
import 'launcher_controller.dart';

/// Measures cold start: the time from process start (as Android reports it)
/// to the first frame Flutter draws, and to the first frame with the apps.
class StartupTimer {
  StartupTimer._();

  /// Null until measured; -1 where the platform cannot tell.
  static final coldStartMillis = ValueNotifier<int?>(null);

  /// Call once, right after `runApp`.
  static void measureAfterFirstFrame(AppSource source) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ms = await source.startupMillis();
      coldStartMillis.value = ms;
      if (ms >= 0) debugPrint('TurboLaunch cold start: $ms ms');
    });
  }

  /// Logs when the first frame with the app list (and so the home grid) is
  /// drawn: what someone pressing Home on a cold phone waits for.
  static void measureHomeReady(AppSource source, LauncherController controller) {
    void check() {
      if (!controller.loaded) return;
      controller.removeListener(check);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ms = await source.startupMillis();
        if (ms >= 0) debugPrint('TurboLaunch home ready: $ms ms');
      });
    }

    controller.addListener(check);
    check();
  }
}
