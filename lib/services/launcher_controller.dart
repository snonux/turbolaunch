import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_source.dart';
import 'fuzzy.dart';
import 'home_grid.dart';
import 'launcher_store.dart';

/// One line in the search results: an app, or one of an app's shortcuts.
class SearchResult {
  const SearchResult.app(AppEntry this.app, {this.positions = const []}) : shortcut = null, owner = app;

  const SearchResult.shortcut(ShortcutEntry this.shortcut, this.owner, {this.positions = const []}) : app = null;

  final AppEntry? app;
  final ShortcutEntry? shortcut;

  /// The app itself, or the app the shortcut belongs to.
  final AppEntry? owner;

  /// Matched character positions in [title], for highlighting.
  final List<int> positions;

  String get title => app?.label ?? shortcut!.label;
}

/// The launcher's state: apps, shortcuts, launch counts, the home grid, the
/// search query and settings. Persists through [LauncherStore].
class LauncherController extends ChangeNotifier {
  LauncherController(this.source, this.store) {
    _counts = store.counts;
    _slots = store.slots;
    _excluded = store.excluded;
    _hidden = store.hidden;
    _settings = store.settings;
    _quickHide = store.quickHide;
    _subscription = source.events.listen(_onEvent);
  }

  final AppSource source;
  final LauncherStore store;
  late final StreamSubscription<AppSourceEvent> _subscription;

  List<AppEntry> _apps = const [];
  List<ShortcutEntry> _shortcuts = const [];
  late Map<String, int> _counts;
  late Map<Cell, String> _slots;
  late Set<String> _excluded;
  late Set<String> _hidden;
  late LauncherSettings _settings;
  late bool _quickHide;
  String _query = '';
  bool _loaded = false;
  int _rows = 0, _cols = 0;

  /// Bumped on every Home press, so the UI can drop focus and the keyboard.
  int homePresses = 0;

  List<AppEntry> get apps => _apps;
  String get query => _query;
  bool get loaded => _loaded;
  Map<String, int> get counts => Map.unmodifiable(_counts);
  Set<String> get hidden => Set.unmodifiable(_hidden);
  LauncherSettings get settings => _settings;
  bool get quickHide => _quickHide;
  int get rows => _rows;
  int get cols => _cols;

  bool isHidden(AppEntry a) => _hidden.contains(a.key);
  bool isOnHome(AppEntry a) => _slots.containsValue(a.key);

  /// The home grid: which app sits in which cell.
  Map<Cell, AppEntry> get grid {
    final byKey = {for (final a in _apps) a.key: a};
    return {
      for (final e in _slots.entries)
        if (byKey[e.value] != null) e.key: byKey[e.value]!,
    };
  }

  /// Every app that is not hidden, alphabetical: the full list shown when the
  /// search box is focused but empty.
  List<AppEntry> get drawer => [
    for (final a in _apps)
      if (!_hidden.contains(a.key)) a,
  ];

  /// Results for the current query, best first. Hidden apps only show up
  /// when the query is exactly their name. Ties go to the more-launched app.
  List<SearchResult> get results {
    final q = _query.trim();
    if (q.isEmpty) return [for (final a in drawer) SearchResult.app(a)];
    final folded = foldForSearch(q);
    final scored = <(int, int, SearchResult)>[];
    for (final a in _apps) {
      if (_hidden.contains(a.key) && foldForSearch(a.label) != folded) continue;
      final m = fuzzyMatch(q, a.label);
      if (m != null) scored.add((m.score, _counts[a.key] ?? 0, SearchResult.app(a, positions: m.positions)));
    }
    for (final s in _shortcuts) {
      final owner = _apps.where(s.belongsTo).firstOrNull;
      if (owner == null || _hidden.contains(owner.key)) continue;
      final m = fuzzyMatch(q, s.label);
      // A shortcut ranks a little below an app with the same score.
      if (m == null) continue;
      scored.add((m.score - 1, _counts[owner.key] ?? 0, SearchResult.shortcut(s, owner, positions: m.positions)));
    }
    scored.sort((a, b) {
      if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
      if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
      return a.$3.title.toLowerCase().compareTo(b.$3.title.toLowerCase());
    });
    return [for (final s in scored) s.$3];
  }

  Future<void> refresh() async {
    final apps = await source.listApps();
    apps.sort((a, b) {
      final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byLabel != 0 ? byLabel : a.key.compareTo(b.key);
    });
    _apps = List.unmodifiable(apps);
    try {
      _shortcuts = List.unmodifiable(await source.shortcuts());
    } catch (_) {
      _shortcuts = const [];
    }
    _loaded = true;
    _place();
    notifyListeners();
  }

  set query(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  /// Tells the controller how many cells the screen has room for. The
  /// settings' overrides win over [autoRows] and [autoCols].
  void setAutoGridSize(int autoRows, int autoCols) {
    final rows = _settings.gridRows > 0 ? _settings.gridRows : autoRows;
    final cols = _settings.gridCols > 0 ? _settings.gridCols : autoCols;
    if (rows == _rows && cols == _cols) return;
    _rows = rows;
    _cols = cols;
    _place();
    notifyListeners();
  }

  void _place() {
    if (!_loaded || _rows == 0 || _cols == 0) return;
    final next = placeApps(
      slots: _slots,
      rows: _rows,
      cols: _cols,
      installed: {for (final a in _apps) a.key},
      counts: _counts,
      excluded: {..._excluded, ..._hidden},
    );
    if (!mapEquals(next, _slots)) {
      _slots = next;
      store.setSlots(_slots);
    }
  }

  /// Launches [app], counts the launch, and clears the search.
  Future<bool> launch(AppEntry app) async {
    final ok = await source.launch(app);
    if (!ok) return false;
    _counts[app.key] = (_counts[app.key] ?? 0) + 1;
    store.setCounts(_counts);
    _query = '';
    _place();
    notifyListeners();
    return true;
  }

  Future<bool> launchResult(SearchResult r) async {
    if (r.app != null) return launch(r.app!);
    final ok = await source.startShortcut(r.shortcut!);
    if (ok) query = '';
    return ok;
  }

  /// Launches the best result, as Enter in the search box does.
  Future<bool> launchTopMatch() async {
    if (_query.trim().isEmpty) return false;
    final r = results;
    if (r.isEmpty) return false;
    return launchResult(r.first);
  }

  /// Takes [app] off the home grid and keeps it off until pinned again.
  void removeFromHome(AppEntry app) {
    _excluded.add(app.key);
    store.setExcluded(_excluded);
    _slots = {
      for (final e in _slots.entries)
        if (e.value != app.key) e.key: e.value,
    };
    store.setSlots(_slots);
    notifyListeners();
  }

  /// Puts [app] on the home grid in the first free cell.
  void pinToHome(AppEntry app) {
    _excluded.remove(app.key);
    store.setExcluded(_excluded);
    _slots = pinApp(_slots, app.key, _rows, _cols);
    store.setSlots(_slots);
    notifyListeners();
  }

  void setHidden(AppEntry app, bool hide) {
    hide ? _hidden.add(app.key) : _hidden.remove(app.key);
    store.setHidden(_hidden);
    if (hide) {
      _slots = {
        for (final e in _slots.entries)
          if (e.value != app.key) e.key: e.value,
      };
      store.setSlots(_slots);
    }
    _place();
    notifyListeners();
  }

  void toggleQuickHide() {
    _quickHide = !_quickHide;
    store.setQuickHide(_quickHide);
    notifyListeners();
  }

  void updateSettings(LauncherSettings s) {
    _settings = s;
    store.setSettings(s);
    // A changed override takes effect on the next layout pass.
    _rows = 0;
    _cols = 0;
    notifyListeners();
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
