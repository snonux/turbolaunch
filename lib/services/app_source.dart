import 'dart:async';
import 'dart:typed_data';

import 'package:launcher_platform/launcher_platform.dart';

/// One launchable app. [key] is `package/activity#userSerial` and stays
/// stable, so later phases use it for launch counts and home slots.
class AppEntry {
  const AppEntry({required this.key, required this.label, this.otherProfile = false});

  final String key;
  final String label;

  /// In a work profile or another profile than the launcher's own.
  final bool otherProfile;

  String get packageName => key.substring(0, key.indexOf('/'));

  @override
  bool operator ==(Object other) =>
      other is AppEntry && other.key == key && other.label == label && other.otherProfile == otherProfile;

  @override
  int get hashCode => Object.hash(key, label, otherProfile);

  @override
  String toString() => 'AppEntry($label, $key)';
}

/// What [AppSource.events] reports.
enum AppSourceEvent {
  /// Apps were installed, removed or updated: list them again.
  packagesChanged,

  /// Home was pressed while the launcher was already in front.
  homePressed,
}

/// Everything the UI needs from the device. [PlatformAppSource] talks to
/// Android; [FakeAppSource] serves the Linux desktop build and the tests.
abstract class AppSource {
  Stream<AppSourceEvent> get events;
  Future<List<AppEntry>> listApps();
  Future<Uint8List?> icon(AppEntry app);
  Future<bool> launch(AppEntry app);
  Future<bool> appInfo(AppEntry app);

  /// Milliseconds from process start to now, or -1 where unknown.
  Future<int> startupMillis();
  Future<bool> splitServiceEnabled();
  Future<void> openAccessibilitySettings();
  Future<void> openHomeSettings();
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second);
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
    for (final a in await _platform.listApps()) AppEntry(key: a.key, label: a.label, otherProfile: a.otherProfile),
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
  Future<bool> splitServiceEnabled() => _platform.splitServiceEnabled();

  @override
  Future<void> openAccessibilitySettings() => _platform.openAccessibilitySettings();

  @override
  Future<void> openHomeSettings() => _platform.openHomeSettings();

  @override
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second) => _platform.launchPair(first.key, second.key);
}

/// An in-memory device: a fixed app list, and a record of what was launched.
class FakeAppSource implements AppSource {
  FakeAppSource(List<AppEntry> apps) : _apps = List.of(apps);

  /// A plausible set of free apps, for the Linux desktop build.
  factory FakeAppSource.demo() => FakeAppSource([
    for (final (pkg, label) in const [
      ('org.mozilla.fennec_fdroid', 'Fennec'),
      ('app.organicmaps', 'Organic Maps'),
      ('org.fossify.gallery', 'Gallery'),
      ('org.fossify.calendar', 'Calendar'),
      ('org.fossify.clock', 'Clock'),
      ('org.fossify.contacts', 'Contacts'),
      ('org.fossify.messages', 'Messages'),
      ('org.fossify.phone', 'Phone'),
      ('org.fossify.notes', 'Notes'),
      ('com.github.libretube', 'LibreTube'),
      ('de.danoeh.antennapod', 'AntennaPod'),
      ('org.buetow.quicklog', 'Quicklog'),
      ('app.grapheneos.camera', 'Camera'),
      ('com.android.settings', 'Settings'),
      ('net.osmand.plus', 'OsmAnd~'),
      ('org.thoughtcrime.securesms', 'Molly'),
      ('com.termux', 'Termux'),
      ('ch.protonmail.android', 'Proton Mail'),
    ])
      AppEntry(key: '$pkg/$pkg.MainActivity#0', label: label),
  ]);

  List<AppEntry> _apps;
  final launched = <AppEntry>[];
  final pairs = <(AppEntry, AppEntry)>[];
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
  Future<bool> splitServiceEnabled() async => serviceEnabled;

  @override
  Future<void> openAccessibilitySettings() async {}

  @override
  Future<void> openHomeSettings() async {}

  @override
  Future<PairOutcome> launchPair(AppEntry first, AppEntry second) async {
    pairs.add((first, second));
    return serviceEnabled ? PairOutcome.split : PairOutcome.noService;
  }
}
