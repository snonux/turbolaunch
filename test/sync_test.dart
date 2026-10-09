import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/home_grid.dart';
import 'package:turbolaunch/services/launcher_controller.dart';
import 'package:turbolaunch/services/launcher_store.dart';
import 'package:turbolaunch/services/s3_config.dart';
import 'package:turbolaunch/services/s3_object_client.dart';
import 'package:turbolaunch/services/settings_backup.dart';
import 'package:turbolaunch/services/sync.dart';
import 'package:turbolaunch/screens/sync_screen.dart';

/// A bucket in memory.
class MemoryBucket implements S3ObjectClient {
  final objects = <String, List<int>>{};
  bool down = false;

  void _check() {
    if (down) throw Exception('connection refused');
  }

  @override
  Future<void> putObject(String key, List<int> bytes, {String contentType = ''}) async {
    _check();
    objects[key] = bytes;
  }

  @override
  Future<List<int>> getObject(String key) async {
    _check();
    return objects[key] ?? (throw S3MissingObjectError(key));
  }

  @override
  Future<void> deleteObject(String key) async {
    _check();
    objects.remove(key);
  }

  @override
  Future<List<String>> listKeys({String prefix = ''}) async {
    _check();
    return [
      for (final k in objects.keys)
        if (k.startsWith(prefix)) k,
    ];
  }
}

AppEntry app(String name, {int serial = 0, bool work = false}) =>
    AppEntry(key: 'org.$name/org.$name.Main#$serial', label: name, otherProfile: work);

const config = SyncConfig(enabled: true, accessKeyId: 'id', secretAccessKey: 'secret');

/// One phone: its own apps, its own SharedPreferences, the shared bucket.
class Phone {
  Phone._(this.source, this.store, this.c);

  final FakeAppSource source;
  final LauncherStore store;
  final LauncherController c;

  static Future<Phone> start(
    MemoryBucket bucket,
    List<AppEntry> apps, {
    Map<String, int> counts = const {},
    Map<Cell, String> slots = const {},
    int rows = 3,
    int cols = 3,
  }) async {
    // Each instance keeps its own cache, so phones do not see each other's prefs.
    SharedPreferences.setMockInitialValues({});
    final store = LauncherStore(await SharedPreferences.getInstance());
    await store.setCounts(counts);
    await store.setSlots(slots);
    await store.setSyncConfig(config);
    final source = FakeAppSource(apps);
    final c = LauncherController(source, store, s3Client: (_) => bucket);
    await c.refresh();
    c.setAutoGridSize(rows, cols);
    return Phone._(source, store, c);
  }

  /// The grid as app names.
  Map<Cell, String> get grid => c.grid.map((cell, a) => MapEntry(cell, a.label));
}

void main() {
  late MemoryBucket bucket;
  final phones = <Phone>[];

  Future<Phone> phone(
    List<AppEntry> apps, {
    Map<String, int> counts = const {},
    Map<Cell, String> slots = const {},
    int rows = 3,
  }) async {
    final p = await Phone.start(bucket, apps, counts: counts, slots: slots, rows: rows);
    phones.add(p);
    return p;
  }

  setUp(() => bucket = MemoryBucket());
  tearDown(() {
    for (final p in phones) {
      p.c.dispose();
    }
    phones.clear();
  });

  Future<void> syncAll() async {
    for (final p in phones) {
      await p.c.syncNow();
    }
    for (final p in phones) {
      await p.c.syncNow();
    }
  }

  test('three phones with settled grids take over the grid of the busiest one', () async {
    final mail = app('mail'), maps = app('maps'), chat = app('chat'), news = app('news'), bank = app('bank');
    // Bottom row is row 2 on a 3-row grid. B has the most launches (70).
    final a = await phone(
      [mail, maps, chat, news],
      counts: {mail.key: 50, maps.key: 10},
      slots: {const Cell(2, 0): mail.key, const Cell(2, 1): maps.key},
    );
    final b = await phone(
      [mail, maps, chat, bank],
      counts: {maps.key: 40, chat.key: 30},
      slots: {const Cell(2, 0): maps.key, const Cell(2, 1): chat.key},
    );
    final c = await phone(
      [mail, chat, news, bank],
      counts: {news.key: 20, bank.key: 5},
      slots: {const Cell(2, 0): news.key, const Cell(2, 1): bank.key},
    );

    await syncAll();

    // B keeps its grid, A takes it over.
    expect(b.grid[const Cell(2, 0)], 'maps');
    expect(b.grid[const Cell(2, 1)], 'chat');
    expect(a.grid[const Cell(2, 0)], 'maps');
    expect(a.grid[const Cell(2, 1)], 'chat');
    // C has no maps: its cell is lent to C's most-launched app without a cell.
    expect(c.grid[const Cell(2, 1)], 'chat');
    expect(c.grid[const Cell(2, 0)], 'mail');
    expect(c.store.lent, {const Cell(2, 0): 'org.maps/org.maps.Main'});
    // Apps that lost their cell got another one.
    expect(a.grid.containsValue('mail'), isTrue);
    expect(c.grid.values, containsAll(['news', 'bank']));
    // Counts are summed: maps 10 + 40 on phone A.
    expect(a.c.totals[maps.key], 50);
    expect(a.c.counts[maps.key], 10);
    expect(c.c.totals[mail.key], 50);

    // Only the first sync takes over a grid: from now on icons stay put,
    // even when another phone becomes the busiest.
    final before = [a.grid, b.grid, c.grid];
    for (var i = 0; i < 200; i++) {
      await c.c.launch(bank);
    }
    await syncAll();
    for (final (i, p) in phones.indexed) {
      for (final e in before[i].entries) {
        expect(p.grid[e.key], e.value, reason: 'phone $i cell ${e.key}');
      }
    }
  });

  test('an app new to a phone takes the cell it has on the other phones', () async {
    final mail = app('mail'), maps = app('maps'), chat = app('chat');
    final a = await phone([mail, maps, chat], counts: {mail.key: 5, chat.key: 9});
    expect(a.grid, {const Cell(2, 0): 'chat', const Cell(2, 1): 'mail'});
    // B already uses its bottom left for maps, and has no chat.
    final b = await phone([mail, maps], counts: {maps.key: 1}, slots: {const Cell(2, 0): maps.key});
    await syncAll();
    // Mail goes where A has it, not to the next free cell in fill order.
    expect(b.grid, {const Cell(2, 0): 'maps', const Cell(2, 1): 'mail'});
  });

  test('a cell kept for an app the phone lacks is lent, and returned when it is installed', () async {
    final mail = app('mail'), chat = app('chat'), news = app('news');
    await phone([mail, chat], counts: {chat.key: 9, mail.key: 5});
    final b = await phone([mail, news]);
    await syncAll();
    expect(b.grid, {const Cell(2, 1): 'mail'});
    // News, launched after the sync, borrows chat's cell (bottom left).
    await b.c.launch(news);
    expect(b.grid, {const Cell(2, 0): 'news', const Cell(2, 1): 'mail'});
    expect(b.store.lent, {const Cell(2, 0): 'org.chat/org.chat.Main'});

    b.source.apps = [mail, news, chat];
    await pumpEventQueue();
    expect(b.grid[const Cell(2, 0)], 'chat');
    expect(b.grid[const Cell(2, 1)], 'mail');
    expect(b.grid.containsValue('news'), isTrue);
    expect(b.store.lent, isEmpty);
  });

  test('cells are matched from the bottom row on phones with more rows', () async {
    final mail = app('mail');
    await phone([mail], counts: {mail.key: 3}, rows: 3);
    final tall = await phone([mail], rows: 5);
    await syncAll();
    expect(tall.grid, {const Cell(4, 0): 'mail'});
  });

  test('work profile apps match across phones whatever their user serial', () async {
    final work = app('mail', serial: 10, work: true);
    await phone([work], counts: {work.key: 7});
    final other = app('mail', serial: 11, work: true);
    final b = await phone([other]);
    await syncAll();
    expect(b.c.totals[other.key], 7);
  });

  test('a failed automatic sync is silent; Sync now says why', () async {
    final mail = app('mail');
    final a = await phone([mail], counts: {mail.key: 1});
    bucket.down = true;
    await a.c.sync();
    expect(a.c.lastSync, isNull);
    await expectLater(a.c.syncNow(), throwsA(isA<SyncException>()));
    bucket.down = false;
    await a.c.syncNow();
    expect(a.c.lastSync, isNotNull);
  });

  test('Sync now without keys asks for them', () async {
    final a = await phone([app('mail')]);
    a.c.updateSyncConfig(const SyncConfig(enabled: true));
    await expectLater(
      a.c.syncNow(),
      throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('access key'))),
    );
  });

  test('each phone writes only its own file', () async {
    final mail = app('mail');
    final a = await phone([mail], counts: {mail.key: 2});
    final b = await phone([mail], counts: {mail.key: 3});
    await syncAll();
    expect(bucket.objects.keys.toSet(), {
      '$kSyncPrefix${a.store.deviceId}.json',
      '$kSyncPrefix${b.store.deviceId}.json',
    });
    expect(a.c.totals[mail.key], 5);
    expect(b.c.totals[mail.key], 5);
  });

  test('a device file round-trips and junk is ignored', () {
    final d = DeviceSync(device: 'abc', name: 'Pixel', counts: const {'a/b': 3}, cells: {const Cell(0, 1): 'a/b'});
    final back = DeviceSync.decode(d.encode())!;
    expect(back.device, 'abc');
    expect(back.counts, {'a/b': 3});
    expect(back.cells, {const Cell(0, 1): 'a/b'});
    expect(DeviceSync.decode('{"format":"other"}'), isNull);
    expect(DeviceSync.decode('nope'), isNull);
  });

  test('phones that disagree about a cell follow the busiest phone', () {
    // y has more launches, so its cells win.
    final x = DeviceSync(device: 'x', counts: const {'a': 5}, cells: {const Cell(0, 0): 'a'});
    final y = DeviceSync(device: 'y', counts: const {'b': 9}, cells: {const Cell(0, 0): 'b', const Cell(0, 1): 'a'});
    expect(sharedCells([x, y], 2), {const Cell(1, 0): 'b', const Cell(1, 1): 'a'});
    expect(sharedCells([y, x], 2), {const Cell(1, 0): 'b', const Cell(1, 1): 'a'});
  });

  test('the export carries the sync settings but never the device id', () async {
    final a = await phone([app('mail')]);
    a.store.deviceId;
    final text = encodeSettingsBackup(LauncherBackup.fromStore(a.store), exportedAt: DateTime(2026));
    expect(text, contains('"secretAccessKey": "secret"'));
    expect(text, contains('"containsSecrets": true'));
    expect(text, isNot(contains(a.store.deviceId)));
    final back = decodeSettingsBackup(text);
    expect(back.sync?.accessKeyId, 'id');
    expect(S3Config.fromRaw().bucket, 'turbolaunch');
  });

  testWidgets('the sync screen saves the keys and Sync now reports the other phones', (tester) async {
    final mail = app('mail');
    await bucket.putObject(
      '${kSyncPrefix}other.json',
      DeviceSync(device: 'other', name: 'Tablet', counts: {'org.mail/org.mail.Main': 4}).encode().codeUnits,
    );
    late Phone a;
    await tester.runAsync(() async => a = await phone([mail]));
    a.c.updateSyncConfig(const SyncConfig());
    await tester.pumpWidget(MaterialApp(home: SyncScreen(controller: a.c)));
    await tester.tap(find.byKey(const Key('sync-enabled')));
    await tester.enterText(find.byKey(const Key('sync-key-id')), 'id');
    await tester.enterText(find.byKey(const Key('sync-secret')), 'secret');
    await tester.pump();
    expect(a.store.syncConfig.secretAccessKey, 'secret');
    await tester.scrollUntilVisible(find.byKey(const Key('sync-now')), 100, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sync-now')));
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Tablet'), 100, scrollable: find.byType(Scrollable).first);
    expect(find.text('Synced with 1 other phone.'), findsOneWidget);
    expect(find.text('Tablet'), findsOneWidget);
    expect(a.c.totals[mail.key], 4);
  });
}
