import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:launcher_platform/launcher_platform.dart';

import 'app_pairs.dart';
import 'app_source.dart';
import 'fuzzy.dart';
import 'home_grid.dart';
import 'launcher_store.dart';
import 'settings_backup.dart';

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

/// One line of the stats screen.
typedef AppStat = ({AppEntry app, int launches, Cell? cell});

/// The launcher's state: apps, app pairs, shortcuts, launch counts, the home
/// grid, the search query and settings. Persists through [LauncherStore].
class LauncherController extends ChangeNotifier {
  LauncherController(this.source, this.store) {
    _load();
    _subscription = source.events.listen(_onEvent);
  }

  void _load() {
    _pairs = store.pairs;
    // The app list from the last run, so a cold start shows the home grid at
    // once; [refresh] replaces it with the device's current list.
    final snapshot = _loaded ? const <AppEntry>[] : store.appSnapshot;
    if (snapshot.isNotEmpty) {
      _setInstalled(snapshot);
      _loaded = true;
    }
    _counts = store.counts;
    _slots = store.slots;
    _excluded = store.excluded;
    _hidden = store.hidden;
    _settings = store.settings;
    _quickHide = store.quickHide;
  }

  final AppSource source;
  final LauncherStore store;
  late final StreamSubscription<AppSourceEvent> _subscription;

  /// Installed apps, as the device lists them.
  List<AppEntry> _installed = const [];

  /// [_installed] plus the app pairs whose two apps are both installed.
  List<AppEntry> _apps = const [];
  late List<AppPair> _pairs;
  List<ShortcutEntry> _shortcuts = const [];

  /// The app each shortcut belongs to, by package and user serial.
  Map<(String, int), AppEntry> _owners = const {};

  /// Labels folded for search once, not on every keystroke.
  final _folded = <String, String>{};
  String _fold(String label) => _folded.putIfAbsent(label, () => foldForSearch(label));
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

  /// Apps and app pairs, alphabetical.
  List<AppEntry> get apps => _apps;

  /// Installed apps without the pairs, for picking a pair's apps.
  List<AppEntry> get installedApps => _installed;
  List<AppPair> get pairs => List.unmodifiable(_pairs);
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
      final label = _fold(a.label);
      if (_hidden.contains(a.key) && label != folded) continue;
      final m = fuzzyMatch(q, a.label, foldedQuery: folded, foldedText: label);
      if (m != null) scored.add((m.score, _counts[a.key] ?? 0, SearchResult.app(a, positions: m.positions)));
    }
    for (final s in _shortcuts) {
      final owner = _owners[(s.packageName, s.userSerial)];
      if (owner == null || _hidden.contains(owner.key)) continue;
      final m = fuzzyMatch(q, s.label, foldedQuery: folded, foldedText: _fold(s.label));
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
    _setInstalled(apps);
    store.setAppSnapshot(_installed);
    _loaded = true;
    _place();
    notifyListeners();
    // Shortcuts only matter once someone types, so the apps do not wait for them.
    try {
      _shortcuts = List.unmodifiable(await source.shortcuts());
    } catch (_) {
      _shortcuts = const [];
    }
    notifyListeners();
  }

  void _setInstalled(List<AppEntry> apps) {
    _installed = List.unmodifiable(List<AppEntry>.of(apps)..sort(_byLabel));
    _folded.clear();
    _owners = {};
    for (final a in _installed) {
      final serial = int.tryParse(a.key.substring(a.key.lastIndexOf('#') + 1));
      if (serial != null) _owners.putIfAbsent((a.packageName, serial), () => a);
    }
    _mergePairs();
  }

  static int _byLabel(AppEntry a, AppEntry b) {
    final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return byLabel != 0 ? byLabel : a.key.compareTo(b.key);
  }

  void _mergePairs() {
    final keys = {for (final a in _installed) a.key};
    _apps = List.unmodifiable(
      <AppEntry>[
        ..._installed,
        for (final p in _pairs)
          if (keys.contains(p.first) && keys.contains(p.second)) AppEntry.pair(p),
      ]..sort(_byLabel),
    );
  }

  /// The installed app with [key], if any.
  AppEntry? appByKey(String key) => _installed.where((a) => a.key == key).firstOrNull;

  /// Launch counts with each app's cell, most-launched first; for the stats screen.
  List<AppStat> get stats {
    final cells = {for (final e in _slots.entries) e.value: e.key};
    return [
      for (final a in _apps)
        if ((_counts[a.key] ?? 0) > 0) (app: a, launches: _counts[a.key]!, cell: cells[a.key]),
    ]..sort((a, b) => a.launches != b.launches ? b.launches.compareTo(a.launches) : _byLabel(a.app, b.app));
  }

  set query(String value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }

  /// The grid size for a screen with room for [autoRows] by [autoCols]: the
  /// settings' overrides win.
  (int, int) gridSizeFor(int autoRows, int autoCols) =>
      (_settings.gridRows > 0 ? _settings.gridRows : autoRows, _settings.gridCols > 0 ? _settings.gridCols : autoCols);

  /// Tells the controller how many cells the screen has room for. The
  /// settings' overrides win over [autoRows] and [autoCols].
  void setAutoGridSize(int autoRows, int autoCols) {
    final (rows, cols) = gridSizeFor(autoRows, autoCols);
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

  /// Launches [app] (both apps of a pair), counts the launch, and clears the search.
  Future<bool> launch(AppEntry app) async {
    final pair = app.pair;
    final bool ok;
    if (pair != null) {
      final first = appByKey(pair.first), second = appByKey(pair.second);
      ok = first != null && second != null && await source.launchPair(first, second) != PairOutcome.failed;
    } else {
      ok = await source.launch(app);
    }
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

  /// Saves a pair of [first] on top and [second] below; replaces a pair of the same two apps.
  AppPair addPair(AppEntry first, AppEntry second, {String? name}) {
    final pair = AppPair(
      name: (name ?? '').trim().isEmpty ? '${first.label} + ${second.label}' : name!.trim(),
      first: first.key,
      second: second.key,
    );
    _pairs = [..._pairs.where((p) => p.key != pair.key), pair];
    store.setPairs(_pairs);
    _mergePairs();
    _place();
    notifyListeners();
    return pair;
  }

  void removePair(AppPair pair) {
    _pairs = [..._pairs.where((p) => p.key != pair.key)];
    store.setPairs(_pairs);
    _mergePairs();
    _place();
    notifyListeners();
  }

  /// Re-reads everything from the store, after a settings import.
  void reload() {
    _load();
    _mergePairs();
    _rows = 0;
    _cols = 0;
    notifyListeners();
  }

  /// Saves the export file where the user picks. The file's name, or null when cancelled.
  Future<String?> exportSettings({DateTime? now}) {
    final at = now ?? DateTime.now();
    return source.saveTextFile(
      suggestedSettingsFileName(at),
      encodeSettingsBackup(LauncherBackup.fromStore(store), exportedAt: at),
    );
  }

  /// Imports a file the user picks; false when cancelled. Throws
  /// [SettingsImportException] for a bad file, before anything is changed.
  Future<bool> importSettings() async {
    final text = await source.openTextFile();
    if (text == null) return false;
    await decodeSettingsBackup(text).applyTo(store);
    reload();
    return true;
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
