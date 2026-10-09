import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/gestures.dart';

/// Points every 4 px along straight strokes from the origin.
List<Offset> path(List<Offset> strokes) {
  final points = [Offset.zero];
  for (final s in strokes) {
    final from = points.last;
    for (var i = 1; i <= 20; i++) {
      points.add(from + s * (i / 20));
    }
  }
  return points;
}

void main() {
  test('plain swipes need some length, or speed', () {
    expect(Gestures.recognize(path([const Offset(0, -200)])), 'U');
    expect(Gestures.recognize(path([const Offset(0, 120)])), 'D');
    expect(Gestures.recognize(path([const Offset(-150, 10)])), 'L');
    expect(Gestures.recognize(path([const Offset(150, -30)])), 'R');
    expect(Gestures.recognize(path([const Offset(0, -50)])), '');
    expect(Gestures.recognize(path([const Offset(0, -50)]), velocity: const Offset(0, -900)), 'U');
    expect(Gestures.recognize(const []), '');
  });

  test('a chain of strokes becomes a code; wobbles and diagonals do not split it', () {
    expect(Gestures.recognize(path([const Offset(0, -150), const Offset(150, 0)])), 'UR');
    expect(Gestures.recognize(path([const Offset(0, 150), const Offset(150, 0), const Offset(0, -150)])), 'DRU');
    // A 20 px sideways twitch inside a swipe up.
    expect(Gestures.recognize(path([const Offset(0, -100), const Offset(20, 0), const Offset(0, -100)])), 'U');
    // A clean diagonal goes by its main direction.
    expect(Gestures.recognize(path([const Offset(150, -160)])), 'U');
  });

  test('too many strokes are a scribble', () {
    const zig = [Offset(0, -100), Offset(100, 0)];
    expect(Gestures.recognize(path([...zig, ...zig, ...zig])), '');
  });

  test('valid codes, names and arrows', () {
    expect(Gestures.valid('UR'), isTrue);
    expect(Gestures.valid('UU'), isFalse);
    expect(Gestures.valid('X'), isFalse);
    expect(Gestures.valid(''), isFalse);
    expect(Gestures.name('U'), 'Swipe up');
    expect(Gestures.name('DRU'), '↓ → ↑');
  });

  test('actions round-trip through their string, unknown ones do nothing', () {
    const launch = GestureAction(GestureKind.launch, 'pair:a/b#0|c/d#0');
    expect(GestureAction.decode(launch.encode()), launch);
    expect(GestureAction.decode('search'), const GestureAction(GestureKind.search));
    expect(GestureAction.decode('teleport'), GestureAction.none);
    const s = ShortcutEntry(packageName: 'org.example.maps', id: 'a|b', userSerial: 10, label: 'Home');
    final a = GestureAction.decode(GestureAction.shortcut(s).encode());
    expect(a.shortcutIn([s]), s);
    expect(a.shortcutIn(const []), isNull);
  });
}
