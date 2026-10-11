/// Launches per app per day, so only the launches of a rolling window count.
///
/// Each launch is kept as the day it happened (UTC, `YYYY-MM-DD`), counted
/// per app and day: `{app: {day: launches}}`. That is a launch's timestamp
/// rounded to the day, which is all a window counted in days needs, and it
/// keeps the stored data and the sync file small however often apps start.
/// ISO dates sort as strings, so a window is a plain string comparison.
library;

/// Launches by app, then by day.
typedef LaunchDays = Map<String, Map<String, int>>;

/// The launch window's default, in days.
const int kDefaultLaunchWindowDays = 30;

/// The windows settings offer; 0 counts every launch ever made.
const List<int> kLaunchWindowChoices = [7, 14, 30, 60, 90, 180, 365, 0];

/// The day of [t], `YYYY-MM-DD` in UTC, so every phone names a day alike.
String launchDay(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}';
}

/// The first day inside a window of [days] days that ends with [now]'s day;
/// the empty string, before every day, for a window of 0 (no window).
String windowStart(DateTime now, int days) =>
    days <= 0 ? '' : launchDay(now.toUtc().subtract(Duration(days: days - 1)));

/// "the last 30 days", or "all launches" for no window.
String describeWindow(int days) => switch (days) {
  <= 0 => 'all launches',
  1 => 'today',
  _ => 'the last $days days',
};

final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Launches per app from [start] on.
Map<String, int> windowCounts(LaunchDays days, String start) {
  final counts = <String, int>{};
  for (final app in days.entries) {
    var n = 0;
    for (final d in app.value.entries) {
      if (d.key.compareTo(start) >= 0) n += d.value;
    }
    if (n > 0) counts[app.key] = n;
  }
  return counts;
}

/// [days] without the days before [start]; the same map when nothing is older.
LaunchDays purgeBefore(LaunchDays days, String start) {
  if (start.isEmpty || !days.values.any((d) => d.keys.any((k) => k.compareTo(start) < 0))) return days;
  return {
    for (final app in days.entries)
      if (app.value.keys.any((k) => k.compareTo(start) >= 0))
        app.key: {
          for (final d in app.value.entries)
            if (d.key.compareTo(start) >= 0) d.key: d.value,
        },
  };
}

/// Launch counts without days, from before the window or from an old export:
/// they are taken as made on [day], so they age out of the window instead of
/// vanishing at once.
LaunchDays daysFromCounts(Map<String, int> counts, String day) => {
  for (final e in counts.entries)
    if (e.value > 0) e.key: {day: e.value},
};

/// Reads `{app: {day: launches}}`, skipping anything malformed; null when
/// [j] is not a map at all.
LaunchDays? parseLaunchDays(Object? j) {
  if (j is! Map) return null;
  return {
    for (final app in j.entries)
      if (app.key is String && app.value is Map)
        app.key as String: {
          for (final d in (app.value as Map).entries)
            if (d.key is String && _dayPattern.hasMatch(d.key as String) && d.value is int && (d.value as int) > 0)
              d.key as String: d.value as int,
        },
  }..removeWhere((_, d) => d.isEmpty);
}
