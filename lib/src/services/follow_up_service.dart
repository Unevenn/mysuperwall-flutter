import 'dart:async';

/// Session policy shared by trigger-based recovery and the legacy second screen.
class FollowUpService {
  final Map<String, DateTime> _used = {};
  final Set<Timer> _timers = {};

  void cancel() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
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
    required Future<void> Function() run,
  }) {
    int integer(String key, int fallback, int max) {
      final raw = rule[key];
      return (raw is num ? raw.toInt() : fallback).clamp(0, max).toInt();
    }

    if (rule['enabled'] != true ||
        (rule['actionType'] ?? 'trigger') != 'trigger' ||
        (rule['triggerKey']?.toString().trim().isEmpty ?? true) ||
        (rule['skipIfPremium'] == true && premium) ||
        depth >= integer('maxChainDepth', 2, 5).clamp(1, 5)) {
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
    _used[key] = now;
    late final Timer timer;
    timer = Timer(Duration(milliseconds: integer('delayMs', 0, 10000)), () {
      _timers.remove(timer);
      // Recovery failure must not break the customer's current screen.
      unawaited(run().catchError((Object _) {}));
    });
    _timers.add(timer);
    return true;
  }
}
