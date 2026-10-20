import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/widgets/app_icon.dart';

/// 1x1 PNGs, red and blue.
final red = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, //
  222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, //
  73, 69, 78, 68, 174, 66, 96, 130,
]);
final blue = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, //
  222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 96, 248, 15, 0, 1, 3, 1, 0, 8, 137, 194, 236, 0, 0, 0, 0, //
  73, 69, 78, 68, 174, 66, 96, 130,
]);

const maps = AppEntry(key: 'org.example.maps/org.example.maps.Main#0', label: 'Maps');

/// Hands out a fresh copy of [icon] on each fetch, as the plugin does.
class IconSource extends FakeAppSource {
  IconSource() : super([maps]);

  Uint8List? next = red;
  int fetches = 0;

  @override
  Future<Uint8List?> icon(AppEntry app) async {
    fetches++;
    final i = next;
    return i == null ? null : Uint8List.fromList(i);
  }
}

void main() {
  late IconSource source;
  late IconCache cache;

  setUp(() {
    source = IconSource();
    cache = IconCache(source);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(app: maps, cache: cache, size: 48),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Uint8List drawn(WidgetTester tester) =>
      ((tester.widget<Image>(find.byType(Image)).image as ResizeImage).imageProvider as MemoryImage).bytes;

  /// Pumps frames until the cache has nothing left to fetch, checking that
  /// the letter tile never shows on the way.
  Future<void> settleWithoutLetter(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      expect(find.byType(CircleAvatar), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    }
  }

  testWidgets('a package change keeps an unchanged icon as it is', (tester) async {
    await show(tester);
    final before = drawn(tester);
    var told = 0;
    cache.addListener(() => told++);
    cache.stale();
    // Something else rebuilds the screen, as the app list refresh does.
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(app: maps, cache: cache, size: 48),
        ),
      ),
    );
    await settleWithoutLetter(tester);
    expect(source.fetches, 2);
    expect(told, 0);
    expect(identical(drawn(tester), before), isTrue);
  });

  testWidgets('a changed icon replaces the old one without a letter tile in between', (tester) async {
    await show(tester);
    source.next = blue;
    cache.stale();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(app: maps, cache: cache, size: 48),
        ),
      ),
    );
    await settleWithoutLetter(tester);
    expect(drawn(tester), blue);
  });

  testWidgets('a failed fetch after a package change keeps the icon', (tester) async {
    await show(tester);
    source.next = null;
    cache.stale();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AppIcon(app: maps, cache: cache, size: 48),
        ),
      ),
    );
    await settleWithoutLetter(tester);
    expect(drawn(tester), red);
  });

  test('icons are fetched once until a package change', () async {
    await cache.get(maps);
    await cache.get(maps);
    cache.loaded(maps);
    expect(source.fetches, 1);
    cache.stale();
    cache.loaded(maps);
    await cache.get(maps);
    expect(source.fetches, 2);
  });
}
