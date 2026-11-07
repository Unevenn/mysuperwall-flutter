import 'sdk_logging.dart';
import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineEventQueue {
  OfflineEventQueue({
    required this.preferences,
    required this.httpClient,
    Logger? logger,
    this.flushInterval = const Duration(seconds: 15),
    this.maxBatchSize = 10,
  }) : _logger = logger ?? MySuperWallLogging.createLogger() {
    _loadQueueFromDisk();
    _startPeriodicFlush();
  }

  final SharedPreferences preferences;
  final http.Client httpClient;
  final Logger _logger;
  final Duration flushInterval;
  final int maxBatchSize;

  static const String _storageKey = 'mysuperwall_offline_events_queue';
  static const int _maxStoredEvents = 500;
  static const Set<String> _conversionTypes = {'purchase', 'purchase_success'};
  final List<Map<String, dynamic>> _queue = [];
  final Set<String> _directDeliveries = {};
  Timer? _timer;
  bool _isFlushing = false;
  bool _disposed = false;
  Future<void> _persistence = Future<void>.value();
  Map<String, String>? _connection;

  String _scope(Map<String, String> connection) => jsonEncode([
    connection['baseUrl'],
    connection['appKey'],
    connection['bundleId'],
    connection['packageName'],
  ]);

  bool _legacyMatches(
    Map<String, dynamic> event,
    Map<String, String> connection,
  ) {
    // Old unscoped rows need both an app identity and their original user.
    if (event['userId'] is! String || (event['userId'] as String).isEmpty) {
      return false;
    }
    bool hasMatch = false;
    for (final key in ['appKey', 'bundleId', 'packageName']) {
      final identity = event[key];
      if (identity is String && identity.isNotEmpty) {
        if (connection[key] != identity) return false;
        hasMatch = true;
      }
    }
    return hasMatch;
  }

  void _loadQueueFromDisk() {
    try {
      final raw = preferences.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final stored in decoded.whereType<Map<String, dynamic>>()) {
            final event = Map<String, dynamic>.from(stored);
            if (event['eventId'] is! String ||
                (event['eventId'] as String).isEmpty) {
              event['eventId'] = const Uuid().v4();
            }
            if (event['_queueScope'] == null) event['_legacyUnscoped'] = true;
            // A purchase gets another chance each launch: the server may accept
            // today what an earlier version refused.
            if (_conversionTypes.contains(event['type'])) {
              event.remove('_rejected');
            }
            _queue.add(event);
          }
          _trim();
          if (_queue.any((event) => event['_legacyUnscoped'] == true)) {
            _logger.w(
              '[MySuperWall] Legacy offline events without a confirmed app/user scope are retained locally until safely attributable.',
            );
          }
          unawaited(_saveQueueToDisk());
        }
      }
    } catch (e) {
      _logger.w('[MySuperWall] Failed to load offline events from disk: $e');
    }
  }

  Future<bool> _saveQueueToDisk() {
    // Serialize writes and take the snapshot when each write starts. An older
    // async setString can never finish after, and overwrite, a newer snapshot.
    final write = _persistence.then((_) async {
      try {
        if (_queue.isEmpty) {
          return await preferences.remove(_storageKey);
        } else {
          return await preferences.setString(_storageKey, jsonEncode(_queue));
        }
      } catch (e) {
        _logger.w('[MySuperWall] Failed to persist offline events to disk: $e');
        return false;
      }
    });
    _persistence = write.then<void>((_) {});
    return write;
  }

  void _startPeriodicFlush() {
    _timer?.cancel();
    _timer = Timer.periodic(flushInterval, (_) {
      if (_queue.isNotEmpty && !_isFlushing) {
        flush();
      }
    });
  }

  /// Enqueues an analytics event for fire-and-forget background sync.
  void enqueue(Map<String, dynamic> event) {
    if (_disposed) return;
    _add(event);
    unawaited(_saveQueueToDisk());
    if (_queue.length >= maxBatchSize && !_isFlushing) unawaited(flush());
  }

  void _add(Map<String, dynamic> event) {
    event = Map<String, dynamic>.from(event);
    event['eventId'] ??= const Uuid().v4();
    final connection = _connection;
    if (connection != null) event['_queueScope'] = _scope(connection);
    event['timestamp'] ??= DateTime.now().toUtc().toIso8601String();
    if (!_queue.any((stored) => stored['eventId'] == event['eventId'])) {
      _queue.add(event);
      _trim();
    }
  }

  /// Keeps storage bounded. Rejected rows go first, then the oldest analytics;
  /// purchases are never dropped.
  void _trim() {
    bool removeFirst(bool Function(Map<String, dynamic>) test) {
      final index = _queue.indexWhere(test);
      if (index < 0) return false;
      _queue.removeAt(index);
      return true;
    }

    bool droppable(Map<String, dynamic> event) =>
        !_conversionTypes.contains(event['type']) &&
        !_directDeliveries.contains(event['eventId']);
    while (_queue.length > _maxStoredEvents) {
      if (removeFirst((event) => droppable(event) && event['_rejected'] == true)) {
        continue;
      }
      if (!removeFirst(droppable)) return;
    }
  }

  /// Write-ahead delivery: no purchase HTTP request precedes this disk write.
  Future<bool> enqueuePersisted(Map<String, dynamic> event) async {
    if (_disposed) return false;
    final id = event['eventId'];
    if (id is! String || id.isEmpty) return false;
    _directDeliveries.add(id);
    _add(event);
    return _saveQueueToDisk();
  }

  Future<void> acknowledge(String eventId) async {
    if (_disposed) return;
    _queue.removeWhere((event) => event['eventId'] == eventId);
    await _saveQueueToDisk();
  }

  void releaseDirectDelivery(String eventId) {
    _directDeliveries.remove(eventId);
  }

  /// Flushes pending events to backend.
  Future<void> flush({
    String? baseUrl,
    String? appKey,
    String? bundleId,
    String? packageName,
    String? platform,
    String? appVersion,
    String? userId,
  }) async {
    if (_disposed) return;
    if (baseUrl != null && baseUrl.isNotEmpty) {
      // Explicit calls replace the entire connection; missing identifiers must
      // not inherit a previous app's identity. Timer calls use this snapshot.
      _connection = {
        'baseUrl': baseUrl,
        if (appKey != null && appKey.isNotEmpty) 'appKey': appKey,
        if (bundleId != null && bundleId.isNotEmpty) 'bundleId': bundleId,
        if (packageName != null && packageName.isNotEmpty)
          'packageName': packageName,
        if (platform != null) 'platform': platform,
        if (appVersion != null) 'appVersion': appVersion,
        if (userId != null) 'userId': userId,
      };
    }
    final connection = _connection;
    if (_isFlushing || _queue.isEmpty || connection == null) return;
    _isFlushing = true;

    try {
      final connectionScope = _scope(connection);
      for (final event in _queue) {
        if (event['_queueScope'] == null &&
            (event['_legacyUnscoped'] != true ||
                _legacyMatches(event, connection))) {
          event['_queueScope'] = connectionScope;
          event.remove('_legacyUnscoped');
        }
      }
      final batch = _queue
          .where(
            (event) =>
                event['_queueScope'] == connectionScope &&
                event['_rejected'] != true &&
                !_directDeliveries.contains(event['eventId']),
          )
          .take(maxBatchSize)
          .toList();
      if (batch.isEmpty) return;
      if (!await _saveQueueToDisk()) return;
      final uri = Uri.parse('${connection['baseUrl']}paywall/events/batch');
      final payload = {
        for (final entry in connection.entries)
          if (entry.key != 'baseUrl') entry.key: entry.value,
        'events': batch
            .map(
              (event) => {
                for (final entry in event.entries)
                  if (entry.key != '_queueScope' &&
                      entry.key != '_legacyUnscoped' &&
                      entry.key != '_rejected')
                    entry.key: entry.value,
              },
            )
            .toList(),
      };

      final response = await httpClient
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (_disposed) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return;
        final ids = decoded['acknowledgedEventIds'];
        final batchIds = batch.map((event) => event['eventId']).toSet();
        final acknowledged = ids is List
            ? ids.whereType<String>().where(batchIds.contains).toSet()
            : decoded['invalid'] == 0 && decoded['processed'] == batch.length
            ? batchIds
            : <Object?>{};
        _queue.removeWhere((event) => acknowledged.contains(event['eventId']));
        final rejected = decoded['rejectedEventIds'];
        if (rejected is List) {
          final rejectedIds = rejected
              .whereType<String>()
              .where(batchIds.contains)
              .toSet();
          for (final event in batch) {
            // Retain rejected events for diagnosis without starving valid ones.
            if (rejectedIds.contains(event['eventId']))
              event['_rejected'] = true;
          }
        }
        await _saveQueueToDisk();
      }
    } catch (e) {
      _logger.d('[MySuperWall] Offline event queue flush will retry later: $e');
    } finally {
      _isFlushing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _connection = null;
    _timer?.cancel();
    _timer = null;
  }
}
