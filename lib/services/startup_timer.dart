import 'package:flutter/widgets.dart';

import 'app_source.dart';

/// Measures cold start: the time from process start (as Android reports it)
/// to the first frame Flutter draws.
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
}
