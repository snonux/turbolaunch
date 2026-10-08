import 'package:flutter/material.dart';
import 'package:launcher_platform/launcher_platform.dart';

import '../services/app_source.dart';
import '../services/app_version.dart';
import '../services/launcher_controller.dart';
import '../services/startup_timer.dart';
import '../widgets/app_icon.dart';

/// Settings. In phase 1: picking the home app, the measured cold start, the
/// app-pair spike and the version.
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

  AppSource get _source => widget.controller.source;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkService();
  }

  @override
  void dispose() {
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
