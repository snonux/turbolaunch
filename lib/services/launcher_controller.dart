import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:launcher_platform/launcher_platform.dart';

import 'app_pairs.dart';
import 'app_source.dart';
import 'bench.dart';
import 'fuzzy.dart';
import 'home_grid.dart';
import 'launcher_store.dart';
import 's3_config.dart';
import 's3_object_client.dart';
import 'settings_backup.dart';
import 'sync.dart';

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

/// One line of the stats screen: launches on every phone, and on this one.
typedef AppStat = ({AppEntry app, int launches, int here, Cell? cell});

/// Why "Sync now" failed; [message] is shown as is.
class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The launcher's state: apps, app pairs, shortcuts, launch counts, the home
/// grid, the search query, settings and the S3 sync. Persists through
/// [LauncherStore].
class LauncherController extends ChangeNotifier {
  LauncherController(
    this.source,
    this.store, {
    S3ObjectClient Function(S3Config)? s3Client,
    DateTime Function()? clock,
    this.syncPrefix = kSyncPrefix,
  }) : _s3Client = s3Client ?? MinioS3ObjectClient.new,
       _clock = clock ?? DateTime.now {
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
    _sync = store.syncConfig;
    _remote = store.remote;
    _remoteCounts = remoteCounts(_remote);
    // Cells lent out before ghost icons go back to the app they were kept
    // for: the borrower is placed again, in a ghost's cell only when no
    // other cell is free.
    final legacy = store.legacyLent;
    if (legacy.isNotEmpty) {
      _slots = {..._slots}..removeWhere((cell, _) => legacy.containsKey(cell));
      store.setSlots(_slots);
      store.clearLegacyLent();
    }
    _lent = store.lent;
    _lastSync = store.lastSync;
    _totals = null;
  }

  final AppSource source;
  final LauncherStore store;
  late final StreamSubscription<AppSourceEvent> _subscription;
  final S3ObjectClient Function(S3Config) _s3Client;
  final DateTime Function() _clock;

  /// Where the phones' files live in the bucket.
  final String syncPrefix;

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
  late SyncConfig _sync;

  /// The other phones' files from the last sync, and their counts added up.
  late List<DeviceSync> _remote;
  late Map<String, int> _remoteCounts;

  /// Cells kept for an app this phone lacks, by its sync key.
  Map<Cell, String> _ghosts = const {};

  /// Ghost cells a local app borrowed because no other cell was free, by the
  /// sync key of the app they are kept for.
  late Map<Cell, String> _lent;
  DateTime? _lastSync;
  DateTime? _lastAttempt;
  Future<void>? _syncing;
  Timer? _syncTimer;

  /// Sync keys of the installed apps and pairs, and back.
  Map<String, String> _syncKeys = const {};
  Map<String, String> _localKeys = const {};

  /// This phone's counts plus the other phones', by app key.
  Map<String, int>? _totals;

  /// The last grid height seen, kept while settings reset [_rows].
  int _lastRows = 0;
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

  /// Every app's shortcuts, for picking one for a gesture.
  List<ShortcutEntry> get shortcuts => _shortcuts;

  /// The app [s] belongs to, if it is installed.
  AppEntry? shortcutOwner(ShortcutEntry s) => _owners[(s.packageName, s.userSerial)];

  /// The app or app pair with [key], if both its apps are installed.
  AppEntry? entryByKey(String key) => _apps.where((a) => a.key == key).firstOrNull;
  String get query => _query;
  bool get loaded => _loaded;

  /// Launches on this phone.
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// Launches on this phone and, with sync, on the other phones.
  Map<String, int> get totals => _totals ??= _sumCounts();

  Map<String, int> _sumCounts() {
    if (_remoteCounts.isEmpty) return _counts;
    final sum = Map.of(_counts);
    for (final e in _syncKeys.entries) {
      final remote = _remoteCounts[e.value];
      if (remote != null) sum[e.key] = (sum[e.key] ?? 0) + remote;
    }
    return sum;
  }

  SyncConfig get syncConfig => _sync;
  DateTime? get lastSync => _lastSync;

  /// The other phones, as the last sync found them.
  List<DeviceSync> get otherPhones => List.unmodifiable(_remote);
  Set<String> get hidden => Set.unmodifiable(_hidden);
  LauncherSettings get settings => _settings;
  bool get quickHide => _quickHide;
  int get rows => _rows;
  int get cols => _cols;

  bool isHidden(AppEntry a) => _hidden.contains(a.key);
  bool isOnHome(AppEntry a) => _slots.containsValue(a.key);

  /// Cells the other phones keep for an app this phone lacks, with that
  /// app's name: the grid draws a ghost there, so it matches the others.
  Map<Cell, String> get ghosts => {for (final e in _ghosts.entries) e.key: ghostLabel(_remote, e.value)};

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
  List<SearchResult> get results => _results ??= _search();

  /// [results], kept until the query or anything else changes.
  List<SearchResult>? _results;

  @override
  void notifyListeners() {
    _results = null;
    super.notifyListeners();
  }

  List<SearchResult> _search() {
    final q = _query.trim();
    if (q.isEmpty) return List.unmodifiable([for (final a in drawer) SearchResult.app(a)]);
    final folded = foldForSearch(q);
    final counts = totals;
    final scored = <(int, int, SearchResult)>[];
    for (final a in _apps) {
      final label = _fold(a.label);
      if (_hidden.contains(a.key) && label != folded) continue;
      final m = fuzzyMatch(q, a.label, foldedQuery: folded, foldedText: label);
      if (m != null) scored.add((m.score, counts[a.key] ?? 0, SearchResult.app(a, positions: m.positions)));
    }
    for (final s in _shortcuts) {
      final owner = _owners[(s.packageName, s.userSerial)];
      if (owner == null || _hidden.contains(owner.key)) continue;
      final m = fuzzyMatch(q, s.label, foldedQuery: folded, foldedText: _fold(s.label));
      // A shortcut ranks a little below an app with the same score.
      if (m == null) continue;
      scored.add((m.score - 1, counts[owner.key] ?? 0, SearchResult.shortcut(s, owner, positions: m.positions)));
    }
    scored.sort((a, b) {
      if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
      if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
      return a.$3.title.toLowerCase().compareTo(b.$3.title.toLowerCase());
    });
    return List.unmodifiable([for (final s in scored) s.$3]);
  }

  Future<void> refresh() async {
    final apps = await source.listApps();
    final first = !_loaded || _lastAttempt == null;
    _setInstalled(apps);
    store.setAppSnapshot(_installed);
    _loaded = true;
    _place();
    notifyListeners();
    // A sync once the home is up, out of the way of the start.
    if (first) _scheduleSync(const Duration(seconds: 5));
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
    final syncKeys = {for (final a in _installed) a.key: appSyncKey(a.key, otherProfile: a.otherProfile)};
    for (final a in _apps) {
      final p = a.pair;
      if (p != null) syncKeys[a.key] = 'pair:${syncKeys[p.first]}|${syncKeys[p.second]}';
    }
    _syncKeys = syncKeys;
    _localKeys = {for (final e in syncKeys.entries) e.value: e.key};
    _totals = null;
  }

  /// The sync key of [key], also for an app that is not installed any more.
  String _syncKeyOf(String key) {
    final known = _syncKeys[key];
    if (known != null) return known;
    if (key.startsWith('pair:')) {
      final parts = key.substring(5).split('|');
      if (parts.length == 2) return 'pair:${_syncKeyOf(parts[0])}|${_syncKeyOf(parts[1])}';
    }
    return appSyncKey(key, otherProfile: !key.endsWith('#0'));
  }

  /// The installed app with [key], if any.
  AppEntry? appByKey(String key) => _installed.where((a) => a.key == key).firstOrNull;

  /// Launch counts with each app's cell, most-launched first; for the stats screen.
  List<AppStat> get stats {
    final cells = {for (final e in _slots.entries) e.value: e.key};
    final counts = totals;
    return [
      for (final a in _apps)
        if ((counts[a.key] ?? 0) > 0) (app: a, launches: counts[a.key]!, here: _counts[a.key] ?? 0, cell: cells[a.key]),
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
    if (rows > 0) _lastRows = rows;
    _place();
    notifyListeners();
  }

  void _place() {
    if (!_loaded || _rows == 0 || _cols == 0) return;
    // The other phones' cells, with the apps installed here under their app
    // key and the others under their sync key.
    String local(String syncKey) => _localKeys[syncKey] ?? syncKey;
    final shared = _remote.isEmpty
        ? const <Cell, String>{}
        : {for (final e in sharedCells(_remote, _rows).entries) e.key: local(e.value)};
    final next = placeHome(
      slots: _slots,
      rows: _rows,
      cols: _cols,
      installed: {for (final a in _apps) a.key},
      counts: totals,
      excluded: {..._excluded, ..._hidden},
      shared: shared,
      lent: {for (final e in _lent.entries) e.key: local(e.value)},
    );
    if (!mapEquals(next.slots, _slots)) {
      _slots = next.slots;
      store.setSlots(_slots);
    }
    if (!mapEquals(next.lent, _lent)) {
      _lent = next.lent;
      store.setLent(_lent);
    }
    _ghosts = next.ghosts;
  }

  /// Launches [app] (both apps of a pair), counts the launch, and clears the search.
  Future<bool> launch(AppEntry app) async {
    final pair = app.pair;
    final watch = Bench.launchStarted();
    final bool ok;
    if (pair != null) {
      final first = appByKey(pair.first), second = appByKey(pair.second);
      ok = first != null && second != null && await source.launchPair(first, second) != PairOutcome.failed;
    } else {
      ok = await source.launch(app);
    }
    Bench.launchDone(watch);
    if (!ok) return false;
    _counts[app.key] = (_counts[app.key] ?? 0) + 1;
    _totals = null;
    store.setCounts(_counts);
    _query = '';
    _place();
    notifyListeners();
    _scheduleSync(const Duration(seconds: 30));
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
    var slots = pinApp(_slots, app.key, _rows, _cols, skip: _ghosts.keys.toSet());
    // With every other cell taken, the app borrows a ghost's cell.
    final ghost = fillOrder(_rows, _cols).where(_ghosts.containsKey).firstOrNull;
    if (!slots.containsValue(app.key) && ghost != null) {
      slots = {...slots, ghost: app.key};
      _lent = {..._lent, ghost: _ghosts[ghost]!};
      store.setLent(_lent);
    }
    _slots = slots;
    store.setSlots(_slots);
    _place();
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

  void updateSyncConfig(SyncConfig c) {
    _sync = c;
    store.setSyncConfig(c);
    notifyListeners();
  }

  /// Syncs [delay] from now, unless sync is off; a later call moves it.
  void _scheduleSync(Duration delay) {
    if (!_sync.ready) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(delay, () => sync().ignore());
  }

  /// "Sync now": like [sync], but throws [SyncException] when it fails.
  Future<void> syncNow() => sync(explicit: true);

  /// Writes this phone's file and reads the other phones'. An automatic sync
  /// fails silently (the server may simply be down); an [explicit] one
  /// throws [SyncException].
  Future<void> sync({bool explicit = false}) async {
    _syncTimer?.cancel();
    final running = _syncing;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    final run = _syncOnce();
    _syncing = run;
    try {
      await run;
    } on SyncException {
      if (explicit) rethrow;
    } catch (e) {
      if (explicit) throw SyncException('Sync failed: ${_describe(e)}');
    } finally {
      if (identical(_syncing, run)) _syncing = null;
    }
  }

  static String _describe(Object e) {
    final text = e.toString().replaceFirst(RegExp(r'^\w*(Exception|Error): '), '');
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  Future<void> _syncOnce() async {
    _lastAttempt = _clock();
    if (!_sync.enabled) throw const SyncException('Sync is off.');
    final config = _sync.s3;
    if (!config.hasCredentials) throw const SyncException('Enter the access key ID and the secret key.');
    if (!_loaded || _lastRows == 0) throw const SyncException('The home screen is not ready yet.');
    final S3ObjectClient client;
    try {
      client = _s3Client(config);
    } on S3ConfigException catch (e) {
      throw SyncException('Check the sync settings: ${e.message}');
    }
    final device = store.deviceId;
    final rows = _lastRows;
    final labels = {for (final a in _apps) a.key: a.label};
    DeviceSync mine() => DeviceSync(
      device: device,
      name: _sync.deviceName,
      updatedAt: _clock(),
      counts: {
        for (final e in _counts.entries)
          if (e.value > 0) _syncKeyOf(e.key): e.value,
      },
      cells: {
        for (final e in _slots.entries)
          if (e.key.row < rows) flipRows(e.key, rows): _syncKeyOf(e.value),
      },
      labels: {
        for (final e in _slots.entries)
          if (e.key.row < rows && labels[e.value] != null) _syncKeyOf(e.value): labels[e.value]!,
      },
    );
    final own = '$syncPrefix$device.json';
    final before = mine();
    await client.putObject(own, utf8.encode(before.encode()));
    final remote = <DeviceSync>[];
    for (final key in await client.listKeys(prefix: syncPrefix)) {
      if (key == own || !key.endsWith('.json')) continue;
      final List<int> bytes;
      try {
        bytes = await client.getObject(key);
      } catch (e) {
        if (isMissingObjectError(e)) continue;
        rethrow;
      }
      final d = DeviceSync.decode(utf8.decode(bytes, allowMalformed: true));
      if (d != null && d.device != device) remote.add(d);
    }
    remote.sort((a, b) => a.device.compareTo(b.device));
    _remote = remote;
    _remoteCounts = remoteCounts(remote);
    _totals = null;
    _lastSync = _clock();
    await store.setRemote(remote);
    await store.setLastSync(_lastSync!);
    final adopted = remote.isNotEmpty && !store.metOtherPhones && _adoptBusiestGrid(before, rows);
    if (remote.isNotEmpty) await store.setMetOtherPhones(true);
    _place();
    notifyListeners();
    // The others should see the grid this phone took over at once.
    if (adopted) await client.putObject(own, utf8.encode(mine().encode()));
  }

  /// On the first sync that finds other phones: when one of them has more
  /// launches than this phone ([mine]), its grid replaces this phone's.
  /// Apps it lacks lose their cells and are placed again; its cells for apps
  /// this phone lacks show ghosts (see [_place]).
  bool _adoptBusiestGrid(DeviceSync mine, int rows) {
    final busiest = ([..._remote, mine]..sort(byLaunches)).first;
    if (identical(busiest, mine)) return false;
    final hidden = {..._excluded, ..._hidden};
    final slots = <Cell, String>{};
    for (final e in busiest.cells.entries) {
      if (e.key.row >= rows) continue;
      final key = _localKeys[e.value];
      if (key != null && !hidden.contains(key)) slots[flipRows(e.key, rows)] = key;
    }
    _slots = slots;
    _lent = const {};
    store.setSlots(_slots);
    store.setLent(_lent);
    return true;
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
        final last = _lastAttempt;
        if (last == null || _clock().difference(last) > const Duration(minutes: 15)) {
          _scheduleSync(const Duration(seconds: 1));
        }
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _subscription.cancel();
    super.dispose();
  }
}
