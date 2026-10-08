import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_platform/launcher_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/main.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/launcher_store.dart';

AppEntry app(String label) {
  final p = 'org.example.${label.toLowerCase()}';
  return AppEntry(key: '$p/$p.Main#0', label: label);
}

void main() {
  late FakeAppSource source;

  setUp(() {
    source = FakeAppSource(
      [app('Calendar'), app('Maps'), app('Music')],
      shortcuts: const [ShortcutEntry(packageName: 'org.example.maps', id: 'h', userSerial: 0, label: 'Navigate home')],
    );
  });

  Future<void> start(WidgetTester tester, [Map<String, Object> prefs = const {}]) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final store = await LauncherStore.open();
    await tester.pumpWidget(TurboLaunchApp(source: source, store: store));
    await tester.pumpAndSettle();
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('search')));
    await tester.pumpAndSettle();
  }

  testWidgets('the home screen starts with an empty grid, the clock and the search box', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
    expect(find.byKey(const Key('clock-line')), findsOneWidget);
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('Maps'), findsNothing, reason: 'never-launched apps get no cell');
  });

  testWidgets('tapping the search box lists every app; tapping one launches it and puts it on the grid', (
    tester,
  ) async {
    await start(tester);
    await openSearch(tester);
    expect(find.text('Calendar'), findsOneWidget);
    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();
    expect(source.launched.single.label, 'Maps');
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
    expect(find.text('Maps'), findsOneWidget, reason: 'Maps now has a cell');
    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();
    expect(source.launched, hasLength(2));
  });

  testWidgets('fuzzy typing narrows the results, Enter launches the top match', (tester) async {
    await start(tester);
    await tester.enterText(find.byKey(const Key('search')), 'mc');
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsNothing);
    expect(find.byKey(const ValueKey('org.example.music/org.example.music.Main#0')), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(source.launched.single.label, 'Music');
  });

  testWidgets('app shortcuts are searchable and start', (tester) async {
    await start(tester);
    await tester.enterText(find.byKey(const Key('search')), 'navh');
    await tester.pumpAndSettle();
    expect(find.text('Maps'), findsOneWidget, reason: 'the owning app is the subtitle');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(source.shortcutsStarted.single.id, 'h');
  });

  testWidgets('Home clears the search and closes settings', (tester) async {
    await start(tester);
    await tester.enterText(find.byKey(const Key('search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No match'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    source.pressHome();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
    expect(find.text('No match'), findsNothing);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
  });

  testWidgets('long-press menu: hide, remove from home, uninstall', (tester) async {
    await start(tester);
    await openSearch(tester);
    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Maps'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-unpin')));
    await tester.pumpAndSettle();
    expect(find.text('Maps'), findsNothing);

    await openSearch(tester);
    await tester.longPress(find.text('Music'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-hide')));
    await tester.pumpAndSettle();
    await openSearch(tester);
    expect(find.text('Music'), findsNothing);

    await tester.longPress(find.text('Calendar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-uninstall')));
    await tester.pumpAndSettle();
    expect(source.uninstalled.single.label, 'Calendar');
  });

  testWidgets('long-press on the clock hides the grid until the next long-press', (tester) async {
    await start(tester);
    await tester.longPress(find.byKey(const Key('clock-line')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-grid')), findsNothing);
    expect(find.byKey(const Key('quick-hidden')), findsOneWidget);
    await tester.longPress(find.byKey(const Key('clock-line')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
  });

  testWidgets('an installed app shows up without a restart', (tester) async {
    await start(tester);
    source.apps = [app('Calendar'), app('Notes')];
    await tester.pumpAndSettle();
    await openSearch(tester);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('Maps'), findsNothing);
  });

  testWidgets('settings: wallpaper, grid columns, font size, hidden apps', (tester) async {
    await start(tester, {
      'hiddenApps': <String>['org.example.music/org.example.music.Main#0'],
    });
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('wallpaper-lock')));
    await tester.pumpAndSettle();
    expect(source.wallpapers, [WallpaperTarget.lock]);
    expect(find.text('Wallpaper set.'), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const Key('grid-cols')), 100);
    await tester.tap(
      find.descendant(of: find.byKey(const Key('grid-cols')), matching: find.byType(DropdownButton<int>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('grid-cols')), matching: find.text('3')), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const Key('scale-labels')), 100);
    final slider = find.descendant(of: find.byKey(const Key('scale-labels')), matching: find.byType(Slider));
    await tester.drag(slider, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('Grid labels: 160%'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Unhide'), 100);
    await tester.tap(find.text('Unhide'));
    await tester.pumpAndSettle();
    expect(find.text('Hidden apps'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openSearch(tester);
    expect(find.text('Music'), findsOneWidget);
  });

  testWidgets('settings opens an app pair and reports a missing service', (tester) async {
    await start(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();

    Future<void> pick(String picker, String label) async {
      await tester.scrollUntilVisible(find.byKey(Key(picker)), 100);
      await tester.tap(find.byKey(Key(picker)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await tester.scrollUntilVisible(find.text('Off: tap to open Accessibility settings'), 100);
    await pick('pair-first', 'Maps');
    await pick('pair-second', 'Music');
    await tester.scrollUntilVisible(find.byKey(const Key('open-pair')), 100);
    await tester.tap(find.byKey(const Key('open-pair')));
    await tester.pumpAndSettle();
    expect(source.pairs.single.$1.label, 'Maps');
    expect(source.pairs.single.$2.label, 'Music');
    expect(find.textContaining('Opened Maps only'), findsOneWidget);
  });
}
