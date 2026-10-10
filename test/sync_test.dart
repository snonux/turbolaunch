import 'dart:convert';

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
  int puts = 0;

  void _check() {
    if (down) throw Exception('connection refused');
  }

  @override
  Future<void> putObject(String key, List<int> bytes, {String contentType = ''}) async {
    puts++;
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
    bool autoArrange = false,
    DateTime Function()? clock,
  }) async {
    // Each instance keeps its own cache, so phones do not see each other's prefs.
    SharedPreferences.setMockInitialValues({});
    final store = LauncherStore(await SharedPreferences.getInstance());
    await store.setCounts(counts);
    await store.setSlots(slots);
    await store.setSyncConfig(config);
    await store.setSettings(const LauncherSettings().copyWith(autoArrange: autoArrange));
    final source = FakeAppSource(apps);
    final c = LauncherController(source, store, s3Client: (_) => bucket, clock: clock);
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
    int cols = 3,
    bool autoArrange = false,
    DateTime Function()? clock,
  }) async {
    final p = await Phone.start(
      bucket,
      apps,
      counts: counts,
      slots: slots,
      rows: rows,
      cols: cols,
      autoArrange: autoArrange,
      clock: clock,
    );
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

  test('arranged by launches, phones rank by the summed counts and show a ghost in its rank', () async {
    final mail = app('mail'), maps = app('maps'), chat = app('chat'), bank = app('bank');
    final a = await phone(
      [mail, maps, chat],
      counts: {mail.key: 5, maps.key: 1},
      slots: {const Cell(2, 0): maps.key},
      autoArrange: true,
    );
    // B lacks maps and has bank, which A lacks; its user serial differs too.
    final b = await phone([app('mail', serial: 10), chat, bank], counts: {chat.key: 4, bank.key: 3}, autoArrange: true);
    expect(a.grid, {const Cell(2, 2): 'mail', const Cell(2, 1): 'maps'});
    await syncAll();
    // Totals: mail 5, chat 4, bank 3, maps 1.
    expect(a.grid, {const Cell(2, 2): 'mail', const Cell(2, 1): 'chat', const Cell(1, 2): 'maps'});
    expect(a.c.ghosts, {const Cell(2, 0): 'bank'});
    expect(b.grid, {const Cell(2, 2): 'mail', const Cell(2, 1): 'chat', const Cell(2, 0): 'bank'});
    expect(b.c.ghosts, {const Cell(1, 2): 'maps'});
    // Installed, maps takes its ghost's cell.
    b.source.apps = [app('mail', serial: 10), chat, bank, maps];
    await pumpEventQueue();
    expect(b.grid[const Cell(1, 2)], 'maps');
    expect(b.c.ghosts, isEmpty);
  });

  test('arranged by launches, a sync with the home in front waits for it to be left', () async {
    final mail = app('mail'), chat = app('chat');
    final a = await phone([mail, chat], counts: {mail.key: 2}, autoArrange: true);
    final b = await phone([mail, chat], counts: {chat.key: 9}, autoArrange: true);
    await b.c.syncNow();
    a.c.setInFront(true);
    await a.c.syncNow();
    expect(a.grid, {const Cell(2, 2): 'mail'});
    a.c.setInFront(false);
    expect(a.grid, {const Cell(2, 2): 'chat', const Cell(2, 1): 'mail'});
  });

  test('arranged by launches, with the home in front an app that goes leaves its ghost and comes back to it', () async {
    final mail = app('mail'), chat = app('chat');
    await phone([mail, chat], counts: {mail.key: 5, chat.key: 3}, autoArrange: true);
    final b = await phone([mail, chat], autoArrange: true);
    await syncAll();
    expect(b.grid, {const Cell(2, 2): 'mail', const Cell(2, 1): 'chat'});
    b.c.setInFront(true);
    b.source.apps = [chat];
    await pumpEventQueue();
    expect(b.grid, {const Cell(2, 1): 'chat'});
    expect(b.c.ghosts, {const Cell(2, 2): 'mail'});
    b.source.apps = [mail, chat];
    await pumpEventQueue();
    expect(b.grid, {const Cell(2, 2): 'mail', const Cell(2, 1): 'chat'});
    expect(b.c.ghosts, isEmpty);
  });

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
    // C has no maps: its cell shows a ghost of maps, so the grids match.
    expect(c.grid[const Cell(2, 1)], 'chat');
    expect(c.grid[const Cell(2, 0)], isNull);
    expect(c.c.ghosts, {const Cell(2, 0): 'maps'});
    // Apps that lost their cell got another one.
    expect(a.grid.containsValue('mail'), isTrue);
    expect(c.grid.values, containsAll(['mail', 'news', 'bank']));
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
    // B takes over A's grid: mail goes where A has it, chat's cell shows its
    // ghost, and maps gets the next free cell.
    expect(b.grid, {const Cell(2, 1): 'mail', const Cell(2, 2): 'maps'});
    expect(b.c.ghosts, {const Cell(2, 0): 'chat'});
  });

  test('a cell kept for an app the phone lacks shows its ghost until it is installed', () async {
    final mail = app('mail'), chat = app('chat'), news = app('news');
    final a = await phone([mail, chat], counts: {chat.key: 9, mail.key: 5});
    final b = await phone([mail, news]);
    await syncAll();
    expect(b.grid, {const Cell(2, 1): 'mail'});
    expect(b.c.ghosts, {const Cell(2, 0): 'chat'});
    // News, launched after the sync, leaves chat's ghost alone.
    await b.c.launch(news);
    expect(b.grid, {const Cell(2, 1): 'mail', const Cell(2, 2): 'news'});
    expect(b.c.ghosts, {const Cell(2, 0): 'chat'});
    // B's file claims no cell for the ghost, so A could still move on.
    await b.c.syncNow();
    final file = DeviceSync.decode(utf8.decode(bucket.objects['$kSyncPrefix${b.store.deviceId}.json']!))!;
    expect(file.cells.values, isNot(contains('org.chat/org.chat.Main')));
    expect(file.labels, {'org.mail/org.mail.Main': 'mail', 'org.news/org.news.Main': 'news'});

    b.source.apps = [mail, news, chat];
    await pumpEventQueue();
    expect(b.grid, {const Cell(2, 0): 'chat', const Cell(2, 1): 'mail', const Cell(2, 2): 'news'});
    expect(b.c.ghosts, isEmpty);
    expect(a.c.ghosts, isEmpty);
  });

  test('a cell lent out before ghosts turns into a ghost', () async {
    final mail = app('mail'), chat = app('chat'), news = app('news');
    await phone([mail, chat], counts: {chat.key: 9, mail.key: 5});
    final b = await phone([mail, news], counts: {news.key: 1});
    await syncAll();
    // What an older version left: news borrowing chat's cell.
    await b.store.setSlots({const Cell(2, 0): news.key, const Cell(2, 1): mail.key});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('syncLent', '{"2,0": "org.chat/org.chat.Main"}');
    final c = LauncherController(b.source, b.store, s3Client: (_) => bucket);
    addTearDown(c.dispose);
    await c.refresh();
    c.setAutoGridSize(3, 3);
    expect(c.ghosts, {const Cell(2, 0): 'chat'});
    expect(c.grid.map((cell, a) => MapEntry(cell, a.label)), {const Cell(2, 1): 'mail', const Cell(2, 2): 'news'});
    expect(b.store.legacyLent, isEmpty);
    expect(b.store.lent, isEmpty);
  });

  test('a local app borrows a ghost cell only when no other cell is free', () async {
    final mail = app('mail'), chat = app('chat'), news = app('news');
    await phone([mail, chat], counts: {chat.key: 9, mail.key: 5}, rows: 1, cols: 2);
    final b = await phone([mail, news], rows: 1, cols: 2);
    await syncAll();
    expect(b.grid, {const Cell(0, 1): 'mail'});
    expect(b.c.ghosts, {const Cell(0, 0): 'chat'});
    // News has too few launches for a cell of its own: it takes the ghost's.
    await b.c.launch(news);
    expect(b.grid, {const Cell(0, 0): 'news', const Cell(0, 1): 'mail'});
    expect(b.c.ghosts, isEmpty);
    expect(b.store.lent, {const Cell(0, 0): 'org.chat/org.chat.Main'});
    expect(b.c.borrowed, {const Cell(0, 0)});
    // Installing chat gives the cell back.
    b.source.apps = [mail, news, chat];
    await pumpEventQueue();
    expect(b.grid, {const Cell(0, 0): 'chat', const Cell(0, 1): 'mail'});
    expect(b.store.lent, isEmpty);
  });

  test('a ghost is named by the busiest phone, or from its key in old files', () {
    final x = DeviceSync(device: 'x', counts: const {'a': 1}, labels: const {'org.maps/org.maps.Main': 'Old Maps'});
    final y = DeviceSync(device: 'y', counts: const {'a': 9}, labels: const {'org.maps/org.maps.Main': 'Maps'});
    expect(ghostLabel([x, y], 'org.maps/org.maps.Main'), 'Maps');
    expect(ghostLabel([x], 'org.chat/org.chat.Main#work'), 'chat');
    expect(ghostLabel([y], 'pair:org.maps/org.maps.Main|org.chat/org.chat.Main'), 'Maps | chat');
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

  test('automatic syncs: only on Home or coming back, at most hourly, failures retried an hour later', () async {
    var now = DateTime.utc(2026, 10, 10, 12);
    final mail = app('mail');
    final a = await phone([mail], clock: () => now);
    Future<void> settle() => pumpEventQueue();
    await settle();
    expect(bucket.puts, 0, reason: 'nothing syncs at the start');
    await a.c.launch(mail);
    await settle();
    expect(bucket.puts, 0, reason: 'nor after a launch');
    a.source.pressHome();
    await settle();
    expect(bucket.puts, 1);
    now = now.add(const Duration(minutes: 59));
    a.source.pressHome();
    await settle();
    expect(bucket.puts, 1, reason: 'at most once an hour');
    now = now.add(const Duration(minutes: 2));
    bucket.down = true;
    a.source.pressHome();
    await settle();
    expect(bucket.puts, 2, reason: 'an hour later it tries again, and fails');
    bucket.down = false;
    now = now.add(const Duration(minutes: 30));
    a.source.pressHome();
    await settle();
    expect(bucket.puts, 2, reason: 'a failed sync waits an hour too');
    // Coming back to the home screen counts as using it; the first time it
    // shows, at the start, does not.
    now = now.add(const Duration(minutes: 31));
    a.c.setInFront(true);
    await settle();
    expect(bucket.puts, 2);
    a.c.setInFront(false);
    a.c.setInFront(true);
    await settle();
    expect(bucket.puts, 3);
    // Sync now always syncs.
    await a.c.syncNow();
    expect(bucket.puts, 4);
  });

  test('the last attempt outlives a restart, so a restart does not sync early', () async {
    var now = DateTime.utc(2026, 10, 10, 12);
    final mail = app('mail');
    final a = await phone([mail], clock: () => now);
    a.source.pressHome();
    await pumpEventQueue();
    expect(bucket.puts, 1);
    final again = LauncherController(a.source, a.store, s3Client: (_) => bucket, clock: () => now);
    addTearDown(again.dispose);
    await again.refresh();
    again.setAutoGridSize(3, 3);
    now = now.add(const Duration(minutes: 10));
    a.source.pressHome();
    await pumpEventQueue();
    expect(bucket.puts, 1);
  });

  test('a week without a sync asks to check it', () async {
    var now = DateTime.utc(2026, 10, 10, 12);
    final a = await phone([app('mail')], clock: () => now);
    a.c.updateSyncConfig(const SyncConfig());
    a.c.updateSyncConfig(config);
    expect(a.c.syncOverdue, isFalse);
    now = now.add(const Duration(days: 8));
    expect(a.c.syncOverdue, isTrue, reason: 'switched on a week ago and never synced');
    await a.c.syncNow();
    expect(a.c.syncOverdue, isFalse);
    now = now.add(const Duration(days: 6));
    bucket.down = true;
    a.source.pressHome();
    await pumpEventQueue();
    expect(a.c.syncOverdue, isFalse);
    now = now.add(const Duration(days: 2));
    expect(a.c.syncOverdue, isTrue, reason: 'the last sync that worked is over a week old');
    a.c.updateSyncConfig(const SyncConfig());
    expect(a.c.syncOverdue, isFalse, reason: 'not with sync off');
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
    final d = DeviceSync(
      device: 'abc',
      name: 'Pixel',
      counts: const {'a/b': 3},
      cells: {const Cell(0, 1): 'a/b'},
      labels: const {'a/b': 'App'},
    );
    final back = DeviceSync.decode(d.encode())!;
    expect(back.labels, {'a/b': 'App'});
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
