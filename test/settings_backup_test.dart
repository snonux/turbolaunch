import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/app_pairs.dart';
import 'package:turbolaunch/services/home_grid.dart';
import 'package:turbolaunch/services/launcher_store.dart';
import 'package:turbolaunch/services/settings_backup.dart';

void main() {
  final at = DateTime.utc(2026, 10, 8, 12);
  final full = LauncherBackup(
    settings: const LauncherSettings(
      gridRows: 4,
      labelScale: 1.2,
      gestures: {'U': 'search', 'UR': 'launch:pair:a|b', 'L': 'flashlight'},
    ),
    hidden: {'a/a.Main#0'},
    removedFromHome: {'b/b.Main#0'},
    pairs: const [AppPair(name: 'Drive', first: 'a/a.Main#0', second: 'b/b.Main#0')],
    launchCounts: {'a/a.Main#0': 3},
    homeSlots: {const Cell(2, 1): 'a/a.Main#0'},
  );

  Map<String, Object?> doc() => jsonDecode(encodeSettingsBackup(full, exportedAt: at)) as Map<String, Object?>;

  test('round-trips every section', () {
    final back = decodeSettingsBackup(encodeSettingsBackup(full, exportedAt: at));
    expect(back.settings!.toJson(), full.settings!.toJson());
    expect(back.hidden, full.hidden);
    expect(back.removedFromHome, full.removedFromHome);
    expect(back.pairs, full.pairs);
    expect(back.launchCounts, full.launchCounts);
    expect(back.homeSlots, full.homeSlots);
    expect(back.exportedAt, at);
  });

  test('the file names its app and format and says it has no secrets', () {
    final d = doc();
    expect(
      (d['app'], d['format'], d['formatVersion'], d['containsSecrets']),
      ('org.buetow.turbolaunch', 'turbolaunch-settings', 1, false),
    );
    expect(d['homeSlots'], {'2,1': 'a/a.Main#0'});
  });

  test('absent sections stay null, so importing leaves them alone', () {
    final back = decodeSettingsBackup(encodeSettingsBackup(const LauncherBackup(hidden: {'x/y#0'}), exportedAt: at));
    expect(back.hidden, {'x/y#0'});
    expect((back.settings, back.pairs, back.launchCounts, back.homeSlots), (null, null, null, null));
  });

  test('unknown keys are ignored', () {
    final d = doc()..['fromTheFuture'] = 42;
    expect(decodeSettingsBackup(jsonEncode(d)).launchCounts, {'a/a.Main#0': 3});
  });

  void rejects(String text, String message) => expect(
    () => decodeSettingsBackup(text),
    throwsA(isA<SettingsImportException>().having((e) => e.message, 'message', contains(message))),
  );

  test('rejects files that are not TurboLaunch exports or are damaged', () {
    rejects('not json', 'not valid JSON');
    rejects('[]', 'expected a JSON object');
    rejects(jsonEncode({'app': 'org.buetow.quicklog'}), 'belongs to "org.buetow.quicklog"');
    rejects(jsonEncode(doc()..['format'] = 'x'), 'unknown format');
    rejects(jsonEncode(doc()..['formatVersion'] = 2), 'only reads up to version 1');
    rejects(jsonEncode(doc()..['launchCounts'] = {'a': 'many'}), '"launchCounts" is malformed');
    rejects(jsonEncode(doc()..['homeSlots'] = {'x': 'a'}), '"homeSlots" is malformed');
    rejects(
      jsonEncode(
        doc()
          ..['appPairs'] = [
            {'name': 'Same', 'first': 'a', 'second': 'a'},
          ],
      ),
      '"appPairs" is malformed',
    );
  });

  test('the suggested file name carries the date', () {
    expect(suggestedSettingsFileName(DateTime(2026, 1, 5)), 'turbolaunch-settings-260105.json');
  });
}
