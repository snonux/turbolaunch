import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/launcher_controller.dart';

AppEntry app(String label, [String? pkg]) {
  final p = pkg ?? 'org.example.${label.toLowerCase().replaceAll(' ', '')}';
  return AppEntry(key: '$p/$p.Main#0', label: label);
}

void main() {
  late FakeAppSource source;
  late LauncherController c;

  setUp(() async {
    source = FakeAppSource([app('maps'), app('Calendar'), app('Music'), app('Organic Maps')]);
    c = LauncherController(source);
    await c.refresh();
  });

  tearDown(() => c.dispose());

  test('lists apps alphabetically, ignoring case', () {
    expect(c.apps.map((a) => a.label), ['Calendar', 'maps', 'Music', 'Organic Maps']);
  });

  test('filters by substring, ignoring case', () {
    c.query = 'MAP';
    expect(c.visible.map((a) => a.label), ['maps', 'Organic Maps']);
    c.query = '  ';
    expect(c.visible, hasLength(4));
  });

  test('Enter launches the top match and clears the query', () async {
    c.query = 'mus';
    expect(await c.launchTopMatch(), isTrue);
    expect(source.launched.single.label, 'Music');
    expect(c.query, isEmpty);
  });

  test('Enter with an empty query or no match launches nothing', () async {
    expect(await c.launchTopMatch(), isFalse);
    c.query = 'zzz';
    expect(await c.launchTopMatch(), isFalse);
    expect(source.launched, isEmpty);
  });

  test('a Home press clears the query and is counted', () async {
    c.query = 'cal';
    source.pressHome();
    await pumpEventQueue();
    expect(c.query, isEmpty);
    expect(c.homePresses, 1);
  });

  test('a package change lists the apps again', () async {
    source.apps = [app('Notes')];
    await pumpEventQueue();
    expect(c.apps.map((a) => a.label), ['Notes']);
  });

  test('AppEntry exposes the package name of its key', () {
    expect(app('Maps', 'app.organicmaps').packageName, 'app.organicmaps');
  });
}
