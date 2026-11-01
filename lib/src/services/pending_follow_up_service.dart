import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Installation-local offers, scoped by SDK app and user. No widget or billing
/// closure is persisted. All presentation decisions are revalidated by the SDK.
class PendingFollowUpService {
  PendingFollowUpService(this.preferences, this.key);
  final SharedPreferences preferences;
  final String key;

  Map<String, dynamic> _read() {
    try {
      final value = jsonDecode(preferences.getString(key) ?? '{}');
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, dynamic> data) async {
    if (!await preferences.setString(key, jsonEncode(data))) {
      throw StateError('Pending follow-up persistence failed');
    }
  }

  List<Map<String, dynamic>> get jobs => (_read()['jobs'] as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .toList();

  Future<void> enqueue(Map<String, dynamic> job) async {
    final data = _read();
    final list = jobs;
    // Keep the first qualifying event: repeated dismissals do not reset its clock.
    final existing = list.indexWhere((item) => item['id'] == job['id']);
    if (existing >= 0) {
      if (list[existing]['policy'] == job['policy']) return;
      list.removeAt(
        existing,
      ); // A new event under an edited policy starts a new offer.
    }
    if (list.length >= 50) list.removeAt(0);
    list.add(job);
    data['jobs'] = list;
    await _write(data);
  }

  Future<void> remove(String id) async {
    final data = _read();
    data['jobs'] = jobs.where((job) => job['id'] != id).toList();
    await _write(data);
  }

  Future<void> cancelPurchasedOffers() async {
    final data = _read();
    data['jobs'] = jobs
        .where((job) => (job['rule'] as Map?)?['cancelOnPurchase'] == false)
        .toList();
    await _write(data);
  }

  bool allowed(
    String id,
    Map<String, dynamic> rule,
    int session,
    DateTime now,
  ) {
    final usage = (_read()['usage'] as Map?)?[id];
    if (usage is! Map) return true;
    if (rule['oncePerSession'] != false && usage['session'] == session) {
      return false;
    }
    final at = DateTime.tryParse(usage['at']?.toString() ?? '');
    final cooldown = (rule['cooldownMs'] as num?)?.toInt() ?? 0;
    if (at != null && now.difference(at).inMilliseconds < cooldown) {
      return false;
    }
    final day = now.toUtc().toIso8601String().substring(0, 10);
    return usage['day'] != day ||
        (usage['count'] as num? ?? 0) < (rule['maxShowsPerDay'] as num? ?? 1);
  }

  Future<void> shown(String id, int session, DateTime now) async {
    final data = _read();
    final usage = Map<String, dynamic>.from(data['usage'] as Map? ?? {});
    final old = usage[id] as Map?;
    final day = now.toUtc().toIso8601String().substring(0, 10);
    usage[id] = {
      'session': session,
      'at': now.toUtc().toIso8601String(),
      'day': day,
      'count': old?['day'] == day
          ? ((old?['count'] as num?)?.toInt() ?? 0) + 1
          : 1,
    };
    // Bound policy history as configurations change.
    while (usage.length > 200) {
      usage.remove(usage.keys.first);
    }
    data['usage'] = usage;
    data['jobs'] = jobs.where((job) => job['id'] != id).toList();
    await _write(data);
  }
}
