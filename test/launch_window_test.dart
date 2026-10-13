import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/home_grid.dart';
import 'package:turbolaunch/services/launch_log.dart';
import 'package:turbolaunch/services/launcher_controller.dart';
import 'package:turbolaunch/services/launcher_store.dart';
import 'package:turbolaunch/services/settings_backup.dart';
import 'package:turbolaunch/services/sync.dart';

import 'sync_test.dart' show MemoryBucket;

AppEntry app(String name) => AppEntry(key: 'org.$name/org.$name.Main#0', label: name);

void main() {
  group('launch days', () {
    final now = DateTime.utc(2026, 10, 11, 5);

    test('a window of n days starts n - 1 days before today; 0 has no start', () {
      expect(launchDay(now), '2026-10-11');
      expect(windowStart(now, 30), '2026-09-12');
      expect(windowStart(now, 1), '2026-10-11');
      expect(windowStart(now, 0), '');
    });

    test('counts only the days in the window, and purges the others', () {
      final days = {
        'a': {'2026-09-11': 5, '2026-09-12': 1, '2026-10-11': 2},
        'b': {'2026-08-01': 9},
      };
      expect(windowCounts(days, '2026-09-12'), {'a': 3});
      expect(windowCounts(days, ''), {'a': 8, 'b': 9});
      expect(purgeBefore(days, '2026-09-12'), {
        'a': {'2026-09-12': 1, '2026-10-11': 2},
      });
      expect(purgeBefore(days, '2026-01-01'), same(days), reason: 'nothing older, nothing written');
    });

    test('old counts become launches of one day; bad entries are skipped', () {
      expect(daysFromCounts({'a': 3, 'b': 0}, '2026-10-11'), {
        'a': {'2026-10-11': 3},
      });
      expect(
        parseLaunchDays({
          'a': {'2026-10-11': 2, 'yesterday': 1, '2026-10-10': -1},
          'b': 'x',
          'c': {'2026-10-11': 'many'},
        }),
        {
          'a': {'2026-10-11': 2},
        },
      );
      expect(parseLaunchDays('x'), isNull);
    });
  });

  group('the launch window on one phone', () {
    late DateTime now;
    final maps = app('maps'), mail = app('mail'), chat = app('chat');

    Future<LauncherController> start(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = LauncherController(FakeAppSource([maps, mail, chat]), await LauncherStore.open(), clock: () => now);
      await c.refresh();
      c.setAutoGridSize(1, 3);
      return c;
    }

    setUp(() => now = DateTime.utc(2026, 10, 11, 12));

    test('only the last 30 days count, older days are purged, and the grid follows', () async {
      final c = await start({
        'launchDays': jsonEncode({
          maps.key: {'2026-09-01': 50, '2026-10-10': 1},
          mail.key: {'2026-10-01': 3},
        }),
      });
      expect(c.settings.launchWindowDays, 30);
      expect(c.counts, {maps.key: 1, mail.key: 3});
      expect(c.grid, {const Cell(0, 2): mail, const Cell(0, 1): maps}, reason: 'mail is most launched now');
      final store = c.store;
      expect(store.launchDays![maps.key], {'2026-10-10': 1}, reason: 'September 1 is purged');

      // Five weeks on, every day so far has left the window.
      now = DateTime.utc(2026, 11, 15, 12);
      await c.launch(chat);
      expect(c.counts, {chat.key: 1});
      expect(store.launchDays, {
        chat.key: {'2026-11-15': 1},
      });
      c.dispose();
    });

    test('counts from before launch days count as made today and age out', () async {
      final c = await start({
        'launchCounts': jsonEncode({maps.key: 7}),
      });
      expect(c.counts, {maps.key: 7});
      expect(c.store.launchDays, {
        maps.key: {'2026-10-11': 7},
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('launchCounts'), isFalse);
      now = DateTime.utc(2026, 11, 10, 12);
      expect(c.counts, isEmpty);
      c.dispose();
    });

    test('the window is a setting; all time keeps every launch', () async {
      final c = await start({
        'launchDays': jsonEncode({
          maps.key: {'2026-10-01': 2, '2026-10-11': 1},
        }),
      });
      expect(c.counts[maps.key], 3);
      c.updateSettings(c.settings.copyWith(launchWindowDays: 7));
      expect(c.counts[maps.key], 1);
      c.updateSettings(c.settings.copyWith(launchWindowDays: 0));
      expect(c.counts[maps.key], 1, reason: 'the shorter window purged October 1');
      now = DateTime.utc(2030);
      expect(c.counts[maps.key], 1, reason: 'all time never purges');
      c.dispose();
    });
  });

  group('the launch window and sync', () {
    late MemoryBucket bucket;
    late DateTime now;
    final maps = app('maps'), mail = app('mail');

    Future<LauncherController> phone(Map<String, Object> prefs, {int window = 30}) async {
      SharedPreferences.setMockInitialValues(prefs);
      final store = LauncherStore(await SharedPreferences.getInstance());
      await store.setSyncConfig(const SyncConfig(enabled: true, accessKeyId: 'id', secretAccessKey: 'secret'));
      await store.setSettings(LauncherSettings(launchWindowDays: window));
      final c = LauncherController(FakeAppSource([maps, mail]), store, s3Client: (_) => bucket, clock: () => now);
      await c.refresh();
      c.setAutoGridSize(1, 2);
      return c;
    }

    setUp(() {
      bucket = MemoryBucket();
      now = DateTime.utc(2026, 10, 11, 12);
    });

    test("each phone counts the others' days over its own window and warns when the windows differ", () async {
      final a = await phone({
        'launchDays': jsonEncode({
          maps.key: {'2026-10-01': 4},
        }),
      });
      await a.sync();
      final b = await phone({
        'launchDays': jsonEncode({
          mail.key: {'2026-10-10': 1},
        }),
      }, window: 7);
      await b.sync();
      await a.sync();

      final file = DeviceSync.decode(utf8.decode(bucket.objects.values.first))!;
      expect(file.windowDays, isNotNull);
      expect(file.days, isNotNull);

      expect(b.totals, {mail.key: 1}, reason: "a's October 1 is outside b's 7 days");
      expect(a.totals, {maps.key: 4, mail.key: 1});
      expect(a.windowMismatches.single.windowDays, 7);
      expect(windowWarning(a.windowMismatches), contains('counts the last 7 days'));
      expect(windowWarning(b.windowMismatches), contains('counts the last 30 days'));

      b.updateSettings(b.settings.copyWith(launchWindowDays: 30));
      await b.sync();
      await a.sync();
      expect(a.windowMismatches, isEmpty);
      expect(b.windowMismatches, isEmpty);
      expect(b.totals, {maps.key: 4, mail.key: 1});
      a.dispose();
      b.dispose();
    });

    test('a file from before the window adds its counts as they are and is warned about', () async {
      bucket.objects['${kSyncPrefix}old.json'] = utf8.encode(
        jsonEncode({
          'format': 'turbolaunch-sync',
          'formatVersion': 1,
          'device': 'old',
          'name': 'Old phone',
          'counts': {'org.maps/org.maps.Main': 6},
        }),
      );
      final a = await phone({});
      await a.sync();
      expect(a.totals, {maps.key: 6});
      expect(windowWarning(a.windowMismatches), contains('Old phone counts all launches (an older TurboLaunch)'));
      a.updateSettings(a.settings.copyWith(launchWindowDays: 0));
      expect(a.windowMismatches, isEmpty, reason: 'it counts every launch too');
      a.dispose();
    });
  });

  group('export and import', () {
    test('carry the launch days; an old file counts its launches as made on the import day', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LauncherStore(await SharedPreferences.getInstance());
      final now = DateTime.utc(2026, 10, 11);
      final days = {
        'a/a.Main#0': {'2026-10-01': 2, '2026-10-11': 1},
      };
      await store.setLaunchDays(days);
      await store.setSettings(const LauncherSettings(launchWindowDays: 7));
      final text = encodeSettingsBackup(LauncherBackup.fromStore(store, now: now), exportedAt: now);
      final back = decodeSettingsBackup(text);
      expect(back.launchDays, days);
      expect(back.launchCounts, {'a/a.Main#0': 1}, reason: 'the window, for older versions');

      await store.setLaunchDays({});
      await back.applyTo(store, now: now);
      expect(store.launchDays, days);

      await const LauncherBackup(launchCounts: {'b/b.Main#0': 4}).applyTo(store, now: now);
      expect(store.launchDays, {
        'b/b.Main#0': {'2026-10-11': 4},
      });
    });
  });
}
