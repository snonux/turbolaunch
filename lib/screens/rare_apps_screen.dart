import 'package:flutter/material.dart';
import 'package:launcher_platform/launcher_platform.dart';

import '../services/app_source.dart';
import '../services/launch_log.dart';
import '../services/launcher_controller.dart';
import '../widgets/app_icon.dart';

/// Apps never or rarely launched on this phone within the launch window,
/// fewest launches first, each with a button for Android's uninstall dialog.
/// System apps, which can only be turned off in App info, are left out
/// unless asked for. Reached only from settings.
class RareAppsScreen extends StatefulWidget {
  const RareAppsScreen({super.key, required this.controller, required this.icons});

  final LauncherController controller;
  final IconCache icons;

  @override
  State<RareAppsScreen> createState() => _RareAppsScreenState();
}

class _RareAppsScreenState extends State<RareAppsScreen> {
  LauncherController get _c => widget.controller;

  /// What the device says about each installed app, null until it answered.
  Map<String, PlatformAppDetails>? _details;
  List<AppEntry>? _detailsFor;
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_loadDetails);
    _loadDetails();
  }

  @override
  void dispose() {
    _c.removeListener(_loadDetails);
    super.dispose();
  }

  /// Asks the device again whenever the app list changed, e.g. after an
  /// uninstall.
  Future<void> _loadDetails() async {
    final apps = _c.installedApps;
    if (identical(apps, _detailsFor)) return;
    _detailsFor = apps;
    final details = await _c.source.appDetails(apps);
    if (mounted && identical(apps, _detailsFor)) setState(() => _details = details);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final details = _details;
        final system = {
          if (details != null && !_showSystem)
            for (final MapEntry(:key, :value) in details.entries)
              if (value.system) key,
        };
        final rare = _c.rarelyUsed(skip: system);
        final never = rare.where((r) => r.here == 0).toList();
        final least = rare.where((r) => r.here > 0).toList();
        final synced = _c.otherPhones.isNotEmpty;
        final days = _c.settings.launchWindowDays;
        final window = describeWindow(days);
        final text = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(title: const Text('Rarely used apps')),
          body: ListView(
            key: const Key('rare-list'),
            children: [
              ListTile(
                key: const Key('rare-intro'),
                title: Text(
                  'Apps launched least on this phone, counting ${days == 0 ? 'all launches' : 'launches of $window'}. '
                  'The bin opens Android\'s uninstall dialog; tap an app for its App info.',
                ),
              ),
              SwitchListTile(
                key: const Key('rare-system'),
                title: const Text('Show system apps'),
                subtitle: const Text('They cannot be uninstalled, only turned off in App info'),
                value: _showSystem,
                onChanged: (v) => setState(() => _showSystem = v),
              ),
              if (details == null)
                const Center(
                  child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
                )
              else if (rare.isEmpty)
                const ListTile(key: Key('rare-empty'), title: Text('No apps to suggest')),
              if (details != null && never.isNotEmpty) ...[
                _header(days == 0 ? 'Never launched' : 'Not launched in $window', text),
                for (final r in never) _row(r, details[r.app.key], synced),
              ],
              if (details != null && least.isNotEmpty) ...[
                _header('Launched least', text),
                for (final r in least) _row(r, details[r.app.key], synced),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _header(String title, TextTheme text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(title, style: text.titleMedium),
  );

  Widget _row(RareApp r, PlatformAppDetails? d, bool synced) {
    final system = d?.system ?? false;
    final info = [
      if (r.here > 0) r.here == 1 ? '1 launch' : '${r.here} launches',
      if (synced && r.launches > r.here) '${r.launches - r.here} on other phones',
      if (d != null && !system) 'installed ${_ago(d.installed)}',
      if (system) 'system app',
      if (r.app.otherProfile) 'work profile',
      if (_c.isHidden(r.app)) 'hidden',
    ];
    return ListTile(
      key: ValueKey('rare-${r.app.key}'),
      leading: AppIcon(app: r.app, cache: widget.icons, size: 36),
      title: Text(r.app.label),
      subtitle: info.isEmpty ? null : Text(_capitalize(info.join(', '))),
      onTap: () => _c.source.appInfo(r.app),
      trailing: system
          ? null
          : IconButton(
              key: ValueKey('rare-uninstall-${r.app.key}'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Uninstall ${r.app.label}',
              onPressed: () => _c.source.uninstall(r.app),
            ),
    );
  }

  static String _ago(DateTime t) {
    final days = DateTime.now().difference(t).inDays;
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      < 60 => '$days days ago',
      < 730 => '${days ~/ 30} months ago',
      _ => '${days ~/ 365} years ago',
    };
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
