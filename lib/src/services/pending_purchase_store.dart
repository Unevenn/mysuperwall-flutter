import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Correlates deferred store completions with actual in-app purchase attempts.
/// No receipts/tokens are stored, and restoring old ownership creates no intent.
class PendingPurchaseStore {
  PendingPurchaseStore(this.preferences);

  static const Duration _clockTolerance = Duration(hours: 12);
  static const Duration _sameCheckoutWindow = Duration(minutes: 5);

  final SharedPreferences preferences;
  Future<void> _operations = Future<void>.value();

  String _key(String scope) =>
      'mysuperwall_pending_purchases_${base64Url.encode(utf8.encode(scope))}';

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Map<String, dynamic> _read(String scope) {
    final raw = preferences.getString(_key(scope));
    if (raw == null) return {};
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Starting over only loses open attempts. Failing here would stop
      // purchase tracking on this device for good.
    }
    return {};
  }

  Future<void> _write(String scope, Map<String, dynamic> journal) async {
    if (!await preferences.setString(_key(scope), jsonEncode(journal))) {
      throw StateError('Purchase journal could not be persisted');
    }
  }

  Future<void> begin(
    String scope,
    String productId,
    Map<String, dynamic> context,
  ) => _serial(() async {
    final journal = _read(scope);
    final pending = Map<String, dynamic>.from(journal['pending'] as Map? ?? {});
    pending[productId.split(':').first] = {
      'eventId': 'intent_${const Uuid().v4()}',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'context': context,
    };
    journal['pending'] = pending;
    await _write(scope, journal);
  });

  Future<void> cancel(String scope, String productId) => _serial(() async {
    final journal = _read(scope);
    final pending = Map<String, dynamic>.from(journal['pending'] as Map? ?? {});
    pending.remove(productId.split(':').first);
    journal['pending'] = pending;
    await _write(scope, journal);
  });

  Future<bool> complete({
    required String scope,
    required String productId,
    required DateTime purchasedAt,
    required String? transactionEventId,
    required bool onlyIfPending,
    required Future<bool> Function(
      String eventId,
      Map<String, dynamic>? context,
    )
    record,
  }) => _serial(() async {
    final journal = _read(scope);
    final pending = Map<String, dynamic>.from(journal['pending'] as Map? ?? {});
    final intent = pending[productId.split(':').first];
    final now = DateTime.now().toUtc();
    if (onlyIfPending && intent is! Map) return false;
    // purchasedAt comes from the store and "now" from the device, whose clock can
    // be wrong. These checks only tell old ownership from a new purchase, so a
    // skewed clock must not reject a real one.
    if (intent is Map) {
      final started = DateTime.tryParse(intent['startedAt']?.toString() ?? '');
      if (started == null || now.difference(started) > const Duration(days: 30)) {
        return false;
      }
      // A direct billing result proves the checkout. An update does not, and
      // could be ownership from before this attempt.
      if (onlyIfPending && purchasedAt.isBefore(started.subtract(_clockTolerance))) {
        return false;
      }
    } else if (purchasedAt.isBefore(now.subtract(_clockTolerance))) {
      return false;
    }
    final eventId =
        transactionEventId ??
        (intent is Map ? intent['eventId']?.toString() : null) ??
        'intent_${const Uuid().v4()}';
    final completed = (journal['completed'] as List? ?? [])
        .whereType<String>()
        .toList();
    if (completed.contains(eventId)) return false;
    final product = productId.split(':').first;
    final recent = Map<String, dynamic>.from(journal['recent'] as Map? ?? {});
    final lastCompleted = recent[product];
    // An update can consume the attempt just before the billing result returns,
    // and the two can name one purchase with different transaction IDs.
    if (intent is! Map &&
        lastCompleted is int &&
        now.millisecondsSinceEpoch - lastCompleted <
            _sameCheckoutWindow.inMilliseconds) {
      return false;
    }
    final savedContext = intent is Map ? intent['context'] : null;
    final context = savedContext is Map<String, dynamic> ? savedContext : null;
    if (!await record(eventId, context)) return false;
    // The event is already durable; a crash before this journal write is safe
    // because replay keeps the same store transaction/event identity.
    pending.remove(product);
    completed.add(eventId);
    recent[product] = now.millisecondsSinceEpoch;
    journal['recent'] = recent;
    journal['pending'] = pending;
    journal['completed'] = completed.length > 256
        ? completed.sublist(completed.length - 256)
        : completed;
    await _write(scope, journal);
    return true;
  });
}
