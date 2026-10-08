import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_source.dart';
import '../services/home_grid.dart';
import '../services/launcher_controller.dart';
import '../widgets/app_icon.dart';
import 'settings_screen.dart';

/// The home screen: the clock line at the top, the home grid filled by
/// launch count, and the search box docked at the bottom within thumb reach.
/// Focusing the search swaps the grid for live fuzzy results.
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

  LauncherController get _c => widget.controller;
  bool get _searching => _focus.hasFocus || _c.query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onController);
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
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
      if (_c.settings.keyboardOnHome) {
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
              if (onHome)
                item('unpin', Icons.remove_circle_outline, 'Remove from home')
              else if (!hidden)
                item('pin', Icons.push_pin_outlined, 'Add to home'),
              if (hidden)
                item('unhide', Icons.visibility_outlined, 'Unhide')
              else
                item('hide', Icons.visibility_off_outlined, 'Hide'),
              item('info', Icons.info_outline, 'App info'),
              item('uninstall', Icons.delete_outline, 'Uninstall'),
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
      case 'hide':
        _c.setHidden(app, true);
      case 'unhide':
        _c.setHidden(app, false);
      case 'info':
        await _c.source.appInfo(app);
      case 'uninstall':
        await _c.source.uninstall(app);
    }
  }

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
              if (_c.settings.showClock && !_searching) _ClockLine(controller: _c, onLongPress: _c.toggleQuickHide),
              Expanded(
                child: !_c.loaded
                    ? const SizedBox.shrink()
                    : _searching
                    ? _results(scheme)
                    : _c.quickHide
                    ? GestureDetector(
                        key: const Key('quick-hidden'),
                        behavior: HitTestBehavior.opaque,
                        onLongPress: _c.toggleQuickHide,
                      )
                    : _HomeGrid(controller: _c, icons: widget.icons, onLongPress: _showMenu),
              ),
              _searchRow(scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _results(ColorScheme scheme) {
    final results = _c.results;
    return Padding(
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
    );
  }

  Widget _searchRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('search'),
              controller: _search,
              focusNode: _focus,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onChanged: (v) => _c.query = v,
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

/// Time, date and battery. Long-press toggles quick hide.
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

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    final battery = await widget.controller.source.battery();
    if (mounted) {
      setState(() {
        _now = DateTime.now();
        _battery = battery;
      });
    }
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final scale = widget.controller.settings.clockScale;
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${_days[_now.weekday - 1]} ${_now.day} ${_months[_now.month - 1]}';
    const shadow = [Shadow(blurRadius: 4, color: Colors.black54)];
    return GestureDetector(
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
              Text('${two(_now.hour)}:${two(_now.minute)}', style: TextStyle(fontSize: 32 * scale)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(date, style: TextStyle(fontSize: 16 * scale)),
              ),
              if (_battery >= 0) Text('$_battery%', style: TextStyle(fontSize: 16 * scale)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The home grid. Measures its own area and reports the automatic size to
/// the controller, which places apps; cells never move once placed.
class _HomeGrid extends StatelessWidget {
  const _HomeGrid({required this.controller, required this.icons, required this.onLongPress});

  final LauncherController controller;
  final IconCache icons;
  final void Function(AppEntry) onLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final auto = autoGridSize(box.maxWidth, box.maxHeight, labelScale: controller.settings.labelScale);
        // The keyboard shrinks the area for a moment; that must not cut cells.
        if (!keyboardOpen) {
          WidgetsBinding.instance.addPostFrameCallback((_) => controller.setAutoGridSize(auto.rows, auto.cols));
        }
        final rows = controller.rows, cols = controller.cols;
        if (rows == 0 || cols == 0) return const SizedBox.shrink();
        final grid = controller.grid;
        return Column(
          key: const Key('home-grid'),
          children: [
            for (var r = 0; r < rows; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < cols; c++)
                      Expanded(
                        child: grid[Cell(r, c)] == null
                            ? const SizedBox.expand()
                            : _GridCell(
                                app: grid[Cell(r, c)]!,
                                icons: icons,
                                labelScale: controller.settings.labelScale,
                                onTap: () => controller.launch(grid[Cell(r, c)]!),
                                onLongPress: () => onLongPress(grid[Cell(r, c)]!),
                              ),
                      ),
                  ],
                ),
              ),
          ],
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
    required this.onLongPress,
  });

  final AppEntry app;
  final IconCache icons;
  final double labelScale;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('cell-${app.key}'),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AppIcon(app: app, cache: icons, size: 48),
              if (app.otherProfile)
                const Positioned(right: -4, bottom: -4, child: Icon(Icons.work, size: 16, color: Colors.white)),
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
    final hit = base.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary);
    final title = result.title;
    final marked = result.positions.toSet();
    final owner = result.owner!;
    return ListTile(
      key: ValueKey(result.app != null ? owner.key : '${owner.key}:${result.shortcut!.id}'),
      leading: showIcon ? AppIcon(app: owner, cache: icons, size: result.shortcut == null ? 40 : 28) : null,
      title: Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < title.length; i++) TextSpan(text: title[i], style: marked.contains(i) ? hit : base),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: result.shortcut != null ? Text(owner.label) : null,
      trailing: owner.otherProfile ? const Icon(Icons.work_outline, size: 18) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
