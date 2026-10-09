/// S3 sync of launch counts and home cells between phones.
///
/// Every phone writes one file of its own, `<prefix><device id>.json`, and
/// reads the others'; nothing is ever overwritten by another phone. A file
/// holds that phone's own launch counts and its home cells. Each phone adds
/// the other phones' counts to its own, and an app it has not placed yet goes
/// to the cell the other phones give it (see [placeHome]).
///
/// The first time a phone meets other phones, it takes over the grid of the
/// phone with the most launches, if that is another phone. After that, a
/// placed icon never moves again, except to give a lent cell back.
///
/// Apps are named across phones by their sync key, the app key without the
/// user serial (serials differ between phones): `package/activity` for the
/// phone's own profile, `package/activity#work` for another profile, and
/// `pair:<sync key>|<sync key>` for an app pair. Rows count from the bottom,
/// where the grid starts filling, so phones with more or fewer rows agree on
/// the cells nearest the search box.
library;

import 'dart:convert';
import 'dart:math';

import 'home_grid.dart';
import 's3_config.dart';

const String kSyncFormat = 'turbolaunch-sync';
const int kSyncFormatVersion = 1;

/// Where the device files live in the bucket.
const String kSyncPrefix = 'turbolaunch/devices/';

/// The sync key of an app with [key] (`package/activity#serial`).
String appSyncKey(String key, {required bool otherProfile}) {
  final hash = key.lastIndexOf('#');
  final base = hash < 0 ? key : key.substring(0, hash);
  return otherProfile ? '$base#work' : base;
}

/// A random id for this phone's file.
String newDeviceId([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Sync settings: off until switched on, with Quicklog's Garage defaults.
class SyncConfig {
  const SyncConfig({
    this.enabled = false,
    this.endpoint = '',
    this.region = '',
    this.bucket = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.deviceName = '',
  });

  final bool enabled;
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  /// Shown in the other phones' stats; the device id when empty.
  final String deviceName;

  S3Config get s3 => S3Config.fromRaw(
    endpoint: endpoint,
    region: region,
    bucket: bucket,
    accessKeyId: accessKeyId,
    secretAccessKey: secretAccessKey,
  );

  bool get ready => enabled && s3.hasCredentials;

  SyncConfig copyWith({
    bool? enabled,
    String? endpoint,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
    String? deviceName,
  }) => SyncConfig(
    enabled: enabled ?? this.enabled,
    endpoint: endpoint ?? this.endpoint,
    region: region ?? this.region,
    bucket: bucket ?? this.bucket,
    accessKeyId: accessKeyId ?? this.accessKeyId,
    secretAccessKey: secretAccessKey ?? this.secretAccessKey,
    deviceName: deviceName ?? this.deviceName,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'endpoint': endpoint,
    'region': region,
    'bucket': bucket,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'deviceName': deviceName,
  };

  factory SyncConfig.fromJson(Map<Object?, Object?> j) {
    String s(String k) => j[k] is String ? j[k] as String : '';
    return SyncConfig(
      enabled: j['enabled'] == true,
      endpoint: s('endpoint'),
      region: s('region'),
      bucket: s('bucket'),
      accessKeyId: s('accessKeyId'),
      secretAccessKey: s('secretAccessKey'),
      deviceName: s('deviceName'),
    );
  }
}

/// One phone's file: its own launch counts and home cells, by sync key.
class DeviceSync {
  const DeviceSync({
    required this.device,
    this.name = '',
    this.updatedAt,
    this.counts = const {},
    this.cells = const {},
  });

  final String device;
  final String name;
  final DateTime? updatedAt;
  final Map<String, int> counts;

  /// Home cells with rows counted from the bottom (0 is the bottom row).
  final Map<Cell, String> cells;

  String get label => name.trim().isEmpty ? device : name.trim();

  Map<String, Object?> toJson() => {
    'format': kSyncFormat,
    'formatVersion': kSyncFormatVersion,
    'device': device,
    'name': name,
    'updatedAt': ?updatedAt?.toUtc().toIso8601String(),
    'counts': counts,
    'cells': {for (final e in cells.entries) e.key.toString(): e.value},
  };

  String encode() => jsonEncode(toJson());

  /// Null for anything that is not a sync file this version reads.
  static DeviceSync? fromJson(Object? j) {
    if (j is! Map || j['format'] != kSyncFormat) return null;
    final version = j['formatVersion'];
    if (version is! int || version < 1 || version > kSyncFormatVersion) return null;
    final device = j['device'];
    if (device is! String || device.isEmpty) return null;
    final counts = j['counts'], cells = j['cells'];
    final updatedAt = j['updatedAt'];
    return DeviceSync(
      device: device,
      name: j['name'] is String ? j['name'] as String : '',
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      counts: {
        if (counts is Map)
          for (final e in counts.entries)
            if (e.key is String && e.value is int && (e.value as int) > 0) e.key as String: e.value as int,
      },
      cells: {
        if (cells is Map)
          for (final e in cells.entries)
            if (e.key is String && Cell.parse(e.key as String) != null && e.value is String)
              Cell.parse(e.key as String)!: e.value as String,
      },
    );
  }

  static DeviceSync? decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }
}

/// A cell counted from the top of a [rows]-row grid, counted from the bottom, and back.
Cell flipRows(Cell c, int rows) => Cell(rows - 1 - c.row, c.col);

/// The other phones' launch counts, added up per sync key.
Map<String, int> remoteCounts(Iterable<DeviceSync> remote) {
  final sum = <String, int>{};
  for (final d in remote) {
    for (final e in d.counts.entries) {
      sum[e.key] = (sum[e.key] ?? 0) + e.value;
    }
  }
  return sum;
}

/// How many launches [d] has made, which decides whose grid wins.
int launchesOf(DeviceSync d) => d.counts.values.fold(0, (sum, n) => sum + n);

/// Orders phones by launches, most first, then by device id, so every phone
/// ranks them the same way.
int byLaunches(DeviceSync a, DeviceSync b) {
  final byCount = launchesOf(b).compareTo(launchesOf(a));
  return byCount != 0 ? byCount : a.device.compareTo(b.device);
}

/// Where the other phones have their apps, as cells of this phone's
/// [rows]-row grid (counted from the top). When phones disagree, about a cell
/// or about an app's cell, the phone with the most launches wins.
Map<Cell, String> sharedCells(Iterable<DeviceSync> remote, int rows) {
  final shared = <Cell, String>{};
  final taken = <String>{};
  for (final d in remote.toList()..sort(byLaunches)) {
    final cells = d.cells.keys.where((c) => c.row < rows).toList()..sort();
    for (final b in cells) {
      final cell = flipRows(b, rows), key = d.cells[b]!;
      if (shared.containsKey(cell) || taken.contains(key)) continue;
      shared[cell] = key;
      taken.add(key);
    }
  }
  return shared;
}
