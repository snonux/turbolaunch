import 'package:flutter/material.dart';

import '../services/launcher_controller.dart';
import '../widgets/app_icon.dart';

/// Launch counts per app, most-launched first, with each app's home cell, so
/// the grid's order explains itself. With sync, counts are every phone's.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.controller, required this.icons});

  final LauncherController controller;
  final IconCache icons;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stats = controller.stats;
        final total = stats.fold(0, (sum, s) => sum + s.launches);
        final here = stats.fold(0, (sum, s) => sum + s.here);
        final synced = controller.otherPhones.isNotEmpty;
        final rows = controller.rows;
        return Scaffold(
          appBar: AppBar(title: const Text('Launch stats')),
          body: stats.isEmpty
              ? const Center(child: Text('Nothing launched yet'))
              : ListView(
                  key: const Key('stats-list'),
                  children: [
                    ListTile(
                      key: const Key('stats-total'),
                      title: Text(
                        synced ? '$total launches on all phones, $here here' : '$total launches on this phone',
                      ),
                      subtitle: const Text(
                        'Free home cells go to the most-launched apps; a placed app keeps its cell.',
                      ),
                    ),
                    for (final s in stats)
                      ListTile(
                        key: ValueKey('stat-${s.app.key}'),
                        leading: AppIcon(app: s.app, cache: icons, size: 36),
                        title: Text(s.app.label),
                        // Rows count from the bottom, where the grid starts filling.
                        subtitle: Text(
                          [
                            s.cell == null
                                ? 'Not on home'
                                : 'Home row ${rows - s.cell!.row}, column ${s.cell!.col + 1}',
                            if (synced) '${s.here} here',
                          ].join(', '),
                        ),
                        trailing: Text('${s.launches}', style: Theme.of(context).textTheme.titleMedium),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
