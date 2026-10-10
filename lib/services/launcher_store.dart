import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_pairs.dart';
import 'app_source.dart';
import 'gestures.dart';
import 'home_grid.dart';
import 'sync.dart';

/// User settings, all with defaults that work without any setup.
class LauncherSettings {
  const LauncherSettings({
    this.gridRows = 0,
    this.gridCols = 0,
    this.labelScale = 1.0,
    this.resultScale = 1.0,
    this.clockScale = 1.0,
    this.keyboardOnHome = false,
    this.showClock = true,
    this.iconsInResults = true,
    this.doubleTapLock = true,
    this.gestures = Gestures.defaults,
  });

  /// 0 means automatic, from the screen size.
  final int gridRows;
  final int gridCols;

  /// Font size factors on top of the system font size, 0.8 to 1.6.
  final double labelScale;
  final double resultScale;
  final double clockScale;

  /// Open the keyboard on every Home press instead of on a tap in the search box.
  final bool keyboardOnHome;
  final bool showClock;
  final bool iconsInResults;

  /// Double-tap on empty home space locks the phone (needs the accessibility service).
  final bool doubleTapLock;

  /// Swipe gestures on the home screen: gesture code (see [Gestures]) to
  /// encoded [GestureAction]. A gesture that is not here does nothing.
  final Map<String, String> gestures;

  GestureAction gestureAction(String code) =>
      gestures[code] == null ? GestureAction.none : GestureAction.decode(gestures[code]!);

  static const minScale = 0.8;
  static const maxScale = 1.6;

  LauncherSettings copyWith({
    int? gridRows,
    int? gridCols,
    double? labelScale,
    double? resultScale,
    double? clockScale,
    bool? keyboardOnHome,
    bool? showClock,
    bool? iconsInResults,
    bool? doubleTapLock,
    Map<String, String>? gestures,
  }) => LauncherSettings(
    gridRows: gridRows ?? this.gridRows,
    gridCols: gridCols ?? this.gridCols,
    labelScale: labelScale ?? this.labelScale,
    resultScale: resultScale ?? this.resultScale,
    clockScale: clockScale ?? this.clockScale,
    keyboardOnHome: keyboardOnHome ?? this.keyboardOnHome,
    showClock: showClock ?? this.showClock,
    iconsInResults: iconsInResults ?? this.iconsInResults,
    doubleTapLock: doubleTapLock ?? this.doubleTapLock,
    gestures: gestures ?? this.gestures,
  );

  Map<String, Object> toJson() => {
    'gridRows': gridRows,
    'gridCols': gridCols,
    'labelScale': labelScale,
    'resultScale': resultScale,
    'clockScale': clockScale,
    'keyboardOnHome': keyboardOnHome,
    'showClock': showClock,
    'iconsInResults': iconsInResults,
    'doubleTapLock': doubleTapLock,
    'gestures': gestures,
  };

  factory LauncherSettings.fromJson(Map<String, Object?> j) {
    double scale(Object? v) => ((v as num?)?.toDouble() ?? 1.0).clamp(minScale, maxScale);
    int size(Object? v) => ((v as num?)?.toInt() ?? 0).clamp(0, 12);
    return LauncherSettings(
      gridRows: size(j['gridRows']),
      gridCols: size(j['gridCols']),
      labelScale: scale(j['labelScale']),
      resultScale: scale(j['resultScale']),
      clockScale: scale(j['clockScale']),
      keyboardOnHome: j['keyboardOnHome'] as bool? ?? false,
      showClock: j['showClock'] as bool? ?? true,
      iconsInResults: j['iconsInResults'] as bool? ?? true,
      doubleTapLock: j['doubleTapLock'] as bool? ?? true,
      gestures: _gestures(j),
    );
  }

  /// The gestures, or for settings from before gestures the defaults, with
  /// swipe down off if "Swipe down for notifications" was.
  static Map<String, String> _gestures(Map<String, Object?> j) {
    final raw = j['gestures'];
    if (raw is Map) {
      return Map.unmodifiable({
        for (final e in raw.entries)
          if (e.key is String && e.value is String && Gestures.valid(e.key as String))
            e.key as String: e.value as String,
      });
    }
    if (j['swipeNotifications'] == false) return const {'U': 'search'};
    return Gestures.defaults;
  }
}

/// Everything TurboLaunch remembers, on the device in SharedPreferences:
/// launch counts, home cells, apps removed from the grid, hidden apps, app
/// pairs, the settings, and the sync settings and what the last sync brought.
class LauncherStore {
  LauncherStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<LauncherStore> open() async => LauncherStore(await SharedPreferences.getInstance());

  static const _counts = 'launchCounts';
  static const _slots = 'homeSlots';
  static const _excluded = 'removedFromHome';
  static const _hidden = 'hiddenApps';
  static const _settings = 'settings';
  static const _quickHide = 'quickHide';
  static const _pairs = 'appPairs';
  static const _appSnapshot = 'appSnapshot';
  static const _sync = 'syncConfig';
  static const _deviceId = 'syncDeviceId';
  static const _remote = 'syncRemote';
  static const _legacyLent = 'syncLent';
  static const _lent = 'syncBorrowed';
  static const _lastSync = 'syncLast';
  static const _met = 'syncMetOthers';

  Map<String, Object?> _json(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return const {};
    try {
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  Map<String, int> get counts => {
    for (final e in _json(_counts).entries)
      if (e.value is num) e.key: (e.value as num).toInt(),
  };

  Future<void> setCounts(Map<String, int> v) => _prefs.setString(_counts, jsonEncode(v));

  Map<Cell, String> get slots => {
    for (final e in _json(_slots).entries)
      if (Cell.parse(e.key) != null && e.value is String) Cell.parse(e.key)!: e.value as String,
  };

  Future<void> setSlots(Map<Cell, String> v) =>
      _prefs.setString(_slots, jsonEncode({for (final e in v.entries) e.key.toString(): e.value}));

  Set<String> get excluded => (_prefs.getStringList(_excluded) ?? const []).toSet();
  Future<void> setExcluded(Set<String> v) => _prefs.setStringList(_excluded, v.toList()..sort());

  Set<String> get hidden => (_prefs.getStringList(_hidden) ?? const []).toSet();
  Future<void> setHidden(Set<String> v) => _prefs.setStringList(_hidden, v.toList()..sort());

  LauncherSettings get settings => LauncherSettings.fromJson(_json(_settings));
  Future<void> setSettings(LauncherSettings v) => _prefs.setString(_settings, jsonEncode(v.toJson()));

  List<AppPair> get pairs {
    final raw = _prefs.getString(_pairs);
    if (raw == null) return const [];
    try {
      final v = jsonDecode(raw);
      return v is List ? [for (final p in v.map(AppPair.fromJson)) ?p] : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<void> setPairs(List<AppPair> v) => _prefs.setString(_pairs, jsonEncode([for (final p in v) p.toJson()]));

  /// The installed apps as last listed, shown while a cold start lists them again.
  List<AppEntry> get appSnapshot {
    final raw = _prefs.getString(_appSnapshot);
    if (raw == null) return const [];
    try {
      final v = jsonDecode(raw);
      if (v is! List) return const [];
      return [
        for (final a in v)
          if (a is Map && a['key'] is String && a['label'] is String)
            AppEntry(
              key: a['key'] as String,
              label: a['label'] as String,
              otherProfile: a['otherProfile'] == true,
              paused: a['paused'] == true,
            ),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> setAppSnapshot(List<AppEntry> apps) {
    final json = jsonEncode([
      for (final a in apps)
        {'key': a.key, 'label': a.label, if (a.otherProfile) 'otherProfile': true, if (a.paused) 'paused': true},
    ]);
    // Most starts list the same apps; skip the write then.
    if (_prefs.getString(_appSnapshot) == json) return Future.value();
    return _prefs.setString(_appSnapshot, json);
  }

  SyncConfig get syncConfig => SyncConfig.fromJson(_json(_sync));
  Future<void> setSyncConfig(SyncConfig v) => _prefs.setString(_sync, jsonEncode(v.toJson()));

  /// This phone's id in the bucket, made on first use. Never exported, so a
  /// phone set up from another's export still writes a file of its own.
  String get deviceId {
    final id = _prefs.getString(_deviceId);
    if (id != null && id.isNotEmpty) return id;
    final made = newDeviceId();
    _prefs.setString(_deviceId, made);
    return made;
  }

  /// The other phones' files as the last sync read them.
  List<DeviceSync> get remote {
    final raw = _prefs.getString(_remote);
    if (raw == null) return const [];
    try {
      final v = jsonDecode(raw);
      return v is List ? [for (final d in v.map(DeviceSync.fromJson)) ?d] : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<void> setRemote(List<DeviceSync> v) => _prefs.setString(_remote, jsonEncode([for (final d in v) d.toJson()]));

  /// Ghost cells a local app borrowed, with the sync key of the app they are kept for.
  Map<Cell, String> get lent => _cells(_lent);

  Future<void> setLent(Map<Cell, String> v) =>
      _prefs.setString(_lent, jsonEncode({for (final e in v.entries) e.key.toString(): e.value}));

  /// Cells lent by versions before ghost icons, which lent a cell even when
  /// others were free. Read once, to place their borrowers again.
  Map<Cell, String> get legacyLent => _cells(_legacyLent);

  Future<void> clearLegacyLent() => _prefs.remove(_legacyLent);

  Map<Cell, String> _cells(String key) => {
    for (final e in _json(key).entries)
      if (Cell.parse(e.key) != null && e.value is String) Cell.parse(e.key)!: e.value as String,
  };

  DateTime? get lastSync => DateTime.tryParse(_prefs.getString(_lastSync) ?? '');
  Future<void> setLastSync(DateTime v) => _prefs.setString(_lastSync, v.toUtc().toIso8601String());

  /// Whether a sync has found other phones yet; the first that does may take over their grid.
  bool get metOtherPhones => _prefs.getBool(_met) ?? false;
  Future<void> setMetOtherPhones(bool v) => _prefs.setBool(_met, v);

  bool get quickHide => _prefs.getBool(_quickHide) ?? false;
  Future<void> setQuickHide(bool v) => _prefs.setBool(_quickHide, v);
}
