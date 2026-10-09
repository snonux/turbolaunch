import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_source.dart';

/// Icons by app key, fetched once per app and kept for the process lifetime.
/// The plugin keeps rendered icons on disk too, so a cold start is cheap.
class IconCache {
  IconCache(this.source);

  final AppSource source;
  final _icons = <String, Future<Uint8List?>>{};
  final _loaded = <String, Uint8List?>{};

  Future<Uint8List?> get(AppEntry app) => _icons.putIfAbsent(app.key, () async {
    final bytes = await source.icon(app);
    _loaded[app.key] = bytes;
    return bytes;
  });

  /// Whether [app]'s icon has been fetched, so [loaded] can be used.
  bool has(AppEntry app) => _loaded.containsKey(app.key);

  /// The fetched icon, or null if the app has none or it is not fetched yet.
  Uint8List? loaded(AppEntry app) => _loaded[app.key];

  /// Drops icons of apps no longer installed or updated since, e.g. after a
  /// package change.
  void clear() {
    _icons.clear();
    _loaded.clear();
  }
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
    // A fetched icon is drawn in the first frame. Through the FutureBuilder
    // alone, every new search result would show its letter tile for a frame
    // and build a second frame, on every keystroke.
    return SizedBox.square(
      dimension: size,
      child: cache.has(app)
          ? _image(app, cache.loaded(app), size)
          : FutureBuilder<Uint8List?>(future: cache.get(app), builder: (context, snap) => _image(app, snap.data, size)),
    );
  }

  Widget _image(AppEntry app, Uint8List? bytes, double size) {
    return Builder(
      builder: (context) {
        if (bytes != null) {
          // Decoded at the size drawn, not the 144 px the plugin renders.
          final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
          return Image.memory(
            bytes,
            cacheWidth: px,
            cacheHeight: px,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          );
        }
        final scheme = Theme.of(context).colorScheme;
        return CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: Text(app.label.isEmpty ? '?' : app.label.characters.first.toUpperCase()),
        );
      },
    );
  }
}
