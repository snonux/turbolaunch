/// A saved app pair: two apps opened side by side in split screen. A pair is
/// an app of its own on the home screen and in search, keyed by its two apps
/// so the same pair has the same key on every phone.
class AppPair {
  const AppPair({required this.name, required this.first, required this.second});

  static const keyPrefix = 'pair:';

  final String name;

  /// App keys: [first] opens on top (or left), [second] below it.
  final String first;
  final String second;

  String get key => '$keyPrefix$first|$second';

  static bool isPairKey(String key) => key.startsWith(keyPrefix);

  Map<String, Object> toJson() => {'name': name, 'first': first, 'second': second};

  /// Null when [j] is not a well-formed pair.
  static AppPair? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], first = j['first'], second = j['second'];
    if (name is! String || first is! String || second is! String) return null;
    if (first.isEmpty || second.isEmpty || first == second) return null;
    return AppPair(name: name, first: first, second: second);
  }

  @override
  bool operator ==(Object other) =>
      other is AppPair && other.name == name && other.first == first && other.second == second;

  @override
  int get hashCode => Object.hash(name, first, second);
}
