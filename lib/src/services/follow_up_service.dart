import 'dart:async';

/// Session policy shared by trigger-based recovery and the legacy second screen.
class FollowUpService {
  final Map<String, DateTime> _used = {};
  final Set<Timer> _timers = {};
  final Set<String> _pending = {};
  int _generation = 0;

  void cancel() {
    _generation++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
  }

  void reset() {
    cancel();
    _used.clear();
  }

  bool schedule({
    required String key,
    required Map<String, dynamic> rule,
    required int depth,
    required bool premium,
    required Future<bool> Function() run,
    void Function(Object error)? onError,
  }) {
    int integer(String key, int fallback, int max) {
      final raw = rule[key];
      return (raw is num ? raw.toInt() : fallback).clamp(0, max).toInt();
    }

    if (rule['enabled'] != true ||
        (rule['actionType'] ?? 'trigger') != 'trigger' ||
        (rule['triggerKey']?.toString().trim().isEmpty ?? true) ||
        (rule['skipIfPremium'] == true && premium) ||
        depth >= integer('maxChainDepth', 2, 5).clamp(1, 5) ||
        _pending.contains(key)) {
      return false;
    }
    final now = DateTime.now();
    final previous = _used[key];
    if (previous != null &&
        (rule['oncePerSession'] != false ||
            now.difference(previous).inMilliseconds <
                integer('cooldownMs', 0, 86400000))) {
      return false;
    }
    _pending.add(key);
    final generation = _generation;
    late final Timer timer;
    timer = Timer(Duration(milliseconds: integer('delayMs', 0, 10000)), () async {
      _timers.remove(timer);
      try {
        // A cancelled, unmatched or failed attempt must not consume a session rule.
        if (generation == _generation &&
            await run() &&
            generation == _generation) {
          _used[key] = DateTime.now();
        }
      } catch (error) {
        onError?.call(error);
      } finally {
        if (generation == _generation) _pending.remove(key);
      }
    });
    _timers.add(timer);
    return true;
  }
}
