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

  testWidgets('home grid, fuzzy search, shortcuts, menu, quick hide, settings', (tester) async {
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
    }

    // Settings opens, shows cold start, wallpapers, fonts and the version; Back returns home.
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('cold-start')), findsOneWidget);
    expect(find.byKey(const Key('wallpaper-home')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('scale-clock')), 200);
    await tester.scrollUntilVisible(find.textContaining('Version 0.'), 200);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-grid')), findsOneWidget);
  });
}
