import 'package:flutter/material.dart';

import '../services/app_source.dart';
import '../services/gestures.dart';
import '../services/launcher_controller.dart';

/// What [action] does, for its settings line.
String describeGestureAction(LauncherController c, GestureAction action, {bool? serviceOn}) {
  final text = switch (action.kind) {
    GestureKind.launch => 'Open ${c.entryByKey(action.target ?? '')?.label ?? 'an app that is not installed'}',
    GestureKind.shortcut => switch (action.shortcutIn(c.shortcuts)) {
      final s? => 'Open ${s.label} (${c.shortcutOwner(s)?.label ?? s.packageName})',
      null => 'Open a shortcut that is gone',
    },
    final k => k.label,
  };
  return action.kind.needsService && serviceOn == false ? '$text: needs the accessibility service' : text;
}

/// Asks what a gesture should do: a kind, then for apps and shortcuts which
/// one. Null when the user backs out.
Future<GestureAction?> pickGestureAction(BuildContext context, LauncherController c, String code) async {
  final kind = await showDialog<GestureKind>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(Gestures.name(code)),
      children: [
        for (final k in GestureKind.values)
          SimpleDialogOption(
            key: Key('action-${k.name}'),
            onPressed: () => Navigator.pop(context, k),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(k.label)),
          ),
      ],
    ),
  );
  if (kind == null || !context.mounted) return null;
  switch (kind) {
    case GestureKind.launch:
      final app = await _pick<AppEntry>(context, 'Open an app', c.apps, (a) => a.label, (a) => 'pick-${a.key}');
      return app == null ? null : GestureAction(GestureKind.launch, app.key);
    case GestureKind.shortcut:
      final s = await _pick<ShortcutEntry>(
        context,
        'Open an app shortcut',
        c.shortcuts,
        (s) => '${s.label} (${c.shortcutOwner(s)?.label ?? s.packageName})',
        (s) => 'pick-${s.packageName}-${s.id}',
      );
      return s == null ? null : GestureAction.shortcut(s);
    default:
      return GestureAction(kind);
  }
}

Future<T?> _pick<T>(
  BuildContext context,
  String title,
  List<T> items,
  String Function(T) label,
  String Function(T) key,
) => showDialog<T>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    contentPadding: const EdgeInsets.only(top: 12),
    content: SizedBox(
      width: double.maxFinite,
      child: items.isEmpty
          ? const Padding(padding: EdgeInsets.all(24), child: Text('Nothing to pick'))
          : ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) => ListTile(
                key: Key(key(items[i])),
                title: Text(label(items[i])),
                onTap: () => Navigator.pop(context, items[i]),
              ),
            ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
  ),
);

/// A pad to draw a new gesture on. Pops with its code when the user keeps it.
class GestureRecordScreen extends StatefulWidget {
  const GestureRecordScreen({super.key});

  @override
  State<GestureRecordScreen> createState() => _GestureRecordScreenState();
}

class _GestureRecordScreenState extends State<GestureRecordScreen> {
  final _path = <Offset>[];
  String? _code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = _code;
    return Scaffold(
      appBar: AppBar(title: const Text('Record a gesture')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Draw a chain of straight strokes in one go, like up then right. '
              'On the home screen, start it on empty space, away from the screen edges.',
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Material(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: GestureDetector(
                  key: const Key('gesture-pad'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => setState(() {
                    _code = null;
                    _path
                      ..clear()
                      ..add(d.localPosition);
                  }),
                  onPanUpdate: (d) => setState(() => _path.add(d.localPosition)),
                  onPanEnd: (d) =>
                      setState(() => _code = Gestures.recognize(_path, velocity: d.velocity.pixelsPerSecond)),
                  child: CustomPaint(painter: _Trail(List.of(_path), scheme.primary), child: const SizedBox.expand()),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    code == null
                        ? 'Draw here'
                        : code.isEmpty
                        ? 'Not a gesture: draw longer strokes'
                        : Gestures.arrows(code),
                    key: const Key('gesture-code'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton(
                  key: const Key('use-gesture'),
                  onPressed: code != null && code.isNotEmpty ? () => Navigator.pop(context, code) : null,
                  child: const Text('Use it'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Trail extends CustomPainter {
  _Trail(this.points, this.color);

  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(Path()..addPolygon(points, false), paint);
  }

  @override
  bool shouldRepaint(_Trail old) => old.points != points || old.color != color;
}
