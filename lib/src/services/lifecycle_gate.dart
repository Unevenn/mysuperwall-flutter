import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/paywall_manifest.dart';

/// Decides on the device whether a lifecycle trigger is worth a server request.
///
/// The server still authorizes every presentation. This only avoids asking when
/// the answer is already known, so most app opens need no network at all. Counts
/// are per installation; limits across devices or reinstalls come back as a
/// server rejection, which [recordRejected] remembers.
class LifecycleGate {
  LifecycleGate(this._prefs, this._storageKey);

  static const Duration defaultBackoff = Duration(hours: 24);

  final SharedPreferences _prefs;
  final String _storageKey;
  Map<String, dynamic>? _loaded;

  Map<String, dynamic> get _state {
    final loaded = _loaded;
    if (loaded != null) return loaded;
    Map<String, dynamic> state = {};
    try {
      final raw = _prefs.getString(_storageKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map<String, dynamic>) state = decoded;
    } catch (_) {
      // A damaged record only costs an extra request; the server still decides.
    }
    return _loaded = state;
  }

  Map<String, dynamic> _entry(String key) {
    final existing = _state[key];
    if (existing is Map<String, dynamic>) return existing;
    final created = <String, dynamic>{};
    _state[key] = created;
    return created;
  }

  int _int(Map<String, dynamic> entry, String field) =>
      (entry[field] as num?)?.toInt() ?? 0;

  List<int> _shownTimes(Map<String, dynamic> entry) =>
      (entry['times'] as List? ?? const []).whereType<num>().map((e) => e.toInt()).toList();

  /// Why this trigger cannot show now, or null when a server request is justified.
  String? blockReason(
    ManifestTrigger trigger, {
    required int sessions,
    required bool premium,
    required DateTime now,
  }) {
    final millis = now.millisecondsSinceEpoch;
    if (trigger.fromOpen > 1 && sessions < trigger.fromOpen) {
      return 'schedule_not_reached';
    }
    if (trigger.hideForPurchasers && premium) return 'purchased';
    final raw = _state[trigger.key];
    if (raw is! Map<String, dynamic>) return null;
    if (_int(raw, 'blockedUntil') > millis) return 'server_rejected';
    if (trigger.maxPerUser > 0 && _int(raw, 'shown') >= trigger.maxPerUser) {
      return 'max_per_user';
    }
    if (trigger.stopAfterDismissals > 0 &&
        _int(raw, 'dismissed') >= trigger.stopAfterDismissals) {
      return 'dismissals';
    }
    final times = _shownTimes(raw);
    if (trigger.maxPerPeriod > 0) {
      final start = millis - Duration(days: trigger.periodDays).inMilliseconds;
      if (times.where((t) => t >= start).length >= trigger.maxPerPeriod) {
        return 'max_per_period';
      }
    }
    if (trigger.minIntervalHours > 0 && times.isNotEmpty) {
      final next = times.last + Duration(hours: trigger.minIntervalHours).inMilliseconds;
      if (next > millis) return 'min_interval';
    }
    return null;
  }

  /// Time still to wait after the app became ready, or zero when due.
  Duration remainingDelay(ManifestTrigger trigger, DateTime readyAt, DateTime now) {
    final remaining = readyAt.add(Duration(seconds: trigger.delaySeconds)).difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> recordShown(String key, DateTime now) {
    final entry = _entry(key);
    entry['shown'] = _int(entry, 'shown') + 1;
    final times = _shownTimes(entry)..add(now.millisecondsSinceEpoch);
    // Period caps go up to 1000, but a bounded history is enough to stop requests.
    entry['times'] = times.length > 50 ? times.sublist(times.length - 50) : times;
    entry.remove('blockedUntil');
    return _save();
  }

  Future<void> recordDismissed(String key) {
    final entry = _entry(key);
    entry['dismissed'] = _int(entry, 'dismissed') + 1;
    return _save();
  }

  /// The server refused: do not ask again before [until], or for a day if unknown.
  Future<void> recordRejected(String key, DateTime now, {DateTime? until}) {
    final next = until != null && until.isAfter(now) ? until : now.add(defaultBackoff);
    _entry(key)['blockedUntil'] = next.millisecondsSinceEpoch;
    return _save();
  }

  Future<void> _save() async {
    await _prefs.setString(_storageKey, jsonEncode(_state));
  }
}
