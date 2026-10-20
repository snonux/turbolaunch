import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_source.dart';

/// Icons by app key, fetched once per app and kept for the process lifetime.
/// The plugin keeps rendered icons on disk too, so a cold start is cheap.
///
/// A package change ([stale]) does not drop the icons: each keeps being
/// drawn and is fetched again in the background, and only an icon whose
/// bytes really changed is replaced (and listeners told). Android reports
/// package changes often (an app enabling a component is one), and dropping
/// every icon made the whole grid flicker through letter tiles each time.
class IconCache extends ChangeNotifier {
  IconCache(this.source);

  final AppSource source;

  /// Fetches since the last package change.
  final _icons = <String, Future<Uint8List?>>{};
  final _loaded = <String, Uint8List?>{};

  Future<Uint8List?> get(AppEntry app) => _icons.putIfAbsent(app.key, () async {
    final had = _loaded.containsKey(app.key);
    final old = _loaded[app.key];
    final bytes = await source.icon(app);
    // The same icon keeps its bytes object, so the image is not decoded
    // again; a failed fetch keeps the icon there was.
    if (had && (bytes == null || _same(old, bytes))) return old;
    _loaded[app.key] = bytes;
    if (had) notifyListeners();
    return bytes;
  });

  /// Whether [app]'s icon has been fetched, so [loaded] can be used.
  bool has(AppEntry app) => _loaded.containsKey(app.key);

  /// The fetched icon, or null if the app has none or it is not fetched yet.
  /// After a package change it is fetched again in the background.
  Uint8List? loaded(AppEntry app) {
    if (!_icons.containsKey(app.key) && _loaded.containsKey(app.key)) get(app);
    return _loaded[app.key];
  }

  /// Apps were installed, removed or updated: icons are checked again the
  /// next time they are drawn, and kept until a changed one is in.
  void stale() => _icons.clear();

  static bool _same(Uint8List? a, Uint8List b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
  Widget build(BuildContext context) => ListenableBuilder(listenable: cache, builder: (context, _) => _build());

  Widget _build() {
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
