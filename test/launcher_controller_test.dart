import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/home_grid.dart';
import 'package:turbolaunch/services/launcher_controller.dart';
import 'package:turbolaunch/services/launcher_store.dart';

AppEntry app(String label, [String? pkg]) {
  final p = pkg ?? 'org.example.${label.toLowerCase().replaceAll(' ', '')}';
  return AppEntry(key: '$p/$p.Main#0', label: label);
}

void main() {
  late FakeAppSource source;
  late LauncherStore store;
  late LauncherController c;

  Future<LauncherController> start([Map<String, Object> prefs = const {}]) async {
    SharedPreferences.setMockInitialValues(prefs);
    store = await LauncherStore.open();
    final controller = LauncherController(source, store);
    await controller.refresh();
    controller.setAutoGridSize(2, 2);
    return controller;
  }

  setUp(() async {
    source = FakeAppSource(
      [app('maps'), app('Calendar'), app('Music'), app('Organic Maps'), app('Notes')],
      shortcuts: const [ShortcutEntry(packageName: 'org.example.notes', id: 'n', userSerial: 0, label: 'New note')],
    );
    c = await start();
  });

  tearDown(() => c.dispose());

  List<String> titles() => c.results.map((r) => r.title).toList();

  test('an empty query lists every app alphabetically, ignoring case', () {
    expect(titles(), ['Calendar', 'maps', 'Music', 'Notes', 'Organic Maps']);
  });

  test('fuzzy search ranks word starts and shows shortcuts', () {
    c.query = 'om';
    expect(titles().first, 'Organic Maps');
    c.query = 'new no';
    expect(titles(), ['New note']);
    expect(c.results.single.owner!.label, 'Notes');
    c.query = 'zzz';
    expect(titles(), isEmpty);
  });

  test('launch counts break ties in search', () async {
    source.apps = [app('Mail'), app('Maps')];
    await pumpEventQueue();
    c.query = 'ma';
    expect(titles(), ['Mail', 'Maps']);
    await c.launch(c.apps.firstWhere((a) => a.label == 'Maps'));
    c.query = 'ma';
    expect(titles(), ['Maps', 'Mail']);
  });

  test('Enter launches the top match, counts it and clears the query', () async {
    c.query = 'mus';
    expect(await c.launchTopMatch(), isTrue);
    expect(source.launched.single.label, 'Music');
    expect(c.query, isEmpty);
    expect(c.counts[source.launched.single.key], 1);
  });

  test('Enter on a shortcut starts it', () async {
    c.query = 'new note';
    expect(await c.launchTopMatch(), isTrue);
    expect(source.shortcutsStarted.single.label, 'New note');
  });

  test('Enter with an empty query or no match launches nothing', () async {
    expect(await c.launchTopMatch(), isFalse);
    c.query = 'zzz';
    expect(await c.launchTopMatch(), isFalse);
    expect(source.launched, isEmpty);
  });

  test('arranged by launches: the most launched bottom right, an overtaken app moves left', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final cal = c.apps.firstWhere((a) => a.label == 'Calendar');
    await c.launch(music);
    expect(c.grid, {const Cell(1, 1): music});
    await c.launch(cal);
    await c.launch(cal);
    expect(c.grid, {const Cell(1, 1): cal, const Cell(1, 0): music});
  });

  test('with the home screen in front, the arrangement waits until it is left or Home is pressed', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final cal = c.apps.firstWhere((a) => a.label == 'Calendar');
    await c.launch(music);
    c.setInFront(true);
    await c.launch(cal);
    await c.launch(cal);
    expect(c.grid, {const Cell(1, 1): music}, reason: 'nothing moves under a finger');
    c.setInFront(false);
    expect(c.grid, {const Cell(1, 1): cal, const Cell(1, 0): music});
    c.setInFront(true);
    await c.launch(music);
    await c.launch(music);
    expect(c.grid[const Cell(1, 1)], cal);
    source.pressHome();
    await pumpEventQueue();
    expect(c.grid, {const Cell(1, 1): music, const Cell(1, 0): cal});
    c.setHidden(music, true);
    expect(c.grid, {const Cell(1, 0): cal}, reason: 'a hidden app leaves at once');
  });

  test('turned off, launched apps fill the grid from the bottom row and stay put', () async {
    c.updateSettings(c.settings.copyWith(autoArrange: false));
    c.setAutoGridSize(2, 2);
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final cal = c.apps.firstWhere((a) => a.label == 'Calendar');
    await c.launch(music);
    expect(c.grid, {const Cell(1, 0): music});
    for (var i = 0; i < 5; i++) {
      await c.launch(cal);
    }
    expect(c.grid, {const Cell(1, 0): music, const Cell(1, 1): cal}, reason: 'Music keeps its cell');
  });

  group('rotating the screen and back keeps the grid', () {
    Future<void> launchAll() async {
      var times = 1;
      for (final a in [...c.apps]) {
        for (var i = 0; i < times; i++) {
          await c.launch(a);
        }
        times++;
      }
    }

    test('arranged by launches, with the home screen in front', () async {
      c.setAutoGridSize(3, 2);
      await launchAll();
      c.setInFront(false);
      c.setInFront(true);
      final before = c.grid;
      expect(before, hasLength(5));
      c.setAutoGridSize(1, 4);
      expect(c.grid, hasLength(4), reason: 'the new size is arranged at once');
      expect(c.grid.containsKey(const Cell(0, 3)), isTrue, reason: 'the most launched app bottom right');
      c.setAutoGridSize(3, 2);
      expect(c.grid, before);
      // A launch in landscape waits for the home screen to be left.
      c.setAutoGridSize(1, 4);
      await c.launch(c.apps.first);
      c.setAutoGridSize(3, 2);
      expect(c.grid, before);
    });

    test('with arranging off', () async {
      c.updateSettings(c.settings.copyWith(autoArrange: false));
      c.setAutoGridSize(3, 2);
      await launchAll();
      final before = c.grid;
      expect(before, hasLength(5));
      c.setAutoGridSize(1, 4);
      expect(c.grid, hasLength(4));
      c.setAutoGridSize(3, 2);
      expect(c.grid, before);
    });

    test('across a restart', () async {
      c.setAutoGridSize(3, 2);
      await launchAll();
      c.setInFront(true);
      final before = c.grid;
      c.setAutoGridSize(1, 4);
      final prefs = await SharedPreferences.getInstance();
      final saved = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
      final again = await start(saved);
      again.setInFront(true);
      again.setAutoGridSize(3, 2);
      expect(again.grid, before);
      again.dispose();
    });
  });

  test('cells, counts and hidden apps survive a restart', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    await c.launch(music);
    c.setHidden(c.apps.firstWhere((a) => a.label == 'Notes'), true);
    final prefs = await SharedPreferences.getInstance();
    final saved = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
    final again = await start(saved);
    expect(again.grid, {const Cell(1, 1): music});
    expect(again.counts[music.key], 1);
    expect(again.hidden, {'org.example.notes/org.example.notes.Main#0'});
    again.dispose();
  });

  test('removing from home keeps an app off until pinned again', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    await c.launch(music);
    c.removeFromHome(music);
    await c.launch(music);
    expect(c.grid, isEmpty);
    c.pinToHome(music);
    expect(c.grid, {const Cell(1, 1): music});
  });

  test('hidden apps leave the grid and the list but match an exact search', () async {
    final notes = c.apps.firstWhere((a) => a.label == 'Notes');
    await c.launch(notes);
    c.setHidden(notes, true);
    expect(c.grid, isEmpty);
    expect(titles(), isNot(contains('Notes')));
    c.query = 'note';
    expect(titles(), isNot(contains('Notes')));
    expect(titles(), isNot(contains('New note')), reason: "a hidden app's shortcuts are hidden too");
    c.query = 'notes';
    expect(titles(), ['Notes']);
  });

  test('uninstalling frees the cell', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    await c.launch(music);
    source.apps = [app('Calendar')];
    await pumpEventQueue();
    expect(c.grid, isEmpty);
  });

  test('grid size overrides win over the automatic size', () {
    c.updateSettings(c.settings.copyWith(gridCols: 4));
    c.setAutoGridSize(5, 3);
    expect((c.rows, c.cols), (5, 4));
  });

  test('quick hide is remembered', () async {
    c.toggleQuickHide();
    expect(c.quickHide, isTrue);
    expect(store.quickHide, isTrue);
  });

  test('a Home press clears the query and is counted', () async {
    c.query = 'cal';
    source.pressHome();
    await pumpEventQueue();
    expect(c.query, isEmpty);
    expect(c.homePresses, 1);
  });

  test('settings round-trip and clamp bad values', () {
    const s = LauncherSettings(gridRows: 3, labelScale: 1.4, keyboardOnHome: true, showBattery: true);
    final back = LauncherSettings.fromJson(s.toJson());
    expect((back.gridRows, back.labelScale, back.keyboardOnHome, back.showBattery), (3, 1.4, true, true));
    expect(LauncherSettings.fromJson({'labelScale': 9, 'gridCols': 99}).labelScale, LauncherSettings.maxScale);
    expect(LauncherSettings.fromJson({'gridCols': 99}).gridCols, 12);
    expect(LauncherSettings.fromJson({}).autoArrange, isTrue, reason: 'on by default, also for older files');
    expect(LauncherSettings.fromJson(s.copyWith(autoArrange: false).toJson()).autoArrange, isFalse);
    expect(LauncherSettings.fromJson({}).showBattery, isFalse, reason: 'battery off when the key is absent');
    expect(LauncherSettings.fromJson({'showBattery': false}).showBattery, isFalse);
    expect(const LauncherSettings().showBattery, isFalse);
  });

  test('AppEntry exposes the package name of its key', () {
    expect(app('Maps', 'app.organicmaps').packageName, 'app.organicmaps');
  });

  test('a pair is an app while both its apps are installed', () async {
    final maps = c.apps.firstWhere((a) => a.label == 'maps');
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final pair = c.addPair(maps, music);
    expect(pair.name, 'maps + Music');
    expect(titles(), contains('maps + Music'));
    c.query = 'mapsmus';
    expect(titles().first, 'maps + Music');

    expect(await c.launchTopMatch(), isTrue);
    expect(source.pairs.single, (maps, music));
    expect(c.counts[pair.key], 1);
    expect(c.grid.values.single.key, pair.key, reason: 'a launched pair earns a cell');

    source.apps = [app('maps'), app('Calendar')];
    await pumpEventQueue();
    expect(titles(), isNot(contains('maps + Music')), reason: 'Music is gone');
    expect(c.grid, isEmpty);
    expect(c.pairs, [pair], reason: 'the pair itself is kept');
  });

  test('deleting a pair frees its cell; saving the same two apps again renames it', () async {
    final maps = c.apps.firstWhere((a) => a.label == 'maps');
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    c.addPair(maps, music);
    final renamed = c.addPair(maps, music, name: 'Drive');
    expect(c.pairs, [renamed]);
    await c.launch(c.apps.firstWhere((a) => a.isPair));
    expect(c.grid, isNotEmpty);
    c.removePair(renamed);
    expect(c.grid, isEmpty);
    expect(store.pairs, isEmpty);
  });

  test('stats list launched apps, most-launched first, with their cells', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final cal = c.apps.firstWhere((a) => a.label == 'Calendar');
    await c.launch(music);
    await c.launch(cal);
    await c.launch(cal);
    expect(
      [for (final s in c.stats) (s.app.label, s.launches, s.cell)],
      [('Calendar', 2, const Cell(1, 1)), ('Music', 1, const Cell(1, 0))],
    );
  });

  test('export and import carry settings, pairs, counts and cells to another phone', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    await c.launch(music);
    c.addPair(c.apps.firstWhere((a) => a.label == 'maps'), music);
    c.setHidden(c.apps.firstWhere((a) => a.label == 'Notes'), true);
    c.updateSettings(c.settings.copyWith(gridCols: 3, doubleTapLock: false));
    expect(await c.exportSettings(now: DateTime(2026, 10, 8)), 'turbolaunch-settings-261008.json');
    final file = source.fileToOpen!;

    final other = await start();
    expect(other.grid, isEmpty);
    source.fileToOpen = file;
    expect(await other.importSettings(), isTrue);
    other.setAutoGridSize(2, 2);
    expect(other.grid, {const Cell(1, 2): music});
    expect(other.pairs.single.name, 'maps + Music');
    expect(other.hidden, {'org.example.notes/org.example.notes.Main#0'});
    expect((other.settings.gridCols, other.settings.doubleTapLock), (3, false));
    other.dispose();
  });

  test('a cancelled import changes nothing', () async {
    source.fileToOpen = null;
    expect(await c.importSettings(), isFalse);
  });

  test('a cold start shows the last app list at once, then the current one', () async {
    // The first run listed the apps and kept them.
    final prefs = Map<String, Object>.from({
      'appSnapshot': (await SharedPreferences.getInstance()).getString('appSnapshot')!,
    });
    final slow = _SlowSource([app('Calendar'), app('Notes'), app('Weather')]);
    SharedPreferences.setMockInitialValues(prefs);
    final next = LauncherController(slow, await LauncherStore.open());
    addTearDown(next.dispose);
    expect(next.loaded, isTrue);
    expect(next.apps.map((a) => a.label), ['Calendar', 'maps', 'Music', 'Notes', 'Organic Maps']);

    final refreshed = next.refresh();
    slow.appsDone.complete();
    slow.shortcutsDone.complete();
    await refreshed;
    expect(next.apps.map((a) => a.label), ['Calendar', 'Notes', 'Weather']);
  });

  test('apps show before the shortcuts are listed', () async {
    final slow = _SlowSource(
      [app('Notes')],
      shortcuts: const [ShortcutEntry(packageName: 'org.example.notes', id: 'n', userSerial: 0, label: 'New note')],
    );
    SharedPreferences.setMockInitialValues({});
    final next = LauncherController(slow, await LauncherStore.open());
    addTearDown(next.dispose);
    expect(next.loaded, isFalse, reason: 'no list from an earlier run');
    final refreshed = next.refresh();
    slow.appsDone.complete();
    await pumpEventQueue();
    expect(next.loaded, isTrue);
    expect(next.apps.map((a) => a.label), ['Notes']);
    slow.shortcutsDone.complete();
    await refreshed;
    next.query = 'new';
    expect(next.results.map((r) => r.title), ['New note']);
  });
}

/// Lists apps and shortcuts only when the test says so.
class _SlowSource extends FakeAppSource {
  _SlowSource(super.apps, {super.shortcuts});

  final appsDone = Completer<void>();
  final shortcutsDone = Completer<void>();

  @override
  Future<List<AppEntry>> listApps() async {
    await appsDone.future;
    return super.listApps();
  }

  @override
  Future<List<ShortcutEntry>> shortcuts() async {
    await shortcutsDone.future;
    return super.shortcuts();
  }
}
