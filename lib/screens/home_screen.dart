import 'dart:async';

import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/material.dart';

import '../services/app_source.dart';
import '../services/bench.dart';
import '../services/gestures.dart';
import '../services/home_grid.dart';
import '../services/launcher_controller.dart';
import '../widgets/app_icon.dart';
import '../widgets/matched_text.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'sync_screen.dart';

/// The home screen: the clock line at the top, the home grid filled by
/// launch count, the quick launch bar with the apps put there by hand, and
/// the search box docked at the bottom within thumb reach. Focusing the
/// search swaps the grid and the bar for live fuzzy results.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, required this.icons});

  final LauncherController controller;
  final IconCache icons;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  int _seenHomePresses = 0;
  late final AppLifecycleListener _lifecycle;

  LauncherController get _c => widget.controller;
  bool get _searching => _focus.hasFocus || _c.query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onController);
    _focus.addListener(() => setState(() {}));
    // The grid is arranged by launches only while nobody looks at it.
    bool front(AppLifecycleState? s) => s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
    _c.setInFront(front(WidgetsBinding.instance.lifecycleState));
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        _c.setInFront(front(s));
        if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _away = true;
        if (s == AppLifecycleState.resumed && _away) _cameBack();
      },
    );
  }

  /// Whether another app was in front since the home screen last was.
  bool _away = false;

  /// Coming back from an app (by Back too, which sends no Home press) shows
  /// the home grid, not the search: Flutter would focus the search box again
  /// if it had focus when the app was left.
  void _cameBack() {
    _away = false;
    _c.query = '';
    _focus.unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    _lifecycle.dispose();
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onController() {
    if (_search.text != _c.query) _search.text = _c.query;
    if (_c.homePresses != _seenHomePresses) {
      _seenHomePresses = _c.homePresses;
      Navigator.of(context).popUntil((r) => r.isFirst);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      // The keyboard opens on a Home press on the home screen, not on the
      // way back from an app.
      if (_c.settings.keyboardOnHome && !_c.homeFromApp) {
        _focus.requestFocus();
      } else {
        _focus.unfocus();
      }
    }
    setState(() {});
  }

  Future<void> _launch(SearchResult r) async {
    _focus.unfocus();
    await _c.launchResult(r);
  }

  Future<void> _showMenu(AppEntry app) async {
    _focus.unfocus();
    final onHome = _c.isOnHome(app);
    final hidden = _c.isHidden(app);
    final bar = _c.settings.quickBar;
    final inBar = bar && _c.isInQuickBar(app);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        Widget item(String id, IconData icon, String label) => ListTile(
          key: Key('menu-$id'),
          leading: Icon(icon),
          title: Text(label),
          onTap: () => Navigator.pop(context, id),
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(app.label, style: Theme.of(context).textTheme.titleMedium)),
              if (inBar)
                item('bar-remove', Icons.remove_circle_outline, 'Remove from quick bar')
              else if (bar && !hidden && !_c.quickBarFull)
                item('bar-add', Icons.bolt_outlined, 'Add to quick bar'),
              if (inBar)
                const SizedBox.shrink()
              else if (onHome)
                item('unpin', Icons.remove_circle_outline, 'Remove from home')
              else if (!hidden)
                item('pin', Icons.push_pin_outlined, 'Add to home'),
              if (hidden)
                item('unhide', Icons.visibility_outlined, 'Unhide')
              else
                item('hide', Icons.visibility_off_outlined, 'Hide'),
              if (app.isPair)
                item('delete-pair', Icons.delete_outline, 'Delete pair')
              else ...[
                item('info', Icons.info_outline, 'App info'),
                item('uninstall', Icons.delete_outline, 'Uninstall'),
              ],
            ],
          ),
        );
      },
    );
    switch (action) {
      case 'unpin':
        _c.removeFromHome(app);
      case 'pin':
        _c.pinToHome(app);
      case 'bar-add':
        _c.addToQuickBar(app);
      case 'bar-remove':
        _c.removeFromQuickBar(_c.quickBar.firstWhere((i) => i.app?.key == app.key).key);
      case 'hide':
        _c.setHidden(app, true);
      case 'unhide':
        _c.setHidden(app, false);
      case 'info':
        await _c.source.appInfo(app);
      case 'uninstall':
        await _c.source.uninstall(app);
      case 'delete-pair':
        _c.removePair(app.pair!);
    }
  }

  /// Long-press on a ghost in the quick bar: it can only be taken out.
  Future<void> _showGhostMenu(QuickBarItem item) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(item.label, style: Theme.of(context).textTheme.titleMedium)),
            ListTile(
              key: const Key('menu-bar-remove'),
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Remove from quick bar'),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (remove == true) _c.removeFromQuickBar(item.key);
  }

  /// Double-tap on empty home space: lock the phone.
  Future<void> _lock() async {
    if (await _c.source.lockScreen()) return;
    _needsService('Locking');
  }

  void _needsService(String what) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what needs TurboLaunch actions turned on under Accessibility.'),
        action: SnackBarAction(label: 'Open', onPressed: _c.source.openAccessibilitySettings),
      ),
    );
  }

  /// The path of the swipe in progress, in the home area's logical pixels.
  final _path = <Offset>[];

  /// Swipes on empty home space: each recognised gesture runs the action
  /// settings give it (see [Gestures]).
  Widget _gestures(Widget child) {
    if (_c.settings.gestures.isEmpty) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Its drag actions would merge every cell into one semantics node,
      // so TalkBack (and uiautomator) could no longer tell the apps apart.
      excludeFromSemantics: true,
      onPanStart: (d) => _path
        ..clear()
        ..add(d.localPosition),
      onPanUpdate: (d) => _path.add(d.localPosition),
      onPanEnd: (d) {
        final code = Gestures.recognize(_path, velocity: d.velocity.pixelsPerSecond);
        _path.clear();
        if (code.isNotEmpty) _run(_c.settings.gestureAction(code));
      },
      onPanCancel: _path.clear,
      child: child,
    );
  }

  Future<void> _run(GestureAction action) async {
    switch (action.kind) {
      case GestureKind.none:
        return;
      case GestureKind.search:
        _focus.requestFocus();
      case GestureKind.notifications:
        await _c.source.expandNotifications();
      case GestureKind.quickSettings:
        await _c.source.expandQuickSettings();
      case GestureKind.launch:
        final app = _c.entryByKey(action.target ?? '');
        if (app != null) await _c.launch(app);
      case GestureKind.shortcut:
        final s = action.shortcutIn(_c.shortcuts);
        if (s != null) await _c.source.startShortcut(s);
      case GestureKind.lock:
        await _lock();
      case GestureKind.recents || GestureKind.powerMenu || GestureKind.screenshot || GestureKind.splitScreen:
        if (!await _c.source.globalAction(action.kind.name)) _needsService(action.kind.label);
      case GestureKind.flashlight:
        await _c.source.toggleFlashlight();
      case GestureKind.quickHide:
        _c.toggleQuickHide();
      case GestureKind.settings:
        _openSettings();
      case GestureKind.stats:
        _focus.unfocus();
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => StatsScreen(controller: _c, icons: widget.icons),
          ),
        );
    }
  }

  /// Shown when sync is on but has not worked for a week.
  Widget _syncWarning(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        key: const Key('sync-warning'),
        dense: true,
        leading: Icon(Icons.sync_problem, color: scheme.onErrorContainer),
        title: Text('No sync for over a week. Tap to check sync.', style: TextStyle(color: scheme.onErrorContainer)),
        onTap: () {
          _focus.unfocus();
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SyncScreen(controller: _c)));
        },
      ),
    ),
  );

  void _openSettings() {
    _focus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(controller: _c, icons: widget.icons),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only empty space listens for double-taps, so taps on apps are never delayed.
    final lockOnDoubleTap = _c.settings.doubleTapLock ? _lock : null;
    // Read here, above the Scaffold: the Scaffold takes the keyboard's inset
    // out of the MediaQuery its body sees.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      // Back on the home screen clears the search instead of leaving.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        _c.query = '';
        _focus.unfocus();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              if (_c.settings.showClockLine && !_searching) _ClockLine(controller: _c, onLongPress: _c.toggleQuickHide),
              if (_c.syncOverdue && !_searching) _syncWarning(scheme),
              Expanded(
                child: !_c.loaded
                    ? const SizedBox.shrink()
                    : _searching
                    ? _results(scheme)
                    : _gestures(
                        _c.quickHide
                            ? GestureDetector(
                                key: const Key('quick-hidden'),
                                behavior: HitTestBehavior.opaque,
                                onLongPress: _c.toggleQuickHide,
                                onDoubleTap: lockOnDoubleTap,
                              )
                            : Column(
                                children: [
                                  Expanded(
                                    child: _HomeGrid(
                                      keyboardOpen: keyboardOpen,
                                      controller: _c,
                                      icons: widget.icons,
                                      onLongPress: _showMenu,
                                      onDoubleTap: lockOnDoubleTap,
                                    ),
                                  ),
                                  if (_c.settings.quickBar)
                                    _QuickBar(
                                      controller: _c,
                                      icons: widget.icons,
                                      onLongPress: _showMenu,
                                      onGhostLongPress: _showGhostMenu,
                                      onDoubleTap: lockOnDoubleTap,
                                    ),
                                ],
                              ),
                      ),
              ),
              _searchRow(scheme),
            ],
          ),
        ),
      ),
    );
  }

  /// The finger's path over the results, for [_swipeAway].
  final _resultsPath = <Offset>[];
  VelocityTracker? _resultsVelocity;

  /// Whether the results list scrolled while the finger was down.
  bool _resultsScrolled = false;

  /// A swipe up over the results closes the search, unless it scrolled the
  /// list: a long list scrolls first and closes once it is at its end.
  Widget _swipeAway(Widget child) {
    return Listener(
      onPointerDown: (e) {
        _resultsScrolled = false;
        _resultsPath
          ..clear()
          ..add(e.localPosition);
        _resultsVelocity = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.localPosition);
      },
      onPointerMove: (e) {
        _resultsPath.add(e.localPosition);
        _resultsVelocity?.addPosition(e.timeStamp, e.localPosition);
      },
      onPointerUp: (e) {
        final velocity = _resultsVelocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
        final up = !_resultsScrolled && Gestures.recognize(_resultsPath, velocity: velocity) == 'U';
        _resultsPath.clear();
        _resultsVelocity = null;
        if (up) {
          _c.query = '';
          _focus.unfocus();
        }
      },
      onPointerCancel: (_) {
        _resultsPath.clear();
        _resultsVelocity = null;
      },
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (n.scrollDelta != 0) _resultsScrolled = true;
          return false;
        },
        child: child,
      ),
    );
  }

  Widget _results(ColorScheme scheme) {
    final results = _c.results;
    return _swipeAway(
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Material(
          // Only the panel is see-through; icons stay fully opaque.
          color: scheme.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: results.isEmpty
              ? Center(child: Text(_c.query.trim().isEmpty ? 'No apps' : 'No match'))
              : ListView.builder(
                  key: const Key('app-list'),
                  controller: _scroll,
                  // The best match sits right above the search box.
                  reverse: _c.query.isNotEmpty,
                  itemCount: results.length,
                  itemBuilder: (context, i) => _ResultTile(
                    result: results[i],
                    icons: widget.icons,
                    scale: _c.settings.resultScale,
                    showIcon: _c.settings.iconsInResults,
                    onTap: () => _launch(results[i]),
                    onLongPress: () => _showMenu(results[i].owner!),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _searchRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            // The identifier is the field's resource-id on Android, which
            // tool/e2e_android.sh finds it by; the hint text is not dumped.
            child: Semantics(
              identifier: 'search',
              child: TextField(
                key: const Key('search'),
                controller: _search,
                focusNode: _focus,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.go,
                onChanged: (v) {
                  Bench.keystroke();
                  _c.query = v;
                },
                onSubmitted: (_) {
                  _focus.unfocus();
                  _c.launchTopMatch();
                },
                decoration: InputDecoration(
                  hintText: 'Search apps',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? IconButton(
                          key: const Key('close-search'),
                          tooltip: 'Close search',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _c.query = '';
                            _focus.unfocus();
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                  // A swipe up lands here; the outline shows where typing goes.
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            key: const Key('open-settings'),
            tooltip: 'TurboLaunch settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
    );
  }
}

/// Time, date and optional battery. Long-press toggles quick hide.
class _ClockLine extends StatefulWidget {
  const _ClockLine({required this.controller, required this.onLongPress});

  final LauncherController controller;
  final VoidCallback onLongPress;

  @override
  State<_ClockLine> createState() => _ClockLineState();
}

class _ClockLineState extends State<_ClockLine> {
  Timer? _timer;
  DateTime _now = DateTime.now();
  int _battery = -1;
  var _wantBattery = false;
  var _tickGen = 0;

  @override
  void initState() {
    super.initState();
    _wantBattery = widget.controller.settings.showBattery;
    widget.controller.addListener(_onController);
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _timer?.cancel();
    super.dispose();
  }

  void _onController() {
    final want = widget.controller.settings.showBattery;
    if (want == _wantBattery) return;
    _wantBattery = want;
    unawaited(_tick());
  }

  Future<void> _tick() async {
    final gen = ++_tickGen;
    final showBattery = widget.controller.settings.showBattery;
    final battery = showBattery ? await widget.controller.source.battery() : -1;
    if (!mounted || gen != _tickGen) return;
    setState(() {
      _now = DateTime.now();
      _battery = battery;
      _wantBattery = showBattery;
    });
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    final scale = settings.clockScale;
    final showBattery = settings.showBattery;
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${_days[_now.weekday - 1]} ${_now.day} ${_months[_now.month - 1]}';
    const shadow = [Shadow(blurRadius: 4, color: Colors.black54)];
    // Identifier is the Android resource-id tool/e2e_android.sh finds it by.
    return Semantics(
      identifier: 'clock-line',
      container: true,
      child: GestureDetector(
        key: const Key('clock-line'),
        behavior: HitTestBehavior.opaque,
        onLongPress: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white, shadows: shadow),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (settings.showTime)
                  Text('${two(_now.hour)}:${two(_now.minute)}', style: TextStyle(fontSize: 32 * scale)),
                if (settings.showTime && settings.showDate) const SizedBox(width: 12),
                Expanded(
                  child: settings.showDate
                      ? Text(date, style: TextStyle(fontSize: 16 * scale))
                      : const SizedBox.shrink(),
                ),
                if (showBattery && _battery >= 0) Text('$_battery%', style: TextStyle(fontSize: 16 * scale)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The home grid. Measures its own area and reports the automatic size to
/// the controller, which places apps; cells never move once placed.
class _HomeGrid extends StatelessWidget {
  const _HomeGrid({
    required this.keyboardOpen,
    required this.controller,
    required this.icons,
    required this.onLongPress,
    this.onDoubleTap,
  });

  final bool keyboardOpen;

  final LauncherController controller;
  final IconCache icons;
  final void Function(AppEntry) onLongPress;

  /// For empty cells only.
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final auto = autoGridSize(box.maxWidth, box.maxHeight, labelScale: controller.settings.labelScale);
        // The keyboard shrinks the area for a moment; that must not cut cells.
        if (!keyboardOpen) {
          WidgetsBinding.instance.addPostFrameCallback((_) => controller.setAutoGridSize(auto.rows, auto.cols));
        }
        // Before the controller has the size (the very first frame), draw the
        // cells already placed at the size this screen gives, so a cold start
        // shows the grid at once instead of a frame later.
        final (rows, cols) = controller.rows > 0
            ? (controller.rows, controller.cols)
            : controller.gridSizeFor(auto.rows, auto.cols);
        if (rows == 0 || cols == 0) return const SizedBox.shrink();
        final grid = controller.grid, ghosts = controller.ghosts, borrowed = controller.borrowed;
        final bar = controller.settings.quickBar;
        // An app dragged out of the quick bar and dropped on the grid leaves the bar.
        return DragTarget<_Dragged>(
          onWillAcceptWithDetails: (d) => d.data.fromBar,
          onAcceptWithDetails: (d) => controller.removeFromQuickBar(d.data.key),
          builder: (context, _, _) => Column(
            key: const Key('home-grid'),
            children: [
              for (var r = 0; r < rows; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var c = 0; c < cols; c++)
                        Expanded(
                          child: grid[Cell(r, c)] == null && ghosts[Cell(r, c)] != null
                              ? _GhostCell(
                                  key: ValueKey('ghost-$r-$c'),
                                  label: ghosts[Cell(r, c)]!,
                                  labelScale: controller.settings.labelScale,
                                )
                              : grid[Cell(r, c)] == null
                              ? GestureDetector(
                                  key: ValueKey('empty-$r-$c'),
                                  behavior: HitTestBehavior.opaque,
                                  excludeFromSemantics: true,
                                  onDoubleTap: onDoubleTap,
                                  child: const SizedBox.expand(),
                                )
                              : _GridCell(
                                  app: grid[Cell(r, c)]!,
                                  icons: icons,
                                  labelScale: controller.settings.labelScale,
                                  borrowed: borrowed.contains(Cell(r, c)),
                                  draggable: bar,
                                  onTap: () => controller.launch(grid[Cell(r, c)]!),
                                  onLongPress: () => onLongPress(grid[Cell(r, c)]!),
                                ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _GridCell extends StatelessWidget {
  const _GridCell({
    required this.app,
    required this.icons,
    required this.labelScale,
    required this.onTap,
    this.onLongPress,
    this.borrowed = false,
    this.draggable = false,
  });

  final AppEntry app;
  final IconCache icons;
  final double labelScale;

  /// In a ghost's cell, lent because the grid was full: drawn a little grey.
  final bool borrowed;

  /// A long-press lifts the app, to drop it into the quick bar; let go
  /// without moving, it opens the menu as before.
  final bool draggable;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // Each cell is its own accessibility node, whatever wraps the grid.
    final cell = Semantics(
      container: true,
      child: InkWell(
        key: ValueKey('cell-${app.key}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: draggable ? null : onLongPress,
        // Scales down rather than overflowing while the keyboard squeezes the grid.
        child: LayoutBuilder(
          builder: (context, box) => Opacity(
            opacity: borrowed ? 0.55 : 1,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: box.maxWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AppIcon(app: app, cache: icons, size: 48),
                        if (app.otherProfile)
                          const Positioned(
                            right: -4,
                            bottom: -4,
                            child: Icon(Icons.work, size: 16, color: Colors.white),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        app.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12 * labelScale,
                          color: Colors.white,
                          shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!draggable) return cell;
    return _Liftable(
      data: _Dragged(app.key, fromBar: false, app: app),
      feedback: AppIcon(app: app, cache: icons, size: 56),
      onMenu: onLongPress ?? () {},
      child: cell,
    );
  }
}

/// What is being dragged: an app from the grid, or an entry of the quick bar.
class _Dragged {
  const _Dragged(this.key, {required this.fromBar, this.app});

  final String key;
  final bool fromBar;
  final AppEntry? app;
}

/// Lifts [child] on a long-press, to drag it somewhere; let go without
/// moving, it opens the menu ([onMenu]) instead, as a plain long-press would.
class _Liftable extends StatefulWidget {
  const _Liftable({required this.data, required this.feedback, required this.onMenu, required this.child});

  final _Dragged data;
  final Widget feedback;
  final VoidCallback onMenu;
  final Widget child;

  @override
  State<_Liftable> createState() => _LiftableState();
}

class _LiftableState extends State<_Liftable> {
  /// How far the finger moved since the app was lifted.
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<_Dragged>(
      data: widget.data,
      hapticFeedbackOnStart: true,
      // The icon sits under the finger, a little above it so it shows.
      dragAnchorStrategy: (_, _, _) => const Offset(28, 56),
      feedback: Material(type: MaterialType.transparency, child: widget.feedback),
      childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
      onDragStarted: () => _moved = 0,
      onDragUpdate: (d) => _moved += d.delta.distance,
      onDraggableCanceled: (_, _) {
        if (_moved < 16) widget.onMenu();
      },
      child: widget.child,
    );
  }
}

/// The quick launch bar under the grid: apps put there by hand, left to
/// right, one slot per grid column. A tinted, outlined panel, so it reads as
/// a dock and not as one more grid row. Apps are dragged in from the grid
/// (or added from the long-press menu), dragged along it to reorder, and
/// dragged out onto the grid to take them out. Empty, it says so.
class _QuickBar extends StatelessWidget {
  const _QuickBar({
    required this.controller,
    required this.icons,
    required this.onLongPress,
    required this.onGhostLongPress,
    this.onDoubleTap,
  });

  final LauncherController controller;
  final IconCache icons;
  final void Function(AppEntry) onLongPress;
  final void Function(QuickBarItem) onGhostLongPress;

  /// For empty slots only.
  final VoidCallback? onDoubleTap;

  /// The bar's height at label scale 1.
  static const height = 84.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = controller.settings.labelScale;
    final items = controller.quickBar;
    final slots = controller.quickBarSlots;
    final full = controller.quickBarFull;

    Widget target(int i, Widget Function(bool hovered) child) => DragTarget<_Dragged>(
      onWillAcceptWithDetails: (d) =>
          d.data.fromBar ? (i >= items.length || items[i].key != d.data.key) : (!full && d.data.app != null),
      onAcceptWithDetails: (d) =>
          d.data.fromBar ? controller.moveInQuickBar(d.data.key, i) : controller.addToQuickBar(d.data.app!, at: i),
      builder: (context, candidates, _) => child(candidates.isNotEmpty),
    );

    Widget slot(bool hovered, Widget child) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: hovered ? scheme.primary.withValues(alpha: 0.35) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );

    return Semantics(
      identifier: 'quick-bar',
      container: true,
      child: Container(
        key: const Key('quick-bar'),
        height: height + 16 * (scale - 1),
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.7), width: 1.5),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < slots; i++)
                  Expanded(
                    child: target(
                      i,
                      (hovered) => slot(
                        hovered,
                        i >= items.length
                            ? GestureDetector(
                                key: ValueKey('bar-empty-$i'),
                                behavior: HitTestBehavior.opaque,
                                excludeFromSemantics: true,
                                onDoubleTap: onDoubleTap,
                                child: const SizedBox.expand(),
                              )
                            : items[i].app == null
                            ? _Liftable(
                                data: _Dragged(items[i].key, fromBar: true),
                                feedback: const Icon(Icons.help_outline, size: 48, color: Colors.white),
                                onMenu: () => onGhostLongPress(items[i]),
                                child: _GhostCell(
                                  key: ValueKey('bar-ghost-${items[i].key}'),
                                  label: items[i].label,
                                  labelScale: scale,
                                ),
                              )
                            : _Liftable(
                                data: _Dragged(items[i].key, fromBar: true, app: items[i].app),
                                feedback: AppIcon(app: items[i].app!, cache: icons, size: 56),
                                onMenu: () => onLongPress(items[i].app!),
                                child: KeyedSubtree(
                                  key: ValueKey('bar-${items[i].app!.key}'),
                                  child: _GridCell(
                                    app: items[i].app!,
                                    icons: icons,
                                    labelScale: scale,
                                    onTap: () => controller.launch(items[i].app!),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
            if (items.isEmpty)
              IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Drag apps here for quick launch',
                      key: const Key('quick-bar-hint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14 * scale,
                        color: Colors.white.withValues(alpha: 0.85),
                        fontStyle: FontStyle.italic,
                        shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A cell the other phones keep for an app this phone lacks: a faded
/// outline with the app's name, so the grid looks the same on every phone.
/// Tapping it only says so; installing the app puts it there.
class _GhostCell extends StatelessWidget {
  const _GhostCell({super.key, required this.label, required this.labelScale});

  final String label;
  final double labelScale;

  @override
  Widget build(BuildContext context) {
    const faded = Color(0x99FFFFFF);
    const shadow = [Shadow(blurRadius: 4, color: Colors.black87)];
    return Semantics(
      container: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$label is on your other phones, not on this one.'))),
        child: LayoutBuilder(
          builder: (context, box) => FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: box.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0x22FFFFFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: faded, width: 1.5),
                    ),
                    child: ExcludeSemantics(
                      child: Text(
                        label.isEmpty ? '?' : label.characters.first.toUpperCase(),
                        style: const TextStyle(fontSize: 22, color: faded, shadows: shadow),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12 * labelScale,
                        color: faded,
                        fontStyle: FontStyle.italic,
                        shadows: shadow,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.icons,
    required this.scale,
    required this.showIcon,
    required this.onTap,
    required this.onLongPress,
  });

  final SearchResult result;
  final IconCache icons;
  final double scale;
  final bool showIcon;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge!;
    final base = body.copyWith(fontSize: (body.fontSize ?? 16) * scale);
    final owner = result.owner!;
    return ListTile(
      key: ValueKey(result.app != null ? owner.key : '${owner.key}:${result.shortcut!.id}'),
      leading: showIcon ? AppIcon(app: owner, cache: icons, size: result.shortcut == null ? 40 : 28) : null,
      title: MatchedText(result.title, positions: result.positions, style: base),
      subtitle: result.shortcut != null ? Text(owner.label) : null,
      trailing: owner.isPair
          ? const Icon(Icons.vertical_split_outlined, size: 18)
          : owner.otherProfile
          ? const Icon(Icons.work_outline, size: 18)
          : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
