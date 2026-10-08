import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:turbolaunch/main.dart' as app;

/// End to end on the real app build: `main()` starts as it does on a phone.
/// On Linux that is the fake app list (`FakeAppSource.demo()`); on Android
/// the device's own apps, where tool/e2e_android.sh covers launching.
///
///   xvfb-run flutter test integration_test -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home screen: list, search, settings, back', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final list = find.byKey(const Key('app-list'));
    expect(list, findsOneWidget);
    expect(find.descendant(of: list, matching: find.byType(ListTile)), findsWidgets);
    if (!Platform.isAndroid) {
      expect(find.text('AntennaPod'), findsOneWidget, reason: 'the list starts alphabetically');
    }

    // Searching narrows the list; a query that matches nothing says so.
    await tester.enterText(find.byKey(const Key('search')), 'zzzzqq');
    await tester.pumpAndSettle();
    expect(find.text('No match'), findsOneWidget);
    if (!Platform.isAndroid) {
      await tester.enterText(find.byKey(const Key('search')), 'org');
      await tester.pumpAndSettle();
      expect(find.text('Organic Maps'), findsOneWidget);
      expect(find.text('AntennaPod'), findsNothing);
    }

    // Back clears the search instead of leaving the home screen.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('No match'), findsNothing);
    expect(find.byKey(const Key('app-list')), findsOneWidget);

    // Settings opens, shows the measured cold start and the version, and Back returns home.
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('cold-start')), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Version 0.'), 200);
    expect(find.textContaining('Version 0.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-list')), findsOneWidget);
  });
}
