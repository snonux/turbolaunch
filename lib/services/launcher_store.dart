import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'home_grid.dart';

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
  }) => LauncherSettings(
    gridRows: gridRows ?? this.gridRows,
    gridCols: gridCols ?? this.gridCols,
    labelScale: labelScale ?? this.labelScale,
    resultScale: resultScale ?? this.resultScale,
    clockScale: clockScale ?? this.clockScale,
    keyboardOnHome: keyboardOnHome ?? this.keyboardOnHome,
    showClock: showClock ?? this.showClock,
    iconsInResults: iconsInResults ?? this.iconsInResults,
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
    );
  }
}

/// Everything TurboLaunch remembers, on the device in SharedPreferences:
/// launch counts, home cells, apps removed from the grid, hidden apps and
/// the settings. Later phases sync the first three through S3.
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

  bool get quickHide => _prefs.getBool(_quickHide) ?? false;
  Future<void> setQuickHide(bool v) => _prefs.setBool(_quickHide, v);
}
