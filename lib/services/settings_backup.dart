import 'dart:convert';

import 'app_pairs.dart';
import 'home_grid.dart';
import 'launcher_store.dart';
import 'sync.dart';

/// Settings export and import, adapted from Quicklog's settings_backup.dart:
/// one versioned, readable JSON file the user saves and opens through the
/// system file dialogs. It carries the settings, hidden apps, apps removed
/// from home, app pairs, launch counts, home cells and the sync settings
/// (with the S3 keys, in plain text like Quicklog's), so a new phone starts
/// with the same grid. The phone's sync id is never in it.

/// Identifies a TurboLaunch export; matches the Android application id so a
/// file from a sibling app (Quicklog) is recognised as foreign.
const String kSettingsAppId = 'org.buetow.turbolaunch';
const String kSettingsFormat = 'turbolaunch-settings';

/// Bump when the layout changes incompatibly. Readers accept any version up
/// to their own; adding keys needs no bump, unknown keys are ignored.
const int kSettingsFormatVersion = 1;

/// A file that cannot be imported; [message] is shown to the user as is.
class SettingsImportException implements Exception {
  const SettingsImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What an export holds. A null field means "not in the file": importing
/// leaves the current value alone.
class LauncherBackup {
  const LauncherBackup({
    this.settings,
    this.hidden,
    this.removedFromHome,
    this.pairs,
    this.launchCounts,
    this.homeSlots,
    this.sync,
    this.exportedAt,
  });

  final LauncherSettings? settings;
  final Set<String>? hidden;
  final Set<String>? removedFromHome;
  final List<AppPair>? pairs;
  final Map<String, int>? launchCounts;
  final Map<Cell, String>? homeSlots;
  final SyncConfig? sync;

  /// True when the file carries S3 keys in plain text.
  bool get containsSecrets => (sync?.accessKeyId ?? '').isNotEmpty || (sync?.secretAccessKey ?? '').isNotEmpty;

  /// When the file was written, if it says so (informational only).
  final DateTime? exportedAt;

  static LauncherBackup fromStore(LauncherStore store) => LauncherBackup(
    settings: store.settings,
    hidden: store.hidden,
    removedFromHome: store.excluded,
    pairs: store.pairs,
    launchCounts: store.counts,
    homeSlots: store.slots,
    sync: store.syncConfig,
  );

  /// Writes every section present in this backup into [store]. With sync on,
  /// the launch counts stay out: the bucket already has them, under the
  /// phone that made them, and importing them too would count them twice.
  Future<void> applyTo(LauncherStore store) async {
    if (sync != null) await store.setSyncConfig(sync!);
    final syncOn = (sync ?? store.syncConfig).enabled;
    if (settings != null) await store.setSettings(settings!);
    if (hidden != null) await store.setHidden(hidden!);
    if (removedFromHome != null) await store.setExcluded(removedFromHome!);
    if (pairs != null) await store.setPairs(pairs!);
    if (launchCounts != null && !syncOn) await store.setCounts(launchCounts!);
    if (homeSlots != null) await store.setSlots(homeSlots!);
  }
}

/// Default file name for an export made at [now], e.g. `turbolaunch-settings-261008.json`.
String suggestedSettingsFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'turbolaunch-settings-${two(now.year % 100)}${two(now.month)}${two(now.day)}.json';
}

String encodeSettingsBackup(LauncherBackup b, {required DateTime exportedAt}) {
  final doc = <String, Object?>{
    'app': kSettingsAppId,
    'format': kSettingsFormat,
    'formatVersion': kSettingsFormatVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'containsSecrets': b.containsSecrets,
    'settings': ?b.settings?.toJson(),
    'hiddenApps': ?(b.hidden?.toList()?..sort()),
    'removedFromHome': ?(b.removedFromHome?.toList()?..sort()),
    'appPairs': ?b.pairs?.map((p) => p.toJson()).toList(),
    'launchCounts': ?b.launchCounts,
    'homeSlots': ?b.homeSlots?.map((c, k) => MapEntry(c.toString(), k)),
    'sync': ?b.sync?.toJson(),
  };
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

/// Parses and validates an export. Throws [SettingsImportException] with a
/// plain message when it is not a TurboLaunch file this version can read.
LauncherBackup decodeSettingsBackup(String text) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException {
    throw const SettingsImportException('Not a TurboLaunch settings file: the file is not valid JSON.');
  }
  if (doc is! Map) throw const SettingsImportException('Not a TurboLaunch settings file: expected a JSON object.');
  final app = doc['app'];
  if (app != kSettingsAppId) {
    throw SettingsImportException(
      app is String ? 'This settings file belongs to "$app", not TurboLaunch.' : 'Not a TurboLaunch settings file.',
    );
  }
  if (doc['format'] != kSettingsFormat) {
    throw const SettingsImportException('Not a TurboLaunch settings file: unknown format.');
  }
  final version = doc['formatVersion'];
  if (version is! int || version < 1) {
    throw const SettingsImportException('Invalid settings file: missing or bad format version.');
  }
  if (version > kSettingsFormatVersion) {
    throw SettingsImportException(
      'This settings file uses format version $version, but this TurboLaunch only reads up to version '
      '$kSettingsFormatVersion. Update TurboLaunch and try again.',
    );
  }
  final exportedAt = doc['exportedAt'];
  return LauncherBackup(
    settings: _opt(doc, 'settings', (v) => v is Map ? LauncherSettings.fromJson(Map<String, Object?>.from(v)) : null),
    hidden: _opt(doc, 'hiddenApps', _stringSet),
    removedFromHome: _opt(doc, 'removedFromHome', _stringSet),
    pairs: _opt(doc, 'appPairs', (v) {
      if (v is! List) return null;
      final pairs = v.map(AppPair.fromJson).toList();
      return pairs.contains(null) ? null : pairs.cast<AppPair>();
    }),
    launchCounts: _opt(doc, 'launchCounts', (v) {
      if (v is! Map || v.values.any((n) => n is! int || n < 0)) return null;
      return {for (final e in v.entries) e.key as String: e.value as int};
    }),
    homeSlots: _opt(doc, 'homeSlots', (v) {
      if (v is! Map) return null;
      final slots = <Cell, String>{};
      for (final e in v.entries) {
        final cell = Cell.parse(e.key as String);
        if (cell == null || e.value is! String) return null;
        slots[cell] = e.value as String;
      }
      return slots;
    }),
    sync: _opt(doc, 'sync', (v) => v is Map ? SyncConfig.fromJson(v) : null),
    exportedAt: exportedAt is String ? DateTime.tryParse(exportedAt) : null,
  );
}

Set<String>? _stringSet(Object? v) => v is List && v.every((e) => e is String) ? v.cast<String>().toSet() : null;

/// Reads section [key] with [parse]; absent is null, malformed is an error,
/// so a bad file is rejected before anything is written.
T? _opt<T>(Map<Object?, Object?> doc, String key, T? Function(Object?) parse) {
  final v = doc[key];
  if (v == null) return null;
  return parse(v) ?? (throw SettingsImportException('Invalid settings file: "$key" is malformed.'));
}
