import 'dart:ui' show Offset;

import 'app_source.dart';

/// Swipe gestures on empty home space. A gesture is a chain of straight
/// strokes, written as a code of letters: `U`, `D`, `L` and `R` are the four
/// plain swipes, `UR` is up then right (an L), `DRU` a U. Users record their
/// own chains in settings and give each one an [GestureAction].
abstract final class Gestures {
  /// The four plain swipes, always listed in settings.
  static const basic = ['U', 'D', 'L', 'R'];

  /// What a fresh install does: swipe up searches, swipe down pulls the shade.
  static const defaults = {'U': 'search', 'D': 'notifications'};

  /// Longer chains are scribbles, not gestures.
  static const maxStrokes = 5;

  /// Points closer than this are one step; each step gets one direction.
  static const _step = 12.0;

  /// A stroke inside a chain must be at least this long, in logical pixels.
  static const _minStroke = 40.0;

  /// A plain swipe must go this far, or be a fling.
  static const _minSwipe = 80.0;
  static const _minFling = 300.0;

  /// The gesture drawn through [points] (logical pixels, in order), ending
  /// at [velocity] in pixels per second. Empty when it is no gesture: too
  /// short and too slow, or too many strokes.
  static String recognize(List<Offset> points, {Offset velocity = Offset.zero}) {
    // Runs of steps that go the same way.
    final runs = <(String, double)>[];
    void add(List<(String, double)> to, String dir, double length) {
      if (to.isNotEmpty && to.last.$1 == dir) {
        to.last = (dir, to.last.$2 + length);
      } else {
        to.add((dir, length));
      }
    }

    if (points.isNotEmpty) {
      var from = points.first;
      for (final p in points.skip(1)) {
        final d = p - from;
        if (d.distance < _step) continue;
        add(runs, _direction(d), d.distance);
        from = p;
      }
    }
    // Wobbles are no strokes: drop the short runs and join what meets again.
    final strokes = <(String, double)>[];
    for (final (dir, length) in runs) {
      if (length >= _minStroke) add(strokes, dir, length);
    }
    if (strokes.length > maxStrokes) return '';
    if (strokes.length > 1) return strokes.map((s) => s.$1).join();
    if (strokes.length == 1 && strokes.single.$2 >= _minSwipe) return strokes.single.$1;
    // A quick flick, or a diagonal that never settled on one direction.
    if (velocity.distance >= _minFling) return _direction(velocity);
    if (points.length > 1 && (points.last - points.first).distance >= _minSwipe) {
      return _direction(points.last - points.first);
    }
    return '';
  }

  static String _direction(Offset d) => d.dx.abs() > d.dy.abs() ? (d.dx > 0 ? 'R' : 'L') : (d.dy > 0 ? 'D' : 'U');

  /// Whether [code] is something [recognize] can return.
  static bool valid(String code) =>
      code.isNotEmpty && code.length <= maxStrokes && RegExp(r'^[UDLR]+$').hasMatch(code) && !_repeats(code);

  static bool _repeats(String code) {
    for (var i = 1; i < code.length; i++) {
      if (code[i] == code[i - 1]) return true;
    }
    return false;
  }

  /// Arrows for [code]: `↑ →` for `UR`.
  static String arrows(String code) =>
      code.split('').map((c) => const {'U': '↑', 'D': '↓', 'L': '←', 'R': '→'}[c] ?? '?').join(' ');

  /// A name for [code]: "Swipe up", or the arrows of a longer chain.
  static String name(String code) => switch (code) {
    'U' => 'Swipe up',
    'D' => 'Swipe down',
    'L' => 'Swipe left',
    'R' => 'Swipe right',
    _ => arrows(code),
  };
}

/// What a gesture can do.
enum GestureKind {
  none('Nothing'),
  search('Open search'),
  notifications('Notifications'),
  quickSettings('Quick settings'),
  launch('Open an app'),
  shortcut('Open an app shortcut'),
  lock('Lock screen', needsService: true),
  recents('Recent apps', needsService: true),
  powerMenu('Power menu', needsService: true),
  screenshot('Screenshot', needsService: true),
  splitScreen('Split screen', needsService: true),
  flashlight('Flashlight on or off'),
  quickHide('Quick hide'),
  settings('TurboLaunch settings'),
  stats('Launch stats');

  const GestureKind(this.label, {this.needsService = false});

  final String label;

  /// Only works with the TurboLaunch actions accessibility service on.
  final bool needsService;
}

/// A [GestureKind] plus what it opens: an app's key for [GestureKind.launch]
/// (pairs included), a shortcut for [GestureKind.shortcut]. Stored as one
/// string, `launch:<app key>` or `shortcut:<package>|<user serial>|<id>`.
class GestureAction {
  const GestureAction(this.kind, [this.target]);

  final GestureKind kind;
  final String? target;

  static const none = GestureAction(GestureKind.none);

  factory GestureAction.shortcut(ShortcutEntry s) =>
      GestureAction(GestureKind.shortcut, '${s.packageName}|${s.userSerial}|${s.id}');

  /// Unknown kinds (from a newer version's export) do nothing.
  factory GestureAction.decode(String s) {
    final colon = s.indexOf(':');
    final name = colon < 0 ? s : s.substring(0, colon);
    final kind = GestureKind.values.where((k) => k.name == name).firstOrNull ?? GestureKind.none;
    return GestureAction(kind, colon < 0 ? null : s.substring(colon + 1));
  }

  String encode() => target == null ? kind.name : '${kind.name}:$target';

  /// The shortcut this action opens, matched against [shortcuts].
  ShortcutEntry? shortcutIn(List<ShortcutEntry> shortcuts) {
    if (kind != GestureKind.shortcut || target == null) return null;
    final parts = target!.split('|');
    if (parts.length < 3) return null;
    final id = parts.sublist(2).join('|');
    return shortcuts.where((s) => s.packageName == parts[0] && '${s.userSerial}' == parts[1] && s.id == id).firstOrNull;
  }

  @override
  bool operator ==(Object other) => other is GestureAction && other.kind == kind && other.target == target;

  @override
  int get hashCode => Object.hash(kind, target);
}
