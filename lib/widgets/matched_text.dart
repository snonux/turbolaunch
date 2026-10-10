import 'package:flutter/material.dart';

/// [text] on one line with the letters at [positions] in bold and the
/// primary colour, as search shows fuzzy matches.
class MatchedText extends StatelessWidget {
  const MatchedText(this.text, {super.key, required this.positions, required this.style});

  final String text;
  final List<int> positions;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final hit = style.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary);
    // One span per run of matched or unmatched letters, not per letter.
    final marked = positions.toSet();
    final spans = <TextSpan>[];
    for (var start = 0; start < text.length;) {
      final hitRun = marked.contains(start);
      var end = start + 1;
      while (end < text.length && marked.contains(end) == hitRun) {
        end++;
      }
      spans.add(TextSpan(text: text.substring(start, end), style: hitRun ? hit : style));
      start = end;
    }
    return Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
