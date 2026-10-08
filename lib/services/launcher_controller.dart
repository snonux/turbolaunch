import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_source.dart';

/// Holds the app list and the search query, and launches apps.
///
/// Phase 1 filters by plain substring; the fuzzy ranker and the home grid
/// replace [visible] in phase 2.
class LauncherController extends ChangeNotifier {
  LauncherController(this.source) {
    _subscription = source.events.listen(_onEvent);
  }

  final AppSource source;
  late final StreamSubscription<AppSourceEvent> _subscription;

  List<AppEntry> _apps = const [];
  String _query = '';
  bool _loaded = false;

  /// Bumped on every Home press, so the UI can drop focus and the keyboard.
  int homePresses = 0;

  List<AppEntry> get apps => _apps;
  String get query => _query;
  bool get loaded => _loaded;

  /// The apps to show for the current query, alphabetical.
  List<AppEntry> get visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _apps;
    return [
      for (final a in _apps)
        if (a.label.toLowerCase().contains(q)) a,
    ];
  }

  Future<void> refresh() async {
    final apps = await source.listApps();
    apps.sort((a, b) {
      final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byLabel != 0 ? byLabel : a.key.compareTo(b.key);
    });
    _apps = List.unmodifiable(apps);
    _loaded = true;
    notifyListeners();
  }

  set query(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  /// Launches [app] and clears the search, so the next Home shows the full list.
  Future<bool> launch(AppEntry app) async {
    final ok = await source.launch(app);
    if (ok) query = '';
    return ok;
  }

  /// Launches the first visible app, as Enter in the search box does.
  Future<bool> launchTopMatch() async {
    final v = visible;
    if (_query.trim().isEmpty || v.isEmpty) return false;
    return launch(v.first);
  }

  void _onEvent(AppSourceEvent event) {
    switch (event) {
      case AppSourceEvent.packagesChanged:
        refresh();
      case AppSourceEvent.homePressed:
        _query = '';
        homePresses++;
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
