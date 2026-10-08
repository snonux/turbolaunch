import 'dart:io';

import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/app_source.dart';
import 'services/launcher_controller.dart';
import 'services/launcher_store.dart';
import 'services/startup_timer.dart';
import 'widgets/app_icon.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The Linux desktop build is the dev loop: a fake app list instead of Android's.
  final AppSource source = Platform.isAndroid ? PlatformAppSource() : FakeAppSource.demo();
  final store = await LauncherStore.open();
  runApp(TurboLaunchApp(source: source, store: store));
  StartupTimer.measureAfterFirstFrame(source);
}

class TurboLaunchApp extends StatefulWidget {
  const TurboLaunchApp({super.key, required this.source, required this.store});

  final AppSource source;
  final LauncherStore store;

  @override
  State<TurboLaunchApp> createState() => _TurboLaunchAppState();
}

class _TurboLaunchAppState extends State<TurboLaunchApp> {
  late final controller = LauncherController(widget.source, widget.store);
  late final icons = IconCache(widget.source);

  @override
  void initState() {
    super.initState();
    widget.source.events.where((e) => e == AppSourceEvent.packagesChanged).listen((_) => icons.clear());
    controller.refresh();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(brightness: b, colorSchemeSeed: Colors.grey, useMaterial3: true);
    return MaterialApp(
      title: 'TurboLaunch',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeScreen(controller: controller, icons: icons),
    );
  }
}
