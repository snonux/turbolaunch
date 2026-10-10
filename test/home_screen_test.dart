import 'dart:async';
import 'dart:convert';

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

  testWidgets('a cold start draws the placed apps on its very first frame', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    // The last run left an app list and a placed app; this run's list never arrives.
    SharedPreferences.setMockInitialValues({
      'appSnapshot': '[{"key": "org.example.maps/org.example.maps.Main#0", "label": "Maps"}]',
      'homeSlots': '{"6,0": "org.example.maps/org.example.maps.Main#0"}',
      'launchCounts': '{"org.example.maps/org.example.maps.Main#0": 3}',
    });
    final store = await LauncherStore.open();
    await tester.pumpWidget(TurboLaunchApp(source: _NeverListing(), store: store));
    expect(find.byKey(const ValueKey('cell-org.example.maps/org.example.maps.Main#0')), findsOneWidget);
  });

  testWidgets('the home screen starts with an empty grid, the clock and the search box', (tester) async {
    await start(tester);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
    expect(find.byKey(const Key('clock-line')), findsOneWidget);
    expect(find.text('87%'), findsNothing, reason: 'battery is off by default');
    expect(find.text('Maps'), findsNothing, reason: 'never-launched apps get no cell');
  });

  testWidgets('a week without a sync shows a warning that opens the sync screen', (tester) async {
    final since = DateTime.now().subtract(const Duration(days: 8)).toUtc().toIso8601String();
    await start(tester, {'syncConfig': '{"enabled": true}', 'syncSince': since});
    expect(find.byKey(const Key('sync-warning')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-warning')));
    await tester.pumpAndSettle();
    expect(find.text('Sync between phones'), findsOneWidget);
  });

  testWidgets('no sync warning while sync is off', (tester) async {
    final since = DateTime.now().subtract(const Duration(days: 8)).toUtc().toIso8601String();
    await start(tester, {'syncSince': since});
    expect(find.byKey(const Key('sync-warning')), findsNothing);
  });

  testWidgets('settings can show the battery on the clock line', (tester) async {
    await start(tester);
    expect(find.text('87%'), findsNothing);
    expect(source.batteryCalls, 0, reason: 'no battery reads while the toggle is off');
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('show-battery')));
    await tester.tap(find.byKey(const Key('show-battery')));
    await tester.pumpAndSettle();
    source.pressHome();
    await tester.pumpAndSettle();
    expect(find.text('87%'), findsOneWidget);
    expect(source.batteryCalls, greaterThan(0));

    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('show-battery')));
    await tester.tap(find.byKey(const Key('show-battery')));
    await tester.pumpAndSettle();
    source.pressHome();
    await tester.pumpAndSettle();
    expect(find.text('87%'), findsNothing, reason: 'turning the toggle off hides the percent again');
  });

  testWidgets('persisted showBattery true shows the percent on a cold start', (tester) async {
    await start(tester, {'settings': '{"showBattery": true}'});
    expect(find.text('87%'), findsOneWidget);
  });

  testWidgets('battery toggle needs the clock line', (tester) async {
    await start(tester);
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('show-clock')));
    await tester.tap(find.byKey(const Key('show-clock')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('show-battery')));
    expect(find.text('Turn on the clock line first'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byKey(const Key('show-battery')));
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    await tester.tap(find.byKey(const Key('show-battery')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('show-battery'))).value, isFalse);
    final raw = (await SharedPreferences.getInstance()).getString('settings');
    final json = raw == null ? <String, Object?>{} : Map<String, Object?>.from(jsonDecode(raw) as Map);
    expect(LauncherSettings.fromJson(json).showBattery, isFalse);
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

  /// Draws [moves] one after the other in a single touch, starting mid-grid.
  Future<void> draw(WidgetTester tester, Finder on, List<Offset> moves) async {
    final g = await tester.startGesture(tester.getCenter(on));
    for (final m in moves) {
      for (var i = 0; i < 10; i++) {
        await g.moveBy(m / 10, timeStamp: const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('swipe down on home opens the notification shade, unless set to nothing', (tester) async {
    await start(tester);
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(source.shades, 1);

    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('gesture-D')));
    expect(find.text('Notifications'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gesture-D')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-none')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(source.shades, 1);
  });

  testWidgets('settings from before gestures keep swipe down off', (tester) async {
    await start(tester, {'settings': '{"swipeNotifications": false}'});
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(source.shades, 0);
  });

  testWidgets('swipe up opens the search with the keyboard and the full list', (tester) async {
    await start(tester);
    await tester.fling(find.byKey(const Key('home-grid')), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byKey(const Key('app-list')), findsOneWidget);
    expect(find.text('Maps'), findsOneWidget);
  });

  testWidgets('a slow pull down far enough opens the shade too; short drags do not', (tester) async {
    await start(tester);
    final grid = find.byKey(const Key('home-grid'));
    await tester.timedDrag(grid, const Offset(0, 20), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.timedDrag(grid, const Offset(30, 0), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(source.shades, 0);
    await tester.timedDrag(grid, const Offset(0, 200), const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(source.shades, 1);
  });

  testWidgets('a recorded gesture opens the app picked for it; deleting it stops that', (tester) async {
    await start(tester);
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('record-gesture')));
    await tester.tap(find.byKey(const Key('record-gesture')));
    await tester.pumpAndSettle();
    final pad = find.byKey(const Key('gesture-pad'));
    // A wobble is no gesture.
    await draw(tester, pad, const [Offset(10, 5)]);
    expect(find.text('Not a gesture: draw longer strokes'), findsOneWidget);
    await draw(tester, pad, const [Offset(0, -150), Offset(150, 0)]);
    expect(find.text('↑ →'), findsOneWidget);
    await tester.tap(find.byKey(const Key('use-gesture')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-launch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-org.example.maps/org.example.maps.Main#0')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('gesture-UR')));
    expect(find.text('Open Maps'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await draw(tester, find.byKey(const Key('home-grid')), const [Offset(0, -150), Offset(150, 0)]);
    expect(source.launched.map((a) => a.label), ['Maps']);
    expect(tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus, isFalse);

    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('delete-gesture-UR')));
    await tester.tap(find.byKey(const Key('delete-gesture-UR')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gesture-UR')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Maps now sits in a cell; draw from an empty one.
    await draw(tester, find.byKey(const Key('empty-0-0')), const [Offset(0, -150), Offset(150, 0)]);
    expect(source.launched, hasLength(1));
  });

  testWidgets('gesture actions: flashlight, shortcut, and service actions say when the service is off', (tester) async {
    await start(tester, {
      'settings':
          '{"gestures": {"L": "flashlight", "R": "recents", "DR": "shortcut:org.example.maps|0|h", "LU": "quickSettings"}}',
    });
    final grid = find.byKey(const Key('home-grid'));
    await tester.fling(grid, const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(source.flashlight, isTrue);
    await tester.fling(grid, const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(source.globalActions, isEmpty);
    expect(find.textContaining('Recent apps needs TurboLaunch actions'), findsOneWidget);
    source.serviceEnabled = true;
    await tester.fling(grid, const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(source.globalActions, ['recents']);
    await draw(tester, grid, const [Offset(0, 150), Offset(150, 0)]);
    expect(source.shortcutsStarted.map((s) => s.label), ['Navigate home']);
    await draw(tester, grid, const [Offset(-150, 0), Offset(0, -150)]);
    expect(source.quickSettings, 1);
    // Swipe up is no longer set: these settings name only their own gestures.
    await tester.fling(grid, const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-list')), findsNothing);
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
    expect(find.textContaining('Home row 1, column'), findsNWidgets(2));
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

  testWidgets('an app launched with the keyboard open gets a bottom-row cell', (tester) async {
    await start(tester);
    final full = tester.getSize(find.byKey(const Key('home-grid')));
    await openSearch(tester);
    // The keyboard takes most of the screen while typing.
    tester.view.viewInsets = const FakeViewPadding(bottom: 1400);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byKey(const Key('search')), 'maps');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('home-grid'))), full);
    final cell = tester.getRect(find.byKey(const ValueKey('cell-org.example.maps/org.example.maps.Main#0')));
    final grid = tester.getRect(find.byKey(const Key('home-grid')));
    expect(
      cell.center.dy,
      greaterThan(grid.bottom - grid.height * 0.15),
      reason: 'bottom row, not a row of the squeezed grid',
    );
  });

  testWidgets('a cell the other phones keep for a missing app shows its ghost', (tester) async {
    // The other phone has Chat, which this one lacks, in its bottom-left cell.
    await start(tester, {
      'syncRemote':
          '[{"format": "turbolaunch-sync", "formatVersion": 1, "device": "other", '
          '"counts": {"org.example.chat/org.example.chat.Main": 9}, '
          '"cells": {"0,0": "org.example.chat/org.example.chat.Main"}, '
          '"labels": {"org.example.chat/org.example.chat.Main": "Chat"}}]',
    });
    expect(find.text('Chat'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(find.text('Chat is on your other phones, not on this one.'), findsOneWidget);
    expect(source.launched, isEmpty);
  });

  testWidgets('each grid cell is its own accessibility node', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester, {'launchCounts': '{"org.example.maps/org.example.maps.Main#0": 1}'});
    final node = tester.getSemantics(find.byKey(const ValueKey('cell-org.example.maps/org.example.maps.Main#0')));
    expect(node.label, contains('Maps'));
    final grid = tester.getSize(find.byKey(const Key('home-grid')));
    expect(node.rect.width, lessThan(grid.width / 2), reason: 'not merged into the whole grid');
    expect(node.rect.height, lessThan(grid.height / 2));
    semantics.dispose();
  });
}

/// A device whose app list never arrives, as on a slow cold start.
class _NeverListing extends FakeAppSource {
  _NeverListing() : super(const []);

  @override
  Future<List<AppEntry>> listApps() => Completer<List<AppEntry>>().future;
}
