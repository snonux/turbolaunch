import 'package:flutter/material.dart';

import '../services/launcher_controller.dart';
import '../services/sync.dart';

/// Warns when the synced phones count launches over different windows;
/// nothing when they agree.
class WindowWarning extends StatelessWidget {
  const WindowWarning({super.key, required this.controller});

  final LauncherController controller;

  @override
  Widget build(BuildContext context) {
    final warning = windowWarning(controller.windowMismatches);
    if (warning == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.error;
    return ListTile(
      leading: Icon(Icons.warning_amber, color: color),
      title: Text(warning, style: TextStyle(color: color)),
    );
  }
}
