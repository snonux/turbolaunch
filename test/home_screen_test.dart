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
    // A fresh app each time, even when a test starts twice.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(TurboLaunchApp(source: source, store: store));
    await tester.pumpAndSettle();
  }

  /// Scrolls the settings page (not a text field inside it) until [f] shows.
  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 100, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open-settings')));
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

    await scrollTo(tester, find.byKey(const Key('grid-cols')));
    await tester.tap(
      find.descendant(of: find.byKey(const Key('grid-cols')), matching: find.byType(DropdownButton<int>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('grid-cols')), matching: find.text('3')), findsOneWidget);

    await scrollTo(tester, find.byKey(const Key('scale-labels')));
    final slider = find.descendant(of: find.byKey(const Key('scale-labels')), matching: find.byType(Slider));
    await tester.drag(slider, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('Grid labels: 160%'), findsOneWidget);

    await scrollTo(tester, find.text('Unhide'));
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
      await scrollTo(tester, find.byKey(Key(picker)));
      await tester.tap(find.byKey(Key(picker)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await scrollTo(tester, find.text('Off: tap to open Accessibility settings'));
    await pick('pair-first', 'Maps');
    await pick('pair-second', 'Music');
    await scrollTo(tester, find.byKey(const Key('open-pair')));
    await tester.tap(find.byKey(const Key('open-pair')));
    await tester.pumpAndSettle();
    expect(source.pairs.single.$1.label, 'Maps');
    expect(source.pairs.single.$2.label, 'Music');
    expect(find.textContaining('Opened Maps only'), findsOneWidget);
  });

  testWidgets('a saved app pair is searchable, opens both apps, earns a cell and can be deleted', (tester) async {
    source.serviceEnabled = true;
    await start(tester);
    await openSettings(tester);
    Future<void> pick(String picker, String label) async {
      await scrollTo(tester, find.byKey(Key(picker)));
      await tester.tap(find.byKey(Key(picker)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await pick('pair-first', 'Maps');
    await pick('pair-second', 'Music');
    await scrollTo(tester, find.byKey(const Key('save-pair')));
    await tester.tap(find.byKey(const Key('save-pair')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved "Maps + Music"'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('search')), 'mapsmus');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(source.pairs.single.$1.label, 'Maps');
    expect(source.pairs.single.$2.label, 'Music');
    expect(source.launched, isEmpty, reason: 'the pair opens through launchPair');
    expect(find.text('Maps + Music'), findsOneWidget, reason: 'the pair took a home cell');

    await tester.longPress(find.text('Maps + Music'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-uninstall')), findsNothing);
    await tester.tap(find.byKey(const Key('menu-delete-pair')));
    await tester.pumpAndSettle();
    expect(find.text('Maps + Music'), findsNothing);
  });

  testWidgets('double-tap on empty home space locks, or explains the accessibility service', (tester) async {
    await start(tester);
    await tester.tap(find.byKey(const Key('empty-0-0')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('empty-0-0')));
    await tester.pumpAndSettle();
    expect(source.locks, 0);
    expect(find.textContaining('needs TurboLaunch actions'), findsOneWidget);

    source.serviceEnabled = true;
    await tester.tap(find.byKey(const Key('empty-0-0')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('empty-0-0')));
    await tester.pumpAndSettle();
    expect(source.locks, 1);
  });

  testWidgets('swipe down on home opens the notification shade, unless turned off', (tester) async {
    await start(tester);
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(source.shades, 1);

    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('swipe-notifications')));
    await tester.tap(find.byKey(const Key('swipe-notifications')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(source.shades, 1);
  });

  testWidgets('the stats screen lists launch counts and home cells', (tester) async {
    await start(tester, {
      'launchCounts':
          '{"org.example.maps/org.example.maps.Main#0": 5, "org.example.music/org.example.music.Main#0": 2}',
    });
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('open-stats')));
    await tester.pumpAndSettle();
    expect(find.text('7 launches on this phone'), findsOneWidget);
    final maps = tester.getTopLeft(find.byKey(const ValueKey('stat-org.example.maps/org.example.maps.Main#0')));
    final music = tester.getTopLeft(find.byKey(const ValueKey('stat-org.example.music/org.example.music.Main#0')));
    expect(maps.dy, lessThan(music.dy), reason: 'most-launched first');
    expect(find.textContaining('Home row 1, column 1'), findsOneWidget);
  });

  testWidgets('settings export and import round-trip, a bad file changes nothing', (tester) async {
    await start(tester);
    await openSearch(tester);
    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('export-settings')));
    await tester.tap(find.byKey(const Key('export-settings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved to turbolaunch-settings-'), findsOneWidget);
    final exported = source.fileToOpen!;

    // Start over on a "new phone" and import the file.
    await start(tester);
    source.fileToOpen = '{"app": "org.buetow.quicklog"}';
    await openSettings(tester);
    Future<void> import() async {
      await scrollTo(tester, find.byKey(const Key('import-settings')));
      await tester.tap(find.byKey(const Key('import-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-import')));
      await tester.pumpAndSettle();
    }

    await import();
    expect(find.textContaining('belongs to "org.buetow.quicklog"'), findsOneWidget);
    source.fileToOpen = exported;
    await import();
    expect(find.text('Settings imported.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Maps'), findsOneWidget, reason: 'the imported grid has Maps');
  });

  testWidgets('apps of a paused work profile still show, with the work badge', (tester) async {
    source.apps = [
      app('Calendar'),
      const AppEntry(key: 'org.example.mail/org.example.mail.Main#10', label: 'Mail', otherProfile: true, paused: true),
    ];
    await start(tester);
    await openSearch(tester);
    expect(find.text('Mail'), findsOneWidget);
    expect(find.byIcon(Icons.work_outline), findsOneWidget);
    expect(find.byType(ColorFiltered), findsOneWidget, reason: 'paused apps are drawn in grey');
  });
}
