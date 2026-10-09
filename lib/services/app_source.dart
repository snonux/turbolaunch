import 'dart:async';
import 'dart:typed_data';

import 'package:launcher_platform/launcher_platform.dart';

import 'app_pairs.dart';

/// One launchable app, or a saved app pair. [key] is
/// `package/activity#userSerial` (or `pair:<first>|<second>`) and stays
/// stable, so launch counts and home slots are stored under it.
class AppEntry {
  const AppEntry({required this.key, required this.label, this.otherProfile = false, this.paused = false})
    : pair = null;

  AppEntry.pair(AppPair this.pair) : key = pair.key, label = pair.name, otherProfile = false, paused = false;

  final String key;
  final String label;

  /// In a work profile or another profile than the launcher's own.
  final bool otherProfile;

  /// Its profile is paused (work apps off); starting it asks to resume.
  final bool paused;

  /// Set for an app pair, which opens two apps in split screen.
  final AppPair? pair;

  bool get isPair => pair != null;

  /// The Android package; empty for a pair.
  String get packageName => isPair ? '' : key.substring(0, key.indexOf('/'));

  @override
  bool operator ==(Object other) =>
      other is AppEntry &&
      other.key == key &&
      other.label == label &&
      other.otherProfile == otherProfile &&
      other.paused == paused;

  @override
  int get hashCode => Object.hash(key, label, otherProfile, paused);

  @override
  String toString() => 'AppEntry($label, $key)';
}

/// One long-press shortcut of an app, searchable like an app.
class ShortcutEntry {
  const ShortcutEntry({required this.packageName, required this.id, required this.userSerial, required this.label});

  final String packageName;
  final String id;
  final int userSerial;
  final String label;

  /// Whether [app] is the app this shortcut belongs to.
  bool belongsTo(AppEntry app) => app.packageName == packageName && app.key.endsWith('#$userSerial');

  @override
  bool operator ==(Object other) =>
      other is ShortcutEntry && other.packageName == packageName && other.id == id && other.userSerial == userSerial;

  @override
  int get hashCode => Object.hash(packageName, id, userSerial);
}

/// What [AppSource.events] reports.
enum AppSourceEvent {
  /// Apps were installed, removed or updated: list them again.
  packagesChanged,

  /// Home was pressed while the launcher was already in front.
  homePressed,
}

/// Everything the UI needs from the device. [PlatformAppSource] talks to
/// Android; [FakeAppSource] serves the tests.
abstract class AppSource {
  Stream<AppSourceEvent> get events;
  Future<List<AppEntry>> listApps();
  Future<Uint8List?> icon(AppEntry app);
  Future<bool> launch(AppEntry app);
  Future<bool> appInfo(AppEntry app);

  /// Milliseconds from process start to now, or -1 where unknown.
  Future<int> startupMillis();

  /// Whether to log benchmark timings (tool/bench_android.sh turns it on).
  Future<bool> benchMode();
  Future<bool> splitServiceEnabled();

  /// Locks the phone; false when the accessibility service is off.
  Future<bool> lockScreen();

  /// Pulls down the notification shade; false when Android refused.
  Future<bool> expandNotifications();

  /// Saves [content] where the user picks; the file's name, or null when cancelled.
  Future<String?> saveTextFile(String name, String content);

  /// The text of a file the user picks, or null when cancelled.
  Future<String?> openTextFile();
  Future<void> openAccessibilitySettings();
  Future<void> openHomeSettings();
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second);

  /// Battery level in percent, or -1 where unknown.
  Future<int> battery();
  Future<bool> uninstall(AppEntry app);
  Future<List<ShortcutEntry>> shortcuts();
  Future<bool> startShortcut(ShortcutEntry shortcut);

  /// True when set, false on failure, null when the user cancelled.
  Future<bool?> pickWallpaper(WallpaperTarget target);
}

class PlatformAppSource implements AppSource {
  PlatformAppSource([this._platform = const LauncherPlatform()]);

  final LauncherPlatform _platform;

  @override
  late final Stream<AppSourceEvent> events = _platform.events
      .map(
        (e) => switch (e) {
          'home' => AppSourceEvent.homePressed,
          _ => AppSourceEvent.packagesChanged,
        },
      )
      .asBroadcastStream();

  @override
  Future<List<AppEntry>> listApps() async => [
    for (final a in await _platform.listApps())
      AppEntry(key: a.key, label: a.label, otherProfile: a.otherProfile, paused: a.paused),
  ];

  @override
  Future<Uint8List?> icon(AppEntry app) => _platform.icon(app.key);

  @override
  Future<bool> launch(AppEntry app) => _platform.launch(app.key);

  @override
  Future<bool> appInfo(AppEntry app) => _platform.appInfo(app.key);

  @override
  Future<int> startupMillis() => _platform.startupMillis();

  @override
  Future<bool> benchMode() => _platform.benchMode();

  @override
  Future<bool> splitServiceEnabled() => _platform.splitServiceEnabled();

  @override
  Future<bool> lockScreen() => _platform.lockScreen();

  @override
  Future<bool> expandNotifications() => _platform.expandNotifications();

  @override
  Future<String?> saveTextFile(String name, String content) => _platform.saveTextFile(name, content);

  @override
  Future<String?> openTextFile() => _platform.openTextFile();

  @override
  Future<void> openAccessibilitySettings() => _platform.openAccessibilitySettings();

  @override
  Future<void> openHomeSettings() => _platform.openHomeSettings();

  @override
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second) => _platform.launchPair(first.key, second.key);

  @override
  Future<int> battery() => _platform.battery();

  @override
  Future<bool> uninstall(AppEntry app) => _platform.uninstall(app.key);

  @override
  Future<List<ShortcutEntry>> shortcuts() async => [
    for (final s in await _platform.shortcuts())
      ShortcutEntry(packageName: s.packageName, id: s.id, userSerial: s.userSerial, label: s.label),
  ];

  @override
  Future<bool> startShortcut(ShortcutEntry s) => _platform.startShortcut(
    PlatformShortcut(packageName: s.packageName, id: s.id, userSerial: s.userSerial, label: s.label),
  );

  @override
  Future<bool?> pickWallpaper(WallpaperTarget target) => _platform.pickWallpaper(target);
}

/// An in-memory device: a fixed app list, and a record of what was launched.
class FakeAppSource implements AppSource {
  FakeAppSource(List<AppEntry> apps, {List<ShortcutEntry> shortcuts = const []})
    : _apps = List.of(apps),
      _shortcuts = List.of(shortcuts);

  List<AppEntry> _apps;
  final List<ShortcutEntry> _shortcuts;
  final launched = <AppEntry>[];
  final shortcutsStarted = <ShortcutEntry>[];
  final uninstalled = <AppEntry>[];
  final wallpapers = <WallpaperTarget>[];
  final pairs = <(AppEntry, AppEntry)>[];
  int locks = 0;
  int shades = 0;

  /// Files "saved" through [saveTextFile], by name; [openTextFile] returns [fileToOpen].
  final savedFiles = <String, String>{};
  String? fileToOpen;
  final _events = StreamController<AppSourceEvent>.broadcast();
  bool serviceEnabled = false;

  set apps(List<AppEntry> apps) {
    _apps = List.of(apps);
    _events.add(AppSourceEvent.packagesChanged);
  }

  void pressHome() => _events.add(AppSourceEvent.homePressed);

  @override
  Stream<AppSourceEvent> get events => _events.stream;

  @override
  Future<List<AppEntry>> listApps() async => List.of(_apps);

  @override
  Future<Uint8List?> icon(AppEntry app) async => null;

  @override
  Future<bool> launch(AppEntry app) async {
    launched.add(app);
    return true;
  }

  @override
  Future<bool> appInfo(AppEntry app) async => true;

  @override
  Future<int> startupMillis() async => -1;

  @override
  Future<bool> benchMode() async => false;

  @override
  Future<bool> splitServiceEnabled() async => serviceEnabled;

  @override
  Future<bool> lockScreen() async {
    if (!serviceEnabled) return false;
    locks++;
    return true;
  }

  @override
  Future<bool> expandNotifications() async {
    shades++;
    return true;
  }

  @override
  Future<String?> saveTextFile(String name, String content) async {
    savedFiles[name] = content;
    // An import opens what the last export saved.
    fileToOpen = content;
    return name;
  }

  @override
  Future<String?> openTextFile() async => fileToOpen;

  @override
  Future<void> openAccessibilitySettings() async {}

  @override
  Future<void> openHomeSettings() async {}

  @override
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second) async {
    pairs.add((first, second));
    return serviceEnabled ? PairOutcome.split : PairOutcome.noService;
  }

  @override
  Future<int> battery() async => 87;

  @override
  Future<bool> uninstall(AppEntry app) async {
    uninstalled.add(app);
    return true;
  }

  @override
  Future<List<ShortcutEntry>> shortcuts() async => List.of(_shortcuts);

  @override
  Future<bool> startShortcut(ShortcutEntry shortcut) async {
    shortcutsStarted.add(shortcut);
    return true;
  }

  @override
  Future<bool?> pickWallpaper(WallpaperTarget target) async {
    wallpapers.add(target);
    return true;
  }
}
