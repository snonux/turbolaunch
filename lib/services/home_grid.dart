/// The home grid's placement rules, as pure functions over plain data.
///
/// By default the grid is arranged by launches ([arrangeHome]): the
/// most-launched app sits bottom right, the next one to its left, and so on
/// up the rows. The rest of this applies when that is turned off.
///
/// A cell is a (row, column) pair. Once an app has a cell it keeps it: only
/// uninstalling the app, removing it by long-press, or shrinking the grid
/// below its cell frees it. Free cells go to the most-launched apps without a
/// cell, filled from the bottom row up (nearest the search box and the thumb),
/// left to right. With sync, an app goes to the cell it has on the other
/// phones when that cell is free, and a cell kept for an app this phone lacks
/// shows a ghost of that app, so the grid looks the same on every phone. Only
/// when no other cell is free does a local app borrow a ghost's cell, until
/// the ghost's app is installed.
library;

class Cell implements Comparable<Cell> {
  const Cell(this.row, this.col);

  final int row;
  final int col;

  /// The stored form, `row,col`.
  @override
  String toString() => '$row,$col';

  static Cell? parse(String s) {
    final parts = s.split(',');
    if (parts.length != 2) return null;
    final r = int.tryParse(parts[0]), c = int.tryParse(parts[1]);
    if (r == null || c == null || r < 0 || c < 0) return null;
    return Cell(r, c);
  }

  @override
  bool operator ==(Object other) => other is Cell && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  int compareTo(Cell other) => row != other.row ? row.compareTo(other.row) : col.compareTo(other.col);
}

/// Cells of a [rows] x [cols] grid in fill order: bottom row first.
List<Cell> fillOrder(int rows, int cols) => [
  for (var r = rows - 1; r >= 0; r--)
    for (var c = 0; c < cols; c++) Cell(r, c),
];

/// Cells of a [rows] x [cols] grid in rank order: bottom right first, then
/// leftwards, then the row above.
List<Cell> rankOrder(int rows, int cols) => [
  for (var r = rows - 1; r >= 0; r--)
    for (var c = cols - 1; c >= 0; c--) Cell(r, c),
];

/// The grid arranged by launches: apps from [installed] with a count above
/// zero, most-launched first, take the cells in [rankOrder]. Ties go by
/// [tieKey] (the sync key, so every phone agrees). Apps that are in
/// [excluded] get no cell.
///
/// [missing] are apps the other phones show that are not installed here,
/// with their launch counts: they are ranked like the others, and their cells
/// are returned in `ghosts` (cell to app) instead of `slots`, so the grid
/// looks the same on every phone.
///
/// An app in [slots] (the current placement) with no launches, put there by
/// "Add to home", keeps a cell after the ranked apps.
({Map<Cell, String> slots, Map<Cell, String> ghosts}) arrangeHome({
  required int rows,
  required int cols,
  required Set<String> installed,
  required Map<String, int> counts,
  Set<String> excluded = const {},
  Map<Cell, String> slots = const {},
  Map<String, int> missing = const {},
  String Function(String key)? tieKey,
}) {
  int count(String k) => installed.contains(k) ? counts[k] ?? 0 : missing[k] ?? 0;
  final tie = tieKey ?? (k) => k;
  final ranked =
      <String>[
        ...installed.where((k) => !excluded.contains(k) && (counts[k] ?? 0) > 0),
        ...missing.keys.where((k) => !installed.contains(k) && !excluded.contains(k) && (missing[k] ?? 0) > 0),
      ]..sort((a, b) {
        final byCount = count(b).compareTo(count(a));
        return byCount != 0 ? byCount : tie(a).compareTo(tie(b));
      });
  final order = rankOrder(rows, cols);
  final position = {for (var i = 0; i < order.length; i++) order[i]: i};
  final added =
      slots.entries
          .where(
            (e) =>
                position.containsKey(e.key) &&
                installed.contains(e.value) &&
                !excluded.contains(e.value) &&
                (counts[e.value] ?? 0) <= 0,
          )
          .toList()
        ..sort((a, b) => position[a.key]!.compareTo(position[b.key]!));
  final keys = <String>{...ranked, for (final e in added) e.value}.toList();
  final result = <Cell, String>{}, ghosts = <Cell, String>{};
  for (var i = 0; i < keys.length && i < order.length; i++) {
    (installed.contains(keys[i]) ? result : ghosts)[order[i]] = keys[i];
  }
  return (slots: result, ghosts: ghosts);
}

/// Returns the new placement; see [placeHome].
Map<Cell, String> placeApps({
  required Map<Cell, String> slots,
  required int rows,
  required int cols,
  required Set<String> installed,
  required Map<String, int> counts,
  Set<String> excluded = const {},
}) => placeHome(slots: slots, rows: rows, cols: cols, installed: installed, counts: counts, excluded: excluded).slots;

/// Returns the new placement, the cells lent out and the ghost cells.
///
/// [slots] is the current placement (cell to app key). Placements whose app is
/// not in [installed], is in [excluded] (hidden, or removed from the grid by
/// the user), or whose cell lies outside the grid are dropped. Then free cells
/// are filled with apps from [installed] that have a launch count above zero,
/// most-launched first, ties broken by key so every phone agrees.
///
/// [shared] is where the other phones have their apps (see sync.dart). An
/// unplaced app goes to its shared cell when that is free; other apps skip
/// cells kept for such an app. A free cell whose shared app is not installed
/// here stays empty and is returned in `ghosts` (cell to owner), for the grid
/// to draw a ghost of that app; once the owner is installed it takes the cell.
/// Only apps left over when every other cell is taken borrow ghost cells, in
/// fill order; those are returned in `lent` (cell to owner). [lent] is that
/// from the last pass: once the owner is installed, it takes its cell back
/// and the borrower is placed again like any app.
({Map<Cell, String> slots, Map<Cell, String> lent, Map<Cell, String> ghosts}) placeHome({
  required Map<Cell, String> slots,
  required int rows,
  required int cols,
  required Set<String> installed,
  required Map<String, int> counts,
  Set<String> excluded = const {},
  Map<Cell, String> shared = const {},
  Map<Cell, String> lent = const {},
}) {
  bool inGrid(Cell c) => c.row < rows && c.col < cols;
  final result = <Cell, String>{};
  for (final e in slots.entries) {
    final c = e.key;
    if (!inGrid(c)) continue;
    if (!installed.contains(e.value) || excluded.contains(e.value)) continue;
    if (result.containsValue(e.value)) continue;
    result[c] = e.value;
  }
  final stillLent = <Cell, String>{};
  for (final e in lent.entries) {
    final cell = e.key, owner = e.value;
    // The other phones moved on: the borrower keeps the cell as its own.
    if (!inGrid(cell) || shared[cell] != owner) continue;
    if (!installed.contains(owner)) {
      if (result.containsKey(cell)) stillLent[cell] = owner;
    } else if (!excluded.contains(owner) && !result.containsValue(owner)) {
      result[cell] = owner;
    }
  }
  final ghosts = <Cell, String>{
    for (final e in shared.entries)
      if (inGrid(e.key) && !result.containsKey(e.key) && !installed.contains(e.value)) e.key: e.value,
  };
  final placed = result.values.toSet();
  final candidates =
      installed.where((k) => !placed.contains(k) && !excluded.contains(k) && (counts[k] ?? 0) > 0).toList()
        ..sort((a, b) {
          final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
          return byCount != 0 ? byCount : a.compareTo(b);
        });
  final waiting = candidates.toSet();
  final kept = <String, Cell>{
    for (final e in shared.entries)
      if (inGrid(e.key) && !result.containsKey(e.key) && waiting.contains(e.value)) e.value: e.key,
  };
  final keptCells = kept.values.toSet();
  final order = fillOrder(rows, cols);
  final ghostOrder = [
    for (final c in order)
      if (ghosts.containsKey(c)) c,
  ];
  var next = 0, nextGhost = 0;
  for (final key in candidates) {
    final own = kept[key];
    if (own != null) {
      result[own] = key;
      continue;
    }
    while (next < order.length &&
        (result.containsKey(order[next]) || keptCells.contains(order[next]) || ghosts.containsKey(order[next]))) {
      next++;
    }
    if (next < order.length) {
      result[order[next++]] = key;
    } else if (nextGhost < ghostOrder.length) {
      final cell = ghostOrder[nextGhost++];
      stillLent[cell] = ghosts.remove(cell)!;
      result[cell] = key;
    } else if (kept.isEmpty) {
      break;
    }
  }
  return (slots: result, lent: stillLent, ghosts: ghosts);
}

/// Places [key] in the first free cell in fill order that is not in [skip],
/// if there is one.
Map<Cell, String> pinApp(Map<Cell, String> slots, String key, int rows, int cols, {Set<Cell> skip = const {}}) {
  if (slots.containsValue(key)) return slots;
  for (final cell in fillOrder(rows, cols)) {
    if (!slots.containsKey(cell) && !skip.contains(cell)) return {...slots, cell: key};
  }
  return slots;
}

/// The automatic grid size for an area of [width] x [height] logical pixels:
/// about one column per 80 dp and one row per 96 dp, rows growing with the
/// label font scale so bigger labels get roomier cells.
({int rows, int cols}) autoGridSize(double width, double height, {double labelScale = 1.0}) {
  final cols = (width / 80).floor().clamp(1, 12);
  final rows = (height / (96 + 16 * (labelScale - 1))).floor().clamp(1, 12);
  return (rows: rows, cols: cols);
}
