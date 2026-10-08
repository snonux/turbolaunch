import 'package:flutter_test/flutter_test.dart';
import 'package:turbolaunch/services/home_grid.dart';

void main() {
  test('cells round-trip and reject garbage', () {
    expect(Cell.parse(const Cell(3, 1).toString()), const Cell(3, 1));
    expect(Cell.parse('x'), isNull);
    expect(Cell.parse('1,-2'), isNull);
  });

  test('fills from the bottom row up, most-launched first', () {
    final slots = placeApps(
      slots: {},
      rows: 2,
      cols: 2,
      installed: {'a', 'b', 'c', 'd', 'never'},
      counts: {'a': 1, 'b': 9, 'c': 5, 'd': 5},
    );
    expect(slots, {const Cell(1, 0): 'b', const Cell(1, 1): 'c', const Cell(0, 0): 'd', const Cell(0, 1): 'a'});
  });

  test('apps never launched get no cell', () {
    expect(placeApps(slots: {}, rows: 2, cols: 2, installed: {'x'}, counts: {}), isEmpty);
  });

  test('a placed app keeps its cell when another overtakes it', () {
    var slots = placeApps(slots: {}, rows: 1, cols: 1, installed: {'a', 'b'}, counts: {'a': 2});
    expect(slots, {const Cell(0, 0): 'a'});
    slots = placeApps(slots: slots, rows: 1, cols: 1, installed: {'a', 'b'}, counts: {'a': 2, 'b': 100});
    expect(slots, {const Cell(0, 0): 'a'});
  });

  test('uninstalling or excluding an app frees its cell for the next one', () {
    final start = {const Cell(0, 0): 'a', const Cell(0, 1): 'b'};
    final counts = {'a': 5, 'b': 4, 'c': 3};
    expect(placeApps(slots: start, rows: 1, cols: 2, installed: {'b', 'c'}, counts: counts), {
      const Cell(0, 0): 'c',
      const Cell(0, 1): 'b',
    });
    expect(placeApps(slots: start, rows: 1, cols: 2, installed: {'a', 'b', 'c'}, counts: counts, excluded: {'b'}), {
      const Cell(0, 0): 'a',
      const Cell(0, 1): 'c',
    });
  });

  test('shrinking drops only the cut-off cells, the rest stay put', () {
    final start = {const Cell(0, 0): 'a', const Cell(0, 3): 'b', const Cell(2, 1): 'c'};
    final out = placeApps(slots: start, rows: 2, cols: 3, installed: {'a', 'b', 'c'}, counts: {});
    expect(out, {const Cell(0, 0): 'a'});
  });

  test('pinning takes the first free cell in fill order', () {
    final slots = pinApp({const Cell(1, 0): 'a'}, 'z', 2, 2);
    expect(slots[const Cell(1, 1)], 'z');
    expect(pinApp(slots, 'z', 2, 2), same(slots));
  });

  test('auto grid size follows the area and the label scale', () {
    expect(autoGridSize(400, 600), (rows: 6, cols: 5));
    expect(autoGridSize(400, 600, labelScale: 1.6).rows, lessThan(6));
    expect(autoGridSize(10, 10), (rows: 1, cols: 1));
  });
}
