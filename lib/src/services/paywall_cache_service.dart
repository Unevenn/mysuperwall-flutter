import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/paywall_result.dart';

class CachedPaywall {
  const CachedPaywall({required this.result, required this.savedAt});

  final PaywallResult result;
  final DateTime savedAt;
}

/// Stores paywalls separately for each app, customer and locale.
class PaywallCacheService {
  const PaywallCacheService(this.preferences);

  final SharedPreferences preferences;
  static const freshLifetime = Duration(minutes: 15);
  static const offlineLifetime = Duration(hours: 24);

  String _key(String scope, String trigger) =>
      'mysuperwall_cache_${base64Url.encode(utf8.encode(jsonEncode([scope, trigger])))}';

  Future<void> save(String scope, String trigger, PaywallResult result) async {
    await preferences.setString(
      _key(scope, trigger),
      jsonEncode({
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'result': result.toJson(),
      }),
    );
  }

  CachedPaywall? read(String scope, String trigger, {bool allowStale = false}) {
    final key = _key(scope, trigger);
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final savedAt = DateTime.tryParse(decoded['savedAt']?.toString() ?? '');
      final payload = decoded['result'];
      if (savedAt == null || payload is! Map<String, dynamic>) return null;
      final age = DateTime.now().toUtc().difference(savedAt.toUtc());
      final maxAge = allowStale ? offlineLifetime : freshLifetime;
      if (age.isNegative || age > maxAge) return null;
      return CachedPaywall(
        result: PaywallResult.fromJson(payload),
        savedAt: savedAt,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Map<String, PaywallResult> readAll(String scope, {bool allowStale = false}) {
    final results = <String, PaywallResult>{};
    for (final trigger in _triggers(scope)) {
      final cached = read(scope, trigger, allowStale: allowStale);
      if (cached != null) results[trigger] = cached.result;
    }
    return results;
  }

  Future<void> removeExcept(String scope, Set<String> retainedTriggers) async {
    for (final trigger in _triggers(scope)) {
      if (!retainedTriggers.contains(trigger)) {
        await preferences.remove(_key(scope, trigger));
      }
    }
  }

  Iterable<String> _triggers(String scope) sync* {
    const prefix = 'mysuperwall_cache_';
    for (final key in preferences.getKeys().toList(growable: false)) {
      if (!key.startsWith(prefix)) continue;
      try {
        final decoded = jsonDecode(
          utf8.decode(base64Url.decode(key.substring(prefix.length))),
        );
        if (decoded is List &&
            decoded.length == 2 &&
            decoded[0] == scope &&
            decoded[1] is String) {
          yield decoded[1] as String;
        }
      } on FormatException {
        continue;
      }
    }
  }
}
