import 'dart:convert';

import '../models/paywall_result.dart';

/// Session-only decisions explicitly authorized for reuse by the backend.
/// Disk/prefetch-active content alone never authorizes a presentation.
class PaywallDecisionCache {
  final Stopwatch _clock = Stopwatch()..start();
  final List<_DecisionEntry> _entries = [];
  int _generation = 0;

  int get generation => _generation;
  int get elapsedMilliseconds => _clock.elapsedMilliseconds;

  PaywallResult? lookup(String triggerKey, Map<String, dynamic> context) {
    final now = elapsedMilliseconds;
    for (final entry in _entries.reversed) {
      if (entry.triggerKey == triggerKey &&
          now < entry.expiresAt &&
          entry.signature == _signature(entry.fields, context)) {
        return entry.result;
      }
    }
    return null;
  }

  void remember({
    required String triggerKey,
    required Map<String, dynamic> context,
    required Object? policy,
    required PaywallResult result,
    required int requestStartedAt,
  }) {
    // A successful new decision supersedes every previous decision for this
    // trigger, including positives when the server now says not to display.
    _entries.removeWhere((entry) => entry.triggerKey == triggerKey);
    if (!result.show || result.paywall == null || policy is! Map) return;
    final age = policy['maxAgeMs'];
    final rawFields = policy['varyBy'];
    if (policy['version'] != 1 ||
        age is! int ||
        age <= 0 ||
        rawFields is! List ||
        rawFields.any((field) => field is! String)) {
      return;
    }
    final fields = rawFields.cast<String>();
    // Identity and region must always vary, even for a malformed server policy.
    if (!fields.toSet().containsAll([
      'userId',
      'platform',
      'appVersion',
      'country',
    ])) {
      return;
    }
    final maxAge = age > 30000 ? 30000 : age;
    final expiresAt = requestStartedAt + maxAge;
    if (expiresAt <= elapsedMilliseconds) return;
    _entries.add(
      _DecisionEntry(
        triggerKey: triggerKey,
        fields: List.unmodifiable(fields),
        signature: _signature(fields, context),
        result: result,
        expiresAt: expiresAt,
      ),
    );
    if (_entries.length > 32) _entries.removeAt(0);
  }

  void clear() {
    _generation++;
    _entries.clear();
  }

  static String _signature(List<String> fields, Map<String, dynamic> context) =>
      jsonEncode([
        for (final field in fields) _canonical(_resolve(context, field)),
      ]);

  // Match backend ruleEngine.resolveContextValue without evaluating/reassigning
  // audiences locally: the cached decision remains the server's selection.
  static Object? _resolve(Map<String, dynamic> context, String field) {
    if (context.containsKey(field)) return ['value', context[field]];
    if (field.contains('.')) {
      Object? value = context;
      for (final part in field.split('.')) {
        if (value == null) return ['missing'];
        // For array/primitive property access, vary on the whole ancestor
        // rather than approximating JavaScript indexing/coercion semantics.
        if (value is! Map) return ['ancestor', value];
        if (!value.containsKey(part)) return ['missing'];
        value = value[part];
      }
      return ['value', value];
    }
    for (final key in ['metadata', 'userAttributes']) {
      final value = context[key];
      if (value is Map && value.containsKey(field))
        return ['value', value[field]];
    }
    // Backend numeric comparisons distinguish absent fields from explicit
    // JSON null, so the signature must preserve presence as well as value.
    return ['missing'];
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}

class _DecisionEntry {
  const _DecisionEntry({
    required this.triggerKey,
    required this.fields,
    required this.signature,
    required this.result,
    required this.expiresAt,
  });

  final String triggerKey;
  final List<String> fields;
  final String signature;
  final PaywallResult result;
  final int expiresAt;
}
