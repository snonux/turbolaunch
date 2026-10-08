/// fzf-style matching: the query's letters must appear in the text in order,
/// gaps allowed, so "gmps" finds "Google Maps". Case and accents are ignored.
library;

/// A match of a query in a text: a score (higher is better) and the indexes
/// of the matched characters in the original text, for highlighting.
class FuzzyMatch {
  const FuzzyMatch(this.score, this.positions);

  final int score;
  final List<int> positions;
}

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'a', //
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i', //
  'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', //
  'ö': 'o', 'ø': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', //
  'ÿ': 'y', 'ß': 's', 'ł': 'l', 'ś': 's', 'ź': 'z', 'ż': 'z', 'č': 'c', //
  'ř': 'r', 'š': 's', 'ž': 'z', 'ě': 'e', 'ů': 'u', 'ő': 'o', 'ű': 'u', //
};

/// Lower case without accents, one output character per input code unit, so
/// match positions map straight back onto the original string.
String foldForSearch(String s) {
  // Plain ASCII, the common case, needs no table.
  var ascii = true;
  for (final u in s.codeUnits) {
    if (u > 0x7f) {
      ascii = false;
      break;
    }
  }
  if (ascii) return s.toLowerCase();
  final out = StringBuffer();
  for (final unit in s.split('')) {
    // Lower-casing can lengthen a character ('İ'); keep its first unit only.
    final lower = unit.toLowerCase();
    final one = lower.isEmpty ? unit : lower[0];
    out.write(_accents[one] ?? one);
  }
  return out.toString();
}

bool _isWordStart(String text, int i) {
  if (i == 0) return true;
  final p = text.codeUnitAt(i - 1), u = text.codeUnitAt(i);
  // ASCII letters and digits, the common case, without building strings.
  if (p < 0x80 && u < 0x80) {
    final pLower = p >= 0x61 && p <= 0x7a, pUpper = p >= 0x41 && p <= 0x5a, pDigit = p >= 0x30 && p <= 0x39;
    if (pLower || pUpper || pDigit) return pLower && u >= 0x41 && u <= 0x5a;
  }
  final prev = text[i - 1];
  final cur = text[i];
  if (' -_./:·&+'.contains(prev)) return true;
  // camelCase and digits after letters start a word too.
  final prevLower = prev.toLowerCase() == prev && prev.toUpperCase() != prev;
  final curUpper = cur.toUpperCase() == cur && cur.toLowerCase() != cur;
  return prevLower && curUpper;
}

const _matchScore = 16;
const _wordStartBonus = 24;
const _consecutiveBonus = 20;
const _firstCharBonus = 16;
const _gapPenalty = 2;

/// Scores [query] against [text], or returns null when the letters do not all
/// appear in order. Spaces in the query are ignored.
///
/// For each query letter the scorer prefers, in order: a word start, the
/// position right after the previous match, the earliest occurrence. That is
/// a greedy pass, not fzf's full optimum, but it is predictable and fast
/// enough for a few hundred apps on every keystroke.
///
/// Callers matching one query against many texts pass [foldedQuery] and
/// [foldedText] (from [foldForSearch]) so neither is folded again each time.
FuzzyMatch? fuzzyMatch(String query, String text, {String? foldedQuery, String? foldedText}) {
  final q = (foldedQuery ?? foldForSearch(query)).replaceAll(' ', '');
  if (q.isEmpty) return const FuzzyMatch(0, []);
  final t = foldedText ?? foldForSearch(text);
  if (t.length < q.length) return null;

  // Quick reject: every letter must exist in order.
  var probe = 0;
  for (var i = 0; i < t.length && probe < q.length; i++) {
    if (t.codeUnitAt(i) == q.codeUnitAt(probe)) probe++;
  }
  if (probe < q.length) return null;

  final positions = <int>[];
  var score = 0;
  var from = 0;
  for (var qi = 0; qi < q.length; qi++) {
    final c = q.codeUnitAt(qi);
    final remaining = q.length - qi - 1;
    int? best;
    var bestScore = -1 << 30;
    for (var i = from; i < t.length; i++) {
      if (t.codeUnitAt(i) != c) continue;
      // The rest of the query must still fit after i.
      if (!_fits(q, qi + 1, t, i + 1)) break;
      var s = 0;
      if (_isWordStart(text, i)) s += _wordStartBonus;
      if (positions.isNotEmpty && positions.last == i - 1) s += _consecutiveBonus;
      s -= (i - from) * _gapPenalty;
      if (s > bestScore) {
        bestScore = s;
        best = i;
      }
      if (remaining == 0 && s >= _wordStartBonus) break;
    }
    if (best == null) return null;
    score += _matchScore + bestScore;
    if (best == 0) score += _firstCharBonus;
    positions.add(best);
    from = best + 1;
  }
  // Shorter texts win ties: "Maps" before "Maps Offline Helper".
  score -= t.length - q.length;
  return FuzzyMatch(score, positions);
}

bool _fits(String q, int qi, String t, int ti) {
  for (var i = ti; i < t.length && qi < q.length; i++) {
    if (t.codeUnitAt(i) == q.codeUnitAt(qi)) qi++;
  }
  return qi >= q.length;
}
