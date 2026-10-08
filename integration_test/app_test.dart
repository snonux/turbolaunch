import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/main.dart' as app;

/// End to end on the real app build: `main()` starts as it does on a phone.
/// On Linux that is the fake app list (`FakeAppSource.demo()`); on Android
/// the device's own apps, where tool/e2e_android.sh covers launching.
///
///   xvfb-run -a flutter test integration_test -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final linux = !Platform.isAndroid;

  // The settings page, not a text field inside it.
  final page = find.byType(Scrollable).first;
  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 200, scrollable: page);
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  testWidgets('home grid, search, shortcuts, menu, gestures, pairs, stats, export, settings', (tester) async {
    // A fresh start: no counts, no cells.
    (await SharedPreferences.getInstance()).clear();
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final search = find.byKey(const Key('search'));
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
    expect(find.byKey(const Key('clock-line')), findsOneWidget);

    // Tapping the search box lists every app.
    await tester.tap(search);
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('app-list'));
    expect(find.descendant(of: list, matching: find.byType(ListTile)), findsWidgets);
    if (linux) expect(find.text('AntennaPod'), findsOneWidget, reason: 'the list starts alphabetically');

    // A query that matches nothing says so; Back clears it.
    await tester.enterText(search, 'zzzzqq');
    await tester.pumpAndSettle();
    expect(find.text('No match'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('No match'), findsNothing);
    expect(find.byKey(const Key('home-grid')), findsOneWidget);

    if (linux) {
      // Fuzzy: "orgm" is Organic Maps; Enter launches it and it takes a cell.
      await tester.tap(search);
      await tester.enterText(search, 'orgm');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('app.organicmaps/app.organicmaps.MainActivity#0')), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cell-app.organicmaps/app.organicmaps.MainActivity#0')), findsOneWidget);

      // A second app goes next to it; the first one stays where it is.
      final first = tester.getCenter(find.text('Organic Maps'));
      await tester.tap(search);
      await tester.enterText(search, 'antp');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.text('AntennaPod'), findsOneWidget);
      expect(tester.getCenter(find.text('Organic Maps')), first);

      // Shortcuts are search results too.
      await tester.tap(search);
      await tester.enterText(search, 'new note');
      await tester.pumpAndSettle();
      expect(find.text('Notes'), findsOneWidget, reason: 'the shortcut shows its app');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Long-press menu: remove from home.
      await tester.longPress(find.text('AntennaPod'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-unpin')));
      await tester.pumpAndSettle();
      expect(find.text('AntennaPod'), findsNothing);
      expect(tester.getCenter(find.text('Organic Maps')), first);

      // Quick hide: long-press the clock line.
      await tester.longPress(find.byKey(const Key('clock-line')));
      await tester.pumpAndSettle();
      expect(find.text('Organic Maps'), findsNothing);
      await tester.longPress(find.byKey(const Key('clock-line')));
      await tester.pumpAndSettle();
      expect(find.text('Organic Maps'), findsOneWidget);

      // Double-tap on empty space wants the accessibility service, which is off here.
      final empty = find.byKey(const ValueKey('empty-0-0'));
      await tester.tap(empty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(empty);
      await tester.pumpAndSettle();
      expect(find.textContaining('needs TurboLaunch actions'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(empty)).hideCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    // Settings opens, shows cold start, wallpapers, fonts and the version; Back returns home.
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('cold-start')), findsOneWidget);
    expect(find.byKey(const Key('wallpaper-home')), findsOneWidget);

    // Stats: what was launched, and where it sits.
    await tester.tap(find.byKey(const Key('open-stats')));
    await tester.pumpAndSettle();
    if (linux) {
      expect(find.text('2 launches on this phone'), findsOneWidget);
    } else {
      expect(
        find.byType(ListTile).evaluate().isNotEmpty || find.text('Nothing launched yet').evaluate().isNotEmpty,
        isTrue,
      );
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('double-tap-lock')));
    await scrollTo(tester, find.byKey(const Key('scale-clock')));

    if (linux) {
      // An app pair: saved here, then found by search and given a cell.
      Future<void> pick(String picker, String label) async {
        await scrollTo(tester, find.byKey(Key(picker)));
        await tester.tap(find.byKey(Key(picker)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await pick('pair-first', 'Organic Maps');
      await pick('pair-second', 'Molly');
      await scrollTo(tester, find.byKey(const Key('save-pair')));
      await tester.tap(find.byKey(const Key('save-pair')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved "Organic Maps + Molly"'), findsOneWidget);

      // Export, then import the same file back.
      await scrollTo(tester, find.byKey(const Key('export-settings')));
      await tester.tap(find.byKey(const Key('export-settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved to turbolaunch-settings-'), findsOneWidget);
      await tester.tap(find.byKey(const Key('import-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-import')));
      await tester.pumpAndSettle();
      expect(find.text('Settings imported.'), findsOneWidget);
    }

    await scrollTo(tester, find.textContaining('Version 0.'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-grid')), findsOneWidget);

    if (linux) {
      await tester.tap(search);
      await tester.enterText(search, 'orgmolly');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.text('Organic Maps + Molly'), findsOneWidget, reason: 'the launched pair took a cell');
      expect(find.text('Organic Maps'), findsOneWidget, reason: 'the imported grid kept Organic Maps');
    }
  });
}
