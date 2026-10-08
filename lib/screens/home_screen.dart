import 'package:flutter/material.dart';

import '../services/app_source.dart';
import '../services/launcher_controller.dart';
import '../widgets/app_icon.dart';
import 'settings_screen.dart';

/// The home screen: every app in a list over the wallpaper, and the search
/// box docked at the bottom within thumb reach.
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

  @override
  void initState() {
    super.initState();
    _c.addListener(_onController);
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
      _focus.unfocus();
      Navigator.of(context).popUntil((r) => r.isFirst);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    setState(() {});
  }

  Future<void> _launch(AppEntry app) async {
    _focus.unfocus();
    await _c.launch(app);
  }

  Future<void> _showMenu(AppEntry app) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(app.label, style: Theme.of(context).textTheme.titleMedium)),
            ListTile(
              key: const Key('menu-app-info'),
              leading: const Icon(Icons.info_outline),
              title: const Text('App info'),
              onTap: () => Navigator.pop(context, 'info'),
            ),
          ],
        ),
      ),
    );
    if (action == 'info') await _c.source.appInfo(app);
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
    final apps = _c.visible;
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
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Material(
                    // Only the panel is see-through; icons stay fully opaque.
                    color: scheme.surface.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: !_c.loaded
                        ? const SizedBox.shrink()
                        : apps.isEmpty
                        ? Center(child: Text(_c.query.isEmpty ? 'No apps' : 'No match'))
                        : ListView.builder(
                            key: const Key('app-list'),
                            controller: _scroll,
                            reverse: _c.query.isNotEmpty,
                            itemCount: apps.length,
                            itemBuilder: (context, i) => _AppTile(
                              app: apps[i],
                              icons: widget.icons,
                              onTap: () => _launch(apps[i]),
                              onLongPress: () => _showMenu(apps[i]),
                            ),
                          ),
                  ),
                ),
              ),
              Padding(
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
                          filled: true,
                          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      key: const Key('open-settings'),
                      tooltip: 'Settings',
                      onPressed: _openSettings,
                      icon: const Icon(Icons.tune),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.icons, required this.onTap, required this.onLongPress});

  final AppEntry app;
  final IconCache icons;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey(app.key),
      leading: AppIcon(app: app, cache: icons),
      title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: app.otherProfile ? const Icon(Icons.work_outline, size: 18) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
