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
      // Row 5 is the bottom row above the quick bar.
      'homeSlots': '{"5,0": "org.example.maps/org.example.maps.Main#0"}',
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

  testWidgets('settings choose what the clock line shows; with nothing on it goes away', (tester) async {
    await start(tester, {'settings': '{"showBattery": true}'});
    expect(find.text('87%'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsOneWidget, reason: 'time shown by default');

    await openSettings(tester);
    for (final k in ['show-time', 'show-date']) {
      await scrollTo(tester, find.byKey(Key(k)));
      await tester.tap(find.byKey(Key(k)));
      await tester.pumpAndSettle();
    }
    source.pressHome();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('clock-line')), findsOneWidget, reason: 'battery alone keeps the line');
    expect(find.text('87%'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsNothing, reason: 'time off');

    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('show-battery')));
    await tester.tap(find.byKey(const Key('show-battery')));
    await tester.pumpAndSettle();
    expect(find.text('With all three off there is no clock line'), findsOneWidget);
    source.pressHome();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('clock-line')), findsNothing);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);

    final raw = (await SharedPreferences.getInstance()).getString('settings')!;
    final s = LauncherSettings.fromJson(Map<String, Object?>.from(jsonDecode(raw) as Map));
    expect((s.showTime, s.showDate, s.showBattery, s.showClockLine), (false, false, false, false));
  });

  testWidgets('date only: the line shows the date without the time', (tester) async {
    await start(tester, {'settings': '{"showTime": false}'});
    expect(find.byKey(const Key('clock-line')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsNothing);
    expect(find.textContaining(RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ')), findsOneWidget);
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

  testWidgets('the app pair pickers use the fuzzy search', (tester) async {
    await start(tester);
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('pair-first')));
    await tester.tap(find.byKey(const Key('pair-first')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pair-search')), findsOneWidget);
    expect(find.byKey(ValueKey('pick-${app('Calendar').key}')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pair-search')), 'mu');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('pick-${app('Music').key}')), findsOneWidget);
    expect(find.byKey(ValueKey('pick-${app('Calendar').key}')), findsNothing);
    expect(find.byKey(ValueKey('pick-${app('Maps').key}')), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pair-search')), findsNothing, reason: 'Enter takes the best match');
    expect(find.descendant(of: find.byKey(const Key('pair-first')), matching: find.text('Music')), findsOneWidget);
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

  testWidgets('a swipe up over the results closes the search', (tester) async {
    await start(tester);
    await openSearch(tester);
    await tester.enterText(find.byKey(const Key('search')), 'ma');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-list')), findsOneWidget);
    await tester.fling(find.byKey(const Key('app-list')), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus, isFalse);
    expect(tester.widget<TextField>(find.byKey(const Key('search'))).controller!.text, isEmpty);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);

    // Also with nothing found, and with a slow drag.
    await openSearch(tester);
    await tester.enterText(find.byKey(const Key('search')), 'zzz');
    await tester.pumpAndSettle();
    await tester.timedDrag(find.text('No match'), const Offset(0, -200), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
  });

  testWidgets('coming back from an app shows the home grid, not the search', (tester) async {
    await start(tester);
    bool focused() => tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus;
    Future<void> leaveAndComeBack() async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
    }

    // Left with the search open (by Back, which sends no Home press).
    await openSearch(tester);
    await tester.enterText(find.byKey(const Key('search')), 'ma');
    await tester.pumpAndSettle();
    await leaveAndComeBack();
    expect(focused(), isFalse);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);

    // A pulled-down shade only makes it inactive: the search stays.
    await openSearch(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-list')), findsOneWidget);
  });

  testWidgets('"Open the keyboard on Home" opens it on Home, not on the way back from an app', (tester) async {
    await start(tester, {'settings': '{"keyboardOnHome": true}'});
    bool focused() => tester.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus;
    source.returnHome();
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
    source.pressHome();
    await tester.pumpAndSettle();
    expect(focused(), isTrue);
  });

  testWidgets('a swipe over the results that scrolls them, or goes down, keeps the search', (tester) async {
    source = FakeAppSource([for (var i = 0; i < 60; i++) app('App$i')]);
    await start(tester);
    await openSearch(tester);
    final list = find.byKey(const Key('app-list'));
    await tester.fling(list, const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    await tester.fling(list, const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    expect(find.byKey(const Key('home-grid')), findsNothing);
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

  testWidgets('rarely used apps lists unlaunched apps first and uninstalls them', (tester) async {
    source = FakeAppSource([app('Calendar'), app('Maps'), app('Music'), app('Phone')]);
    final phone = app('Phone').key;
    source.details[phone] = PlatformAppDetails(system: true, installed: DateTime.utc(2020));
    source.details[app('Calendar').key] = PlatformAppDetails(
      system: false,
      installed: DateTime.now().subtract(const Duration(days: 3)),
    );
    await start(tester, {
      'launchCounts':
          '{"org.example.maps/org.example.maps.Main#0": 5, "org.example.music/org.example.music.Main#0": 2}',
    });
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('open-rare')));
    await tester.pumpAndSettle();
    expect(find.text('Not launched in the last 30 days'), findsOneWidget);
    expect(find.text('Installed 3 days ago'), findsOneWidget);
    expect(find.byKey(ValueKey('rare-$phone')), findsNothing, reason: 'system apps are left out');
    final calendar = tester.getTopLeft(find.byKey(ValueKey('rare-${app('Calendar').key}')));
    final music = tester.getTopLeft(find.byKey(ValueKey('rare-${app('Music').key}')));
    final maps = tester.getTopLeft(find.byKey(ValueKey('rare-${app('Maps').key}')));
    expect(calendar.dy, lessThan(music.dy), reason: 'never launched first');
    expect(music.dy, lessThan(maps.dy), reason: 'then fewest launches');
    expect(find.textContaining('2 launches'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('rare-uninstall-${app('Calendar').key}')));
    await tester.pumpAndSettle();
    expect(source.uninstalled.single.label, 'Calendar');

    await tester.tap(find.byKey(const Key('rare-system')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('rare-$phone')), findsOneWidget);
    expect(find.byKey(ValueKey('rare-uninstall-$phone')), findsNothing, reason: 'system apps cannot be uninstalled');

    // Uninstalled, Calendar leaves the list.
    source.apps = [app('Maps'), app('Music'), app('Phone')];
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('rare-${app('Calendar').key}')), findsNothing);
  });

  testWidgets('stats and settings warn when another phone counts another launch window', (tester) async {
    await start(tester, {
      'launchCounts': '{"org.example.maps/org.example.maps.Main#0": 5}',
      'syncRemote':
          '[{"format": "turbolaunch-sync", "formatVersion": 1, "device": "other", "name": "Tablet", '
          '"counts": {"org.example.maps/org.example.maps.Main": 2}, '
          '"days": {"org.example.maps/org.example.maps.Main": {"2000-01-01": 9}}, "windowDays": 90}]',
    });
    await openSettings(tester);
    await scrollTo(tester, find.byKey(const Key('launch-window')));
    expect(find.textContaining('The last 30 days, for the grid'), findsOneWidget);
    expect(find.textContaining('Tablet counts the last 90 days'), findsOneWidget);
    await tester.tap(find.byKey(const Key('launch-window')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The last 90 days'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The last 90 days, for the grid'), findsOneWidget);
    expect(find.textContaining('Tablet counts'), findsNothing, reason: 'both count 90 days now');
    await tester.tap(find.byKey(const Key('launch-window')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The last 7 days'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('open-stats')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tablet counts the last 90 days'), findsOneWidget);
    expect(find.text('5 launches on all phones, 5 here'), findsOneWidget, reason: "the tablet's day is long past");
    expect(find.textContaining('Counting launches of the last 7 days.'), findsOneWidget);
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

  group('quick bar', () {
    const mapsKey = 'org.example.maps/org.example.maps.Main#0';
    const musicKey = 'org.example.music/org.example.music.Main#0';
    final onGrid = find.byKey(const Key('home-grid'));
    final bar = find.byKey(const Key('quick-bar'));
    Finder inGrid(String label) => find.descendant(of: onGrid, matching: find.text(label));
    Finder inBar(String label) => find.descendant(of: bar, matching: find.text(label));

    /// Long-presses [from] until it lifts, drags it to [to] and lets go.
    Future<void> drag(WidgetTester tester, Finder from, Offset to) async {
      final g = await tester.startGesture(tester.getCenter(from));
      await tester.pump(const Duration(milliseconds: 700));
      final start = tester.getCenter(from);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(start, to, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('empty, it keeps its row with a note; settings turn it off and the grid gets its row back', (
      tester,
    ) async {
      await start(tester);
      expect(bar, findsOneWidget);
      expect(find.text('Drag apps here for quick launch'), findsOneWidget);
      final withBar = tester.getSize(onGrid).height;
      await openSettings(tester);
      await scrollTo(tester, find.byKey(const Key('quick-bar-enabled')));
      await tester.tap(find.byKey(const Key('quick-bar-enabled')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(tester.getSize(onGrid).height, greaterThan(withBar));
    });

    testWidgets('an app dragged in leaves the grid, launches from the bar and counts; dragged out it leaves the bar', (
      tester,
    ) async {
      await start(tester, {'launchCounts': '{"$mapsKey": 3, "$musicKey": 1}'});
      expect(inGrid('Maps'), findsOneWidget);
      await drag(tester, inGrid('Maps'), tester.getCenter(find.byKey(const ValueKey('bar-empty-0'))));
      expect(find.text('Drag apps here for quick launch'), findsNothing);
      expect(inBar('Maps'), findsOneWidget);
      expect(inGrid('Maps'), findsNothing, reason: 'not shown twice');

      await tester.tap(inBar('Maps'));
      await tester.pumpAndSettle();
      expect(source.launched.single.label, 'Maps');

      // Music dropped on the first slot goes before Maps.
      await drag(tester, inGrid('Music'), tester.getCenter(inBar('Maps')));
      expect(tester.getCenter(inBar('Music')).dx, lessThan(tester.getCenter(inBar('Maps')).dx));
      // Along the bar: Music to the third slot, after Maps.
      await drag(tester, inBar('Music'), tester.getCenter(find.byKey(const ValueKey('bar-empty-2'))));
      expect(tester.getCenter(inBar('Music')).dx, greaterThan(tester.getCenter(inBar('Maps')).dx));

      await openSettings(tester);
      await tester.tap(find.byKey(const Key('open-stats')));
      await tester.pumpAndSettle();
      expect(find.text('5 launches on this phone'), findsOneWidget);
      expect(find.text('In the quick bar'), findsNWidgets(2));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Out onto the grid: it leaves the bar.
      await drag(tester, inBar('Maps'), tester.getCenter(onGrid));
      expect(inBar('Maps'), findsNothing);
      expect(inBar('Music'), findsOneWidget);
    });

    testWidgets('the long-press menu adds to and removes from the bar; a plain long-press still opens it', (
      tester,
    ) async {
      await start(tester);
      await openSearch(tester);
      await tester.longPress(find.text('Calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-bar-add')));
      await tester.pumpAndSettle();
      expect(inBar('Calendar'), findsOneWidget);

      await tester.longPress(inBar('Calendar'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('menu-pin')), findsNothing, reason: 'a bar app has no home entries');
      await tester.tap(find.byKey(const Key('menu-bar-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Drag apps here for quick launch'), findsOneWidget);
    });

    testWidgets('a bar app another phone put there shows as a ghost', (tester) async {
      await start(tester, {
        'quickBar': ['org.example.chat/org.example.chat.Main'],
        'quickBarChanged': '2026-10-15T08:00:00Z',
        'syncRemote':
            '[{"format": "turbolaunch-sync", "formatVersion": 1, "device": "other", '
            '"labels": {"org.example.chat/org.example.chat.Main": "Chat"}}]',
      });
      expect(inBar('Chat'), findsOneWidget);
      await tester.tap(inBar('Chat'));
      await tester.pump();
      expect(find.text('Chat is on your other phones, not on this one.'), findsOneWidget);
    });
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
