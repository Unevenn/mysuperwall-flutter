import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Cumulative checkpoints let rules added later recover recent crossings.
/// The first checkpoint is a baseline; earlier crossings are never invented.
class LifecycleHistory {
  LifecycleHistory(this.preferences, this.key);

  final SharedPreferences preferences;
  final String key;

  List<_Checkpoint> _read() {
    try {
      final raw = jsonDecode(preferences.getString(key) ?? '[]');
      if (raw is! List) return [];
      final result = <_Checkpoint>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final at = DateTime.tryParse(item['at']?.toString() ?? '');
        final sessions = item['sessions'];
        final active = item['active'];
        if (at != null &&
            sessions is int &&
            sessions >= 0 &&
            active is int &&
            active >= 0) {
          result.add(
            _Checkpoint(at.toUtc(), sessions, active, item['open'] == true),
          );
        }
      }
      result.sort((a, b) => a.at.compareTo(b.at));
      for (var i = 1; i < result.length; i++) {
        if (result[i].sessions < result[i - 1].sessions ||
            result[i].active < result[i - 1].active) {
          return []; // Corrupt/clock-reordered history must not invent crossings.
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> record(
    DateTime now,
    int sessions,
    int active, {
    bool boundary = false,
  }) async {
    final entries = _read();
    final cutoff = now.subtract(const Duration(days: 30));
    // Keep the last checkpoint before the cutoff to recognize older crossings.
    while (entries.length > 1 && entries[1].at.isBefore(cutoff)) {
      entries.removeAt(0);
    }
    if (boundary ||
        entries.isEmpty ||
        entries.last.sessions != sessions ||
        entries.last.active != active) {
      final continues =
          !boundary && entries.isNotEmpty && entries.last.sessions == sessions;
      if (continues && entries.length > 1 && entries.last.open) {
        entries.removeLast();
      }
      entries.add(_Checkpoint(now.toUtc(), sessions, active, continues));
    }
    final saved = await preferences.setString(
      key,
      jsonEncode([
        for (final entry in entries)
          {
            'at': entry.at.toIso8601String(),
            'sessions': entry.sessions,
            'active': entry.active,
            'open': entry.open,
          },
      ]),
    );
    if (!saved) throw StateError('Lifecycle history could not be persisted');
  }

  DateTime? crossing({required bool session, required int threshold}) {
    final entries = _read();
    if (entries.isEmpty) return null;
    int value(_Checkpoint entry) => session ? entry.sessions : entry.active;
    if (value(entries.first) >= threshold) return null;
    var previous = entries.first;
    for (final entry in entries.skip(1)) {
      if (value(entry) >= threshold) {
        if (!session && entry.active > previous.active) {
          final fraction =
              (threshold - previous.active) / (entry.active - previous.active);
          return previous.at.add(
            Duration(
              microseconds:
                  (entry.at.difference(previous.at).inMicroseconds * fraction)
                      .round(),
            ),
          );
        }
        return entry.at;
      }
      previous = entry;
    }
    return null;
  }
}

class _Checkpoint {
  const _Checkpoint(this.at, this.sessions, this.active, this.open);
  final bool open;
  final DateTime at;
  final int sessions;
  final int active;
}
