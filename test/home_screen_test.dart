import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/main.dart';
import 'package:turbolaunch/services/app_source.dart';

AppEntry app(String label) {
  final p = 'org.example.${label.toLowerCase()}';
  return AppEntry(key: '$p/$p.Main#0', label: label);
}

void main() {
  late FakeAppSource source;

  setUp(() => source = FakeAppSource([app('Calendar'), app('Maps'), app('Music')]));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(TurboLaunchApp(source: source));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every app and launches one on tap', (tester) async {
    await start(tester);
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Maps'), findsOneWidget);
    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();
    expect(source.launched.single.label, 'Maps');
  });

  testWidgets('typing filters, Enter launches the top match', (tester) async {
    await start(tester);
    await tester.enterText(find.byKey(const Key('search')), 'mu');
    await tester.pumpAndSettle();
    expect(find.text('Calendar'), findsNothing);
    expect(find.text('Music'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(source.launched.single.label, 'Music');
    expect(find.text('Calendar'), findsOneWidget, reason: 'the launch clears the search');
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
    expect(find.text('Calendar'), findsOneWidget);
  });

  testWidgets('an installed app shows up without a restart', (tester) async {
    await start(tester);
    source.apps = [app('Calendar'), app('Notes')];
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('Maps'), findsNothing);
  });

  testWidgets('settings opens an app pair and reports a missing service', (tester) async {
    await start(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Off: tap to open Accessibility settings'), findsOneWidget);

    Future<void> pick(String picker, String label) async {
      await tester.scrollUntilVisible(find.byKey(Key(picker)), 100);
      await tester.tap(find.byKey(Key(picker)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

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
