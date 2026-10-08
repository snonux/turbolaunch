import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/fuzzy.dart';

int? score(String q, String t) => fuzzyMatch(q, t)?.score;

void main() {
  test('letters in order with gaps match', () {
    expect(fuzzyMatch('gmps', 'Google Maps')?.positions, [0, 7, 9, 10]);
    expect(fuzzyMatch('gmps', 'Maps Google'), isNull);
    expect(fuzzyMatch('xyz', 'Maps'), isNull);
  });

  test('case, accents and spaces in the query are ignored', () {
    expect(fuzzyMatch('CAFE', 'Café Finder'), isNotNull);
    expect(fuzzyMatch('cafe', 'CAFÉ')?.positions, [0, 1, 2, 3]);
    expect(fuzzyMatch('o m', 'Organic Maps')?.positions, [0, 8]);
  });

  test('positions map onto the original text even when lower case is longer', () {
    final m = fuzzyMatch('ist', 'İstanbul Transit')!;
    expect(m.positions.first, 0);
  });

  test('an empty query matches everything with score 0', () {
    expect(fuzzyMatch('', 'Anything')?.score, 0);
  });

  test('word starts beat letters inside words', () {
    // "om" is O(rganic) M(aps) at word starts, against "om" inside "Rooms".
    expect(score('om', 'Organic Maps')!, greaterThan(score('om', 'Rooms')!));
    expect(fuzzyMatch('om', 'Organic Maps')!.positions, [0, 8]);
  });

  test('prefix and consecutive letters beat scattered ones', () {
    expect(score('mus', 'Music')!, greaterThan(score('mus', 'Maps Utility Suite')!));
    expect(score('cal', 'Calendar')!, greaterThan(score('cal', 'Local')!));
  });

  test('shorter texts win otherwise equal matches', () {
    expect(score('maps', 'Maps')!, greaterThan(score('maps', 'Maps Offline Helper')!));
  });

  test('camelCase starts a word', () {
    expect(fuzzyMatch('as', 'AntennaPod Sync')!.positions, [0, 11]);
    expect(fuzzyMatch('ap', 'AntennaPod')!.positions, [0, 7]);
  });
}
