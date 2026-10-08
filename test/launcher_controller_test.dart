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

  test('launched apps fill the grid from the bottom row and stay put', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    final cal = c.apps.firstWhere((a) => a.label == 'Calendar');
    await c.launch(music);
    expect(c.grid, {const Cell(1, 0): music});
    for (var i = 0; i < 5; i++) {
      await c.launch(cal);
    }
    expect(c.grid, {const Cell(1, 0): music, const Cell(1, 1): cal}, reason: 'Music keeps its cell');
  });

  test('cells, counts and hidden apps survive a restart', () async {
    final music = c.apps.firstWhere((a) => a.label == 'Music');
    await c.launch(music);
    c.setHidden(c.apps.firstWhere((a) => a.label == 'Notes'), true);
    final prefs = await SharedPreferences.getInstance();
    final saved = {for (final k in prefs.getKeys()) k: prefs.get(k)!};
    final again = await start(saved);
    expect(again.grid, {const Cell(1, 0): music});
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
    expect(c.grid, {const Cell(1, 0): music});
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
    const s = LauncherSettings(gridRows: 3, labelScale: 1.4, keyboardOnHome: true);
    final back = LauncherSettings.fromJson(s.toJson());
    expect((back.gridRows, back.labelScale, back.keyboardOnHome), (3, 1.4, true));
    expect(LauncherSettings.fromJson({'labelScale': 9, 'gridCols': 99}).labelScale, LauncherSettings.maxScale);
    expect(LauncherSettings.fromJson({'gridCols': 99}).gridCols, 12);
  });

  test('AppEntry exposes the package name of its key', () {
    expect(app('Maps', 'app.organicmaps').packageName, 'app.organicmaps');
  });
}
