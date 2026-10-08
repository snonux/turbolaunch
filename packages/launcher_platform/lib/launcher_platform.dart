/// Android launcher APIs for TurboLaunch, backed by the Kotlin plugin in
/// `android/`. Apps are identified by a key string `package/activity#userSerial`.
library;

import 'package:flutter/services.dart';

/// One launchable activity as the platform reports it.
class PlatformApp {
  const PlatformApp({required this.key, required this.label, required this.otherProfile});

  final String key;
  final String label;

  /// True for apps in a work profile or another profile than the launcher's own.
  final bool otherProfile;
}

/// One long-press shortcut of an app ("New note", "Navigate home").
class PlatformShortcut {
  const PlatformShortcut({required this.packageName, required this.id, required this.userSerial, required this.label});

  final String packageName;
  final String id;
  final int userSerial;
  final String label;
}

/// Which screens a picked wallpaper goes on.
enum WallpaperTarget { home, lock, both }

/// How [LauncherPlatform.launchPair] ended.
enum PairOutcome { split, noService, failed }

class LauncherPlatform {
  const LauncherPlatform();

  static const _channel = MethodChannel('launcher_platform');
  static const _events = EventChannel('launcher_platform/events');

  /// `"packages"` when apps were installed, removed or changed, `"home"` when
  /// Home was pressed while the launcher was already in front.
  Stream<String> get events => _events.receiveBroadcastStream().map((e) => e as String);

  Future<List<PlatformApp>> listApps() async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('listApps') ?? const [];
    return [
      for (final m in raw)
        PlatformApp(
          key: m['key'] as String,
          label: m['label'] as String,
          otherProfile: m['otherProfile'] as bool? ?? false,
        ),
    ];
  }

  /// The app's icon as a square PNG of [size] pixels, or null if it is gone.
  Future<Uint8List?> icon(String key, {int size = 144}) =>
      _channel.invokeMethod<Uint8List>('icon', {'key': key, 'size': size});

  Future<bool> launch(String key) async => await _channel.invokeMethod<bool>('launch', {'key': key}) ?? false;

  Future<bool> appInfo(String key) async => await _channel.invokeMethod<bool>('appInfo', {'key': key}) ?? false;

  /// Milliseconds from process start until now; called after the first frame
  /// it measures cold start.
  Future<int> startupMillis() async => await _channel.invokeMethod<int>('startupMillis') ?? -1;

  /// Whether the user enabled TurboLaunch's accessibility service.
  Future<bool> splitServiceEnabled() async => await _channel.invokeMethod<bool>('splitServiceEnabled') ?? false;

  Future<void> openAccessibilitySettings() => _channel.invokeMethod('openAccessibilitySettings');

  /// Opens the system's default home app picker.
  Future<void> openHomeSettings() => _channel.invokeMethod('openHomeSettings');

  Future<PairOutcome> launchPair(String first, String second) async {
    final r = await _channel.invokeMethod<String>('launchPair', {'first': first, 'second': second});
    return switch (r) {
      'split' => PairOutcome.split,
      'no_service' => PairOutcome.noService,
      _ => PairOutcome.failed,
    };
  }

  /// Battery level in percent.
  Future<int> battery() async => await _channel.invokeMethod<int>('battery') ?? -1;

  /// Opens the system's uninstall confirmation for the app.
  Future<bool> uninstall(String key) async => await _channel.invokeMethod<bool>('uninstall', {'key': key}) ?? false;

  /// Every app's shortcuts; empty unless TurboLaunch is the default home app.
  Future<List<PlatformShortcut>> shortcuts() async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('shortcuts') ?? const [];
    return [
      for (final m in raw)
        PlatformShortcut(
          packageName: m['package'] as String,
          id: m['id'] as String,
          userSerial: (m['userSerial'] as num).toInt(),
          label: m['label'] as String,
        ),
    ];
  }

  Future<bool> startShortcut(PlatformShortcut s) async =>
      await _channel.invokeMethod<bool>('startShortcut', {
        'package': s.packageName,
        'id': s.id,
        'userSerial': s.userSerial,
      }) ??
      false;

  /// Lets the user pick an image and sets it as wallpaper. True when set,
  /// false on failure, null when the user cancelled the picker.
  Future<bool?> pickWallpaper(WallpaperTarget target) =>
      _channel.invokeMethod<bool>('pickWallpaper', {'target': target.name});
}
