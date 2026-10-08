import 'package:flutter/material.dart';
import 'package:launcher_platform/launcher_platform.dart';

import '../services/app_source.dart';
import '../services/app_version.dart';
import '../services/launcher_controller.dart';
import '../services/launcher_store.dart';
import '../services/startup_timer.dart';
import '../widgets/app_icon.dart';

/// Settings: the home app, cold start, wallpapers, grid size, search, font
/// sizes, hidden apps, the app-pair test and the version.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller, required this.icons});

  final LauncherController controller;
  final IconCache icons;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  AppEntry? _first;
  AppEntry? _second;
  bool? _serviceEnabled;
  String? _pairResult;
  String? _wallpaperResult;

  AppSource get _source => widget.controller.source;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_rebuild);
    _checkService();
  }

  void _rebuild() => setState(() {});

  void _update(LauncherSettings s) => widget.controller.updateSettings(s);

  Widget _header(String title, TextTheme text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(title, style: text.titleMedium),
  );

  Future<void> _pickWallpaper(WallpaperTarget target) async {
    final ok = await _source.pickWallpaper(target);
    if (!mounted || ok == null) return;
    setState(() => _wallpaperResult = ok ? 'Wallpaper set.' : 'Could not set the wallpaper.');
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the system's accessibility settings re-checks the switch.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkService();
  }

  Future<void> _checkService() async {
    final enabled = await _source.splitServiceEnabled();
    if (mounted) setState(() => _serviceEnabled = enabled);
  }

  Future<void> _openPair() async {
    final first = _first, second = _second;
    if (first == null || second == null) return;
    final outcome = await _source.launchPair(first, second);
    if (!mounted) return;
    setState(
      () => _pairResult = switch (outcome) {
        PairOutcome.split => 'Opened ${first.label} and ${second.label} in split screen.',
        PairOutcome.noService => 'Opened ${first.label} only: turn on TurboLaunch actions under Accessibility first.',
        PairOutcome.failed => 'Could not open the pair.',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.controller.apps;
    final text = Theme.of(context).textTheme;
    final s = widget.controller.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            key: const Key('set-home'),
            leading: const Icon(Icons.home_outlined),
            title: const Text('Set as home app'),
            subtitle: const Text('Opens the system list of home apps'),
            onTap: _source.openHomeSettings,
          ),
          ValueListenableBuilder<int?>(
            valueListenable: StartupTimer.coldStartMillis,
            builder: (context, ms, _) => ListTile(
              key: const Key('cold-start'),
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Cold start'),
              subtitle: Text(ms == null || ms < 0 ? 'Not measured' : '$ms ms from process start to first frame'),
            ),
          ),
          const Divider(),
          _header('Wallpaper', text),
          for (final (target, label) in const [
            (WallpaperTarget.home, 'Home screen wallpaper'),
            (WallpaperTarget.lock, 'Lock screen wallpaper'),
            (WallpaperTarget.both, 'Both'),
          ])
            ListTile(
              key: Key('wallpaper-${target.name}'),
              leading: const Icon(Icons.wallpaper_outlined),
              title: Text(label),
              subtitle: target == WallpaperTarget.both ? const Text('One picture for home and lock screen') : null,
              onTap: () => _pickWallpaper(target),
            ),
          if (_wallpaperResult != null)
            Padding(padding: const EdgeInsets.fromLTRB(72, 0, 16, 8), child: Text(_wallpaperResult!)),
          const Divider(),
          _header('Home grid', text),
          _GridSizeTile(
            key: const Key('grid-cols'),
            label: 'Columns',
            value: s.gridCols,
            current: widget.controller.cols,
            onChanged: (v) => _update(s.copyWith(gridCols: v)),
          ),
          _GridSizeTile(
            key: const Key('grid-rows'),
            label: 'Rows',
            value: s.gridRows,
            current: widget.controller.rows,
            onChanged: (v) => _update(s.copyWith(gridRows: v)),
          ),
          SwitchListTile(
            key: const Key('show-clock'),
            title: const Text('Clock line'),
            subtitle: const Text('Time, date and battery at the top; long-press it to hide the grid'),
            value: s.showClock,
            onChanged: (v) => _update(s.copyWith(showClock: v)),
          ),
          const Divider(),
          _header('Search', text),
          SwitchListTile(
            key: const Key('keyboard-on-home'),
            title: const Text('Open the keyboard on Home'),
            subtitle: const Text('Otherwise tap the search box'),
            value: s.keyboardOnHome,
            onChanged: (v) => _update(s.copyWith(keyboardOnHome: v)),
          ),
          SwitchListTile(
            key: const Key('icons-in-results'),
            title: const Text('Icons in search results'),
            value: s.iconsInResults,
            onChanged: (v) => _update(s.copyWith(iconsInResults: v)),
          ),
          const Divider(),
          _header('Font sizes', text),
          _ScaleTile(
            key: const Key('scale-labels'),
            label: 'Grid labels',
            value: s.labelScale,
            onChanged: (v) => _update(s.copyWith(labelScale: v)),
          ),
          _ScaleTile(
            key: const Key('scale-results'),
            label: 'Search results',
            value: s.resultScale,
            onChanged: (v) => _update(s.copyWith(resultScale: v)),
          ),
          _ScaleTile(
            key: const Key('scale-clock'),
            label: 'Clock line',
            value: s.clockScale,
            onChanged: (v) => _update(s.copyWith(clockScale: v)),
          ),
          if (widget.controller.hidden.isNotEmpty) ...[
            const Divider(),
            _header('Hidden apps', text),
            for (final a in widget.controller.apps.where(widget.controller.isHidden))
              ListTile(
                key: Key('hidden-${a.key}'),
                leading: AppIcon(app: a, cache: widget.icons, size: 32),
                title: Text(a.label),
                trailing: TextButton(
                  onPressed: () => widget.controller.setHidden(a, false),
                  child: const Text('Unhide'),
                ),
              ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('App pair test', style: text.titleMedium),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Opens two apps side by side. This needs the opt-in TurboLaunch actions '
              'accessibility service, which does nothing but switch to split screen.',
            ),
          ),
          ListTile(
            key: const Key('split-service'),
            leading: Icon(_serviceEnabled == true ? Icons.check_circle_outline : Icons.accessibility_new),
            title: const Text('Accessibility service'),
            subtitle: Text(switch (_serviceEnabled) {
              null => 'Checking',
              true => 'On',
              false => 'Off: tap to open Accessibility settings',
            }),
            onTap: _source.openAccessibilitySettings,
          ),
          _AppPicker(
            key: const Key('pair-first'),
            label: 'Top app',
            apps: apps,
            value: _first,
            icons: widget.icons,
            onChanged: (a) => setState(() => _first = a),
          ),
          _AppPicker(
            key: const Key('pair-second'),
            label: 'Bottom app',
            apps: apps,
            value: _second,
            icons: widget.icons,
            onChanged: (a) => setState(() => _second = a),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.icon(
              key: const Key('open-pair'),
              onPressed: _first != null && _second != null && _first != _second ? _openPair : null,
              icon: const Icon(Icons.vertical_split_outlined),
              label: const Text('Open pair'),
            ),
          ),
          if (_pairResult != null)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_pairResult!)),
          const Divider(),
          FutureBuilder<String>(
            future: loadAppVersion(DefaultAssetBundle.of(context)),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('TurboLaunch'),
              subtitle: Text(snap.hasData ? 'Version ${snap.data}' : ''),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppPicker extends StatelessWidget {
  const _AppPicker({
    super.key,
    required this.label,
    required this.apps,
    required this.value,
    required this.icons,
    required this.onChanged,
  });

  final String label;
  final List<AppEntry> apps;
  final AppEntry? value;
  final IconCache icons;
  final ValueChanged<AppEntry?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: DropdownButtonFormField<AppEntry>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [
          for (final a in apps)
            DropdownMenuItem(
              value: a,
              child: Row(
                children: [
                  AppIcon(app: a, cache: icons, size: 24),
                  const SizedBox(width: 12),
                  Expanded(child: Text(a.label, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Auto or a fixed number of rows or columns.
class _GridSizeTile extends StatelessWidget {
  const _GridSizeTile({
    super.key,
    required this.label,
    required this.value,
    required this.current,
    required this.onChanged,
  });

  final String label;

  /// 0 for automatic.
  final int value;

  /// What the grid has now, shown next to "Auto".
  final int current;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: DropdownButton<int>(
        value: value,
        items: [
          DropdownMenuItem(value: 0, child: Text(current > 0 ? 'Auto ($current)' : 'Auto')),
          for (var n = 1; n <= 12; n++) DropdownMenuItem(value: n, child: Text('$n')),
        ],
        onChanged: (v) => onChanged(v ?? 0),
      ),
    );
  }
}

/// A font size factor from 80 to 160 percent.
class _ScaleTile extends StatelessWidget {
  const _ScaleTile({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text('$label: ${(value * 100).round()}%'),
      subtitle: Slider(
        value: value,
        min: LauncherSettings.minScale,
        max: LauncherSettings.maxScale,
        divisions: 8,
        label: '${(value * 100).round()}%',
        onChanged: onChanged,
      ),
    );
  }
}
