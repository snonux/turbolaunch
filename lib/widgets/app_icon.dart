import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_source.dart';

/// Icons by app key, fetched once per app and kept for the process lifetime.
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
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.app, required this.cache, this.size = 40});

  final AppEntry app;
  final IconCache cache;
  final double size;

  @override
  Widget build(BuildContext context) {
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
