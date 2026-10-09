import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:turbolaunch/services/app_source.dart';
import 'package:turbolaunch/services/launcher_controller.dart';
import 'package:turbolaunch/services/launcher_store.dart';

/// A regression limit for search: a phone with 300 apps and 150 shortcuts,
/// every keystroke of a few queries. The host is faster than a phone and
/// shares its CPU with other jobs, so the limit is loose; a slip back to
/// per-keystroke folding or string allocation in the scorer passes it.
void main() {
  test('search stays fast with 300 apps and 150 shortcuts', () async {
    const words = ['Maps', 'Notes', 'Music', 'Camera', 'Clock', 'Signal', 'Files', 'Photo', 'Mail', 'Organic'];
    final apps = [
      for (var i = 0; i < 300; i++)
        AppEntry(
          key: 'org.example.app$i/org.example.app$i.Main#0',
          label: '${words[i % 10]} ${words[(i * 7) % 10]} $i',
        ),
    ];
    final shortcuts = [
      for (var i = 0; i < 150; i++)
        ShortcutEntry(packageName: 'org.example.app$i', id: 's$i', userSerial: 0, label: 'New ${words[i % 10]} entry'),
    ];
    SharedPreferences.setMockInitialValues({});
    final c = LauncherController(FakeAppSource(apps, shortcuts: shortcuts), await LauncherStore.open());
    await c.refresh();

    final times = <int>[];
    for (var round = 0; round < 3; round++) {
      for (final q in ['orgmaps', 'sgnl', 'new note', 'clk', 'xyzzy', 'cam']) {
        for (var n = 1; n <= q.length; n++) {
          final watch = Stopwatch()..start();
          c.query = q.substring(0, n);
          c.results;
          times.add(watch.elapsedMicroseconds);
        }
        c.query = '';
      }
    }
    times.sort();
    final median = times[times.length ~/ 2];
    // ignore: avoid_print
    print('search keystroke, 450 entries: median $median us, max ${times.last} us');
    expect(median, lessThan(5000));
    c.dispose();
  });
}
