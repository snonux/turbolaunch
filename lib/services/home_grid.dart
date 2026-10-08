/// The home grid's placement rules, as pure functions over plain data.
///
/// A cell is a (row, column) pair. Once an app has a cell it keeps it: only
/// uninstalling the app, removing it by long-press, or shrinking the grid
/// below its cell frees it. Free cells go to the most-launched apps without a
/// cell, filled from the bottom row up (nearest the search box and the thumb),
/// left to right.
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

/// Returns the new placement.
///
/// [slots] is the current placement (cell to app key). Placements whose app is
/// not in [installed], is in [excluded] (hidden, or removed from the grid by
/// the user), or whose cell lies outside the grid are dropped. Then free cells
/// are filled with apps from [installed] that have a launch count above zero,
/// most-launched first, ties broken by key so every phone agrees.
Map<Cell, String> placeApps({
  required Map<Cell, String> slots,
  required int rows,
  required int cols,
  required Set<String> installed,
  required Map<String, int> counts,
  Set<String> excluded = const {},
}) {
  final result = <Cell, String>{};
  for (final e in slots.entries) {
    final c = e.key;
    if (c.row >= rows || c.col >= cols) continue;
    if (!installed.contains(e.value) || excluded.contains(e.value)) continue;
    if (result.containsValue(e.value)) continue;
    result[c] = e.value;
  }
  final placed = result.values.toSet();
  final candidates =
      installed.where((k) => !placed.contains(k) && !excluded.contains(k) && (counts[k] ?? 0) > 0).toList()
        ..sort((a, b) {
          final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
          return byCount != 0 ? byCount : a.compareTo(b);
        });
  var next = 0;
  for (final cell in fillOrder(rows, cols)) {
    if (next >= candidates.length) break;
    if (result.containsKey(cell)) continue;
    result[cell] = candidates[next++];
  }
  return result;
}

/// Places [key] in the first free cell in fill order, if there is one.
Map<Cell, String> pinApp(Map<Cell, String> slots, String key, int rows, int cols) {
  if (slots.containsValue(key)) return slots;
  for (final cell in fillOrder(rows, cols)) {
    if (!slots.containsKey(cell)) return {...slots, cell: key};
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
