// Three phones syncing through a real S3 bucket. Runs only when the bucket's
// keys are in the environment, as in CI's e2e job:
//
//   S3_TEST_ACCESS_KEY_ID=... S3_TEST_SECRET_KEY=... flutter test test/s3_live_test.dart
//
// S3_TEST_ENDPOINT and S3_TEST_BUCKET default to Paul's Garage test bucket.
// Each run writes under a prefix of its own and deletes it afterwards.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/home_grid.dart';
import 'package:turbolaunch/services/launcher_controller.dart';
import 'package:turbolaunch/services/launcher_store.dart';
import 'package:turbolaunch/services/s3_object_client.dart';
import 'package:turbolaunch/services/sync.dart';

void main() {
  final env = Platform.environment;
  final keyId = env['S3_TEST_ACCESS_KEY_ID'] ?? '';
  final secret = env['S3_TEST_SECRET_KEY'] ?? '';
  final config = SyncConfig(
    enabled: true,
    endpoint: env['S3_TEST_ENDPOINT'] ?? 'https://garage.f3s.buetow.org',
    region: 'garage',
    bucket: env['S3_TEST_BUCKET'] ?? 'turbolaunch-test',
    accessKeyId: keyId,
    secretAccessKey: secret,
  );
  final prefix = 'e2e-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}/devices/';
  final controllers = <LauncherController>[];

  AppEntry app(String name) => AppEntry(key: 'org.$name/org.$name.Main#0', label: name);

  Future<LauncherController> phone(
    String name,
    List<AppEntry> apps,
    Map<String, int> counts,
    Map<Cell, String> slots,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = LauncherStore(await SharedPreferences.getInstance());
    await store.setCounts(counts);
    await store.setSlots(slots);
    await store.setSyncConfig(config.copyWith(deviceName: name));
    final c = LauncherController(FakeAppSource(apps), store, syncPrefix: prefix);
    await c.refresh();
    c.setAutoGridSize(4, 4);
    controllers.add(c);
    return c;
  }

  tearDownAll(() async {
    for (final c in controllers) {
      c.dispose();
    }
    if (!config.s3.hasCredentials) return;
    final client = MinioS3ObjectClient(config.s3);
    for (final key in await client.listKeys(prefix: prefix)) {
      await client.deleteObject(key);
    }
  });

  test('three phones sync through the bucket', () async {
    final mail = app('mail'), maps = app('maps'), chat = app('chat');
    final a = await phone('A', [mail, maps, chat], {mail.key: 3}, {const Cell(3, 0): mail.key});
    final b = await phone('B', [mail, maps], {maps.key: 9}, {const Cell(3, 0): maps.key});
    final c = await phone('C', [mail, chat], {chat.key: 1}, {const Cell(3, 0): chat.key});
    for (var round = 0; round < 2; round++) {
      for (final p in [a, b, c]) {
        await p.syncNow();
      }
    }
    expect(a.otherPhones.map((d) => d.label).toSet(), {'B', 'C'});
    expect(a.totals, {mail.key: 3, maps.key: 9, chat.key: 1});
    // B has the most launches: A takes over its grid, C shows a ghost of maps.
    expect(a.grid[const Cell(3, 0)]?.label, 'maps');
    expect(b.grid[const Cell(3, 0)]?.label, 'maps');
    expect(c.grid[const Cell(3, 0)], isNull);
    expect(c.ghosts[const Cell(3, 0)], 'maps');
    expect(c.grid.values.map((e) => e.label), contains('mail'));
    final client = MinioS3ObjectClient(config.s3);
    expect(await client.listKeys(prefix: prefix), hasLength(3));
  }, skip: keyId.isEmpty || secret.isEmpty ? 'S3_TEST_ACCESS_KEY_ID and S3_TEST_SECRET_KEY are not set' : false);
}
