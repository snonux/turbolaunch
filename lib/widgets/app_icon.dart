import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_source.dart';

/// Icons by app key, fetched once per app and kept for the process lifetime.
/// The plugin keeps rendered icons on disk too, so a cold start is cheap.
class IconCache {
  IconCache(this.source);

  final AppSource source;
  final _icons = <String, Future<Uint8List?>>{};

  Future<Uint8List?> get(AppEntry app) => _icons.putIfAbsent(app.key, () => source.icon(app));

  /// Drops icons of apps no longer installed or updated since, e.g. after a
  /// package change.
  void clear() => _icons.clear();
}

/// An app's icon, always drawn fully opaque; a letter tile until it loads.
/// A pair shows its two apps' icons, one above the other; an app in a paused
/// work profile is drawn in grey.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.app, required this.cache, this.size = 40});

  final AppEntry app;
  final IconCache cache;
  final double size;

  static const _grey = ColorFilter.matrix([
    0.33, 0.33, 0.33, 0, 0, //
    0.33, 0.33, 0.33, 0, 0, //
    0.33, 0.33, 0.33, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final pair = app.pair;
    if (pair != null) {
      final half = size * 0.62;
      return SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: _single(AppEntry(key: pair.first, label: app.label), half),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: _single(AppEntry(key: pair.second, label: app.label), half),
            ),
          ],
        ),
      );
    }
    final icon = _single(app, size);
    return app.paused ? ColorFiltered(colorFilter: _grey, child: icon) : icon;
  }

  Widget _single(AppEntry app, double size) {
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<Uint8List?>(
        future: cache.get(app),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null) return Image.memory(bytes, gaplessPlayback: true, filterQuality: FilterQuality.medium);
          final scheme = Theme.of(context).colorScheme;
          return CircleAvatar(
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            child: Text(app.label.isEmpty ? '?' : app.label.characters.first.toUpperCase()),
          );
        },
      ),
    );
  }
}
