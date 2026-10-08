import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/main.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/launcher_store.dart';

/// The README screenshots, taken from the Linux build at phone size with the
/// demo apps and drawn icons. It lives outside integration_test/ so the CI run
/// does not start a second app; tool/readme_shots.sh copies it in and runs it.
const _dir = String.fromEnvironment('SHOTS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README screenshots', skip: _dir.isEmpty, (tester) async {
    // A Pixel-sized phone in dark mode.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    // Launch counts a few weeks of use might leave, so the grid is filled.
    (await SharedPreferences.getInstance()).clear();
    final store = await LauncherStore.open();
    final demo = FakeAppSource.demo();
    final apps = await demo.listApps();
    final byLabel = {for (final a in apps) a.label: a.key};
    const used = [
      'Molly', 'Fennec', 'Organic Maps', 'Phone', 'Messages', 'Camera', 'Quicklog', 'Proton Mail', //
      'AntennaPod', 'Notes', 'Calendar', 'Termux',
    ];
    await store.setCounts({for (final (i, label) in used.indexed) byLabel[label]!: 60 - i * 4});

    final source = _IconSource(apps, shortcuts: await demo.shortcuts());
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        // Stands in for the system wallpaper, which shows through the launcher.
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1B2A49), Color(0xFF3A2E5C), Color(0xFF0E5E6F)],
            ),
          ),
          child: TurboLaunchApp(source: source, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    Future<void> shot(String name) async {
      // Icons are drawn and decoded off the test clock; give them real time.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
      }
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1.25);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    }

    await shot('home');

    final search = find.byKey(const Key('search'));
    await tester.tap(search);
    await tester.enterText(search, 'te');
    await shot('search');
  });
}

/// The demo apps with drawn icons: a coloured square and a symbol each.
class _IconSource extends FakeAppSource {
  _IconSource(super.apps, {super.shortcuts});

  static const _looks = <String, (IconData, Color)>{
    'Fennec': (Icons.public, Color(0xFFE66000)),
    'Organic Maps': (Icons.map, Color(0xFF2E7D32)),
    'Gallery': (Icons.photo, Color(0xFF8E24AA)),
    'Calendar': (Icons.calendar_month, Color(0xFF1E88E5)),
    'Clock': (Icons.schedule, Color(0xFF455A64)),
    'Contacts': (Icons.person, Color(0xFF00897B)),
    'Messages': (Icons.sms, Color(0xFF3949AB)),
    'Phone': (Icons.call, Color(0xFF43A047)),
    'Notes': (Icons.sticky_note_2, Color(0xFFF9A825)),
    'LibreTube': (Icons.play_arrow, Color(0xFFD32F2F)),
    'AntennaPod': (Icons.podcasts, Color(0xFF1565C0)),
    'Quicklog': (Icons.edit_note, Color(0xFF6D4C41)),
    'Camera': (Icons.photo_camera, Color(0xFF546E7A)),
    'Settings': (Icons.settings, Color(0xFF607D8B)),
    'OsmAnd~': (Icons.explore, Color(0xFFEF6C00)),
    'Molly': (Icons.chat_bubble, Color(0xFF5E35B1)),
    'Termux': (Icons.terminal, Color(0xFF212121)),
    'Proton Mail': (Icons.mail, Color(0xFF6D4AFF)),
  };

  @override
  Future<Uint8List?> icon(AppEntry app) async {
    final (glyph, colour) = _looks[app.label] ?? (Icons.apps, Colors.blueGrey);
    const size = 144.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, size, size), const Radius.circular(size * 0.3)),
      Paint()..color = colour,
    );
    final text = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(glyph.codePoint),
        style: TextStyle(
          fontFamily: glyph.fontFamily,
          package: glyph.fontPackage,
          fontSize: size * 0.58,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset((size - text.width) / 2, (size - text.height) / 2));
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }
}
