import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'models/purchase_verification.dart';
import 'services/purchase_verification_service.dart';
import 'exceptions/mysuperwall_exception.dart';
import 'models/paywall_data.dart';
import 'models/paywall_automation_action.dart';
import 'models/paywall_result.dart';
import 'product_data_entry.dart';
import 'services/paywall_cache_service.dart';
import 'services/local_rule_engine.dart';
import 'services/manifest_service.dart';
import 'services/follow_up_service.dart';
import 'services/offline_event_queue.dart';
import 'ui/paywall_view.dart';
import 'ui/paywall_session.dart';

/// The core MySuperWall SDK client.
class MySuperWallClient {
  static MySuperWallClient? _instance;
  static int _hostMountCount = 0;
  static const String defaultBaseUrl = 'https://mysuperwall.com/';
  static const String _sdkValidationCacheKey =
      'mysuperwall_sdk_validation_cache';
  static const String _paywallCacheSchemaVersionKey =
      'mysuperwall_paywall_cache_schema_version';
  static const String _preparedPreferredTriggersCacheKey =
      'mysuperwall_prepared_preferred_triggers';
  static const String _preparedExcludedTriggersCacheKey =
      'mysuperwall_prepared_excluded_triggers';
  static const int _paywallCacheSchemaVersion = 3;
  static const Set<String> _terminalNoPaywallReasons = {
    'holdout',
    'app_not_found',
    'trigger_not_found',
    'paywall_not_assigned',
    'paywall_inactive',
    'missing_trigger_key',
    'missing_app_identifier',
  };

  final String baseUrl;
  final String? appKey; // Optional if package identifier is used
  String? _userId; // Centralized user ID
  String? _locale = Platform.localeName.replaceAll('_', '-').toLowerCase();
  String? _country;
  bool _subscriptionPremium = false;
  final FollowUpService _followUps = FollowUpService();
  int _flowGeneration = 0;
  PaywallData? _followUpPaywall;
  String? _followUpOutcomePaywallId;
  void Function(String event, String? paywallId)? _followUpEvent;

  /// Pass the host billing provider's current entitlement; never inferred from taps.
  void setSubscriptionStatus(bool premium) {
    _subscriptionPremium = premium;
  }

  final http.Client _httpClient;
  final Duration timeout;
  final bool failOpenOnNetworkError;
  final Map<String, DateTime> _paywallCachedAt = {};
  final Map<String, dynamic> _productData = {};
  int _productDataRevision = 0;
  final Map<String, PaywallResult> _paywallCache = {};
  final LinkedHashMap<String, PreparedPaywallController> _preparedPaywallPool =
      LinkedHashMap<String, PreparedPaywallController>();
  final Map<String, int> _preparedPriorityByTrigger = <String, int>{};
  final LinkedHashSet<String> _preferredPreparedTriggerKeys =
      LinkedHashSet<String>();
  final LinkedHashSet<String> _excludedPreparedTriggerKeys =
      LinkedHashSet<String>();
  final Map<String, Map<String, dynamic>> _purchaseContexts = {};
  Future<void> Function(MySuperWallAutomationAction action)?
  _automationActionHandler;
  SharedPreferences? _prefs;
  ManifestService? _manifestService;
  LocalRuleEngine _localRuleEngine = const LocalRuleEngine();
  OfflineEventQueue? _eventQueue;

  ManifestService? get manifestService => _manifestService;
  LocalRuleEngine get localRuleEngine => _localRuleEngine;
  OfflineEventQueue? get eventQueue => _eventQueue;
  final List<String> _pendingLifecycleTriggers = [];
  int _maxPreparedPaywalls = 0;
  static final ValueNotifier<int> _preparedPoolVersion = ValueNotifier<int>(0);
  static final ValueNotifier<String?> _activePreparedTriggerKey =
      ValueNotifier<String?>(null);
  static final ValueNotifier<bool> _hostLoadingOverlayVisible =
      ValueNotifier<bool>(false);
  static Route<void>? _preparedBackInterceptorRoute;
  static NavigatorState? _preparedBackInterceptorNavigator;

  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 50,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  MySuperWallClient._({
    required this.baseUrl,
    this.appKey,
    String? userId,
    http.Client? httpClient,
    Duration? timeout,
    this.failOpenOnNetworkError = true,
  }) : _userId = userId,
       _httpClient = httpClient ?? http.Client(),
       timeout = timeout ?? const Duration(seconds: 8);

  void loadProducts(Map<String, String> prices) {
    unawaited(setProductData(prices, replace: false));
  }

  Map<String, String> get productPrices => Map<String, String>.unmodifiable(
    _productData.map((key, value) {
      if (value is String) {
        return MapEntry(key, value);
      }
      if (value is Map) {
        final displayPrice = value['displayPrice']?.toString();
        final priceString = value['priceString']?.toString();
        return MapEntry(key, displayPrice ?? priceString ?? '');
      }
      return MapEntry(key, value?.toString() ?? '');
    }),
  );

  Map<String, dynamic> get productData =>
      Map<String, dynamic>.unmodifiable(_productData);

  void loadProductData(Map<String, dynamic> productData) {
    unawaited(setProductData(productData, replace: false));
  }

  int _preparedPriorityFor(String triggerKey) =>
      _preparedPriorityByTrigger[triggerKey] ?? 0;

  int get maxPreparedPaywalls => _maxPreparedPaywalls;

  List<String> get preparedTriggerKeys =>
      _preparedPaywallPool.keys.toList(growable: false);
  Map<String, PreparedPaywallController> get preparedPaywallControllers =>
      Map<String, PreparedPaywallController>.unmodifiable(_preparedPaywallPool);
  List<String> get preferredPreparedTriggerKeys =>
      _preferredPreparedTriggerKeys.toList(growable: false);
  Map<String, int> get preparedPriorityByTrigger =>
      Map<String, int>.unmodifiable(_preparedPriorityByTrigger);
  List<String> get excludedPreparedTriggerKeys =>
      _excludedPreparedTriggerKeys.toList(growable: false);
  static ValueNotifier<int> get preparedPoolListenable => _preparedPoolVersion;
  static ValueNotifier<String?> get activePreparedTriggerKeyListenable =>
      _activePreparedTriggerKey;
  static ValueNotifier<bool> get hostLoadingOverlayListenable =>
      _hostLoadingOverlayVisible;
  static String? get activePreparedTriggerKey =>
      _activePreparedTriggerKey.value;
  static bool get isHostMounted => _hostMountCount > 0;

  static void setHostLoadingOverlayVisible(bool visible) {
    if (_hostLoadingOverlayVisible.value == visible) {
      return;
    }
    _hostLoadingOverlayVisible.value = visible;
  }

  void configurePreparedPaywallPool({required int maxCount}) {
    final clampedCount = maxCount.clamp(0, 3);
    _maxPreparedPaywalls = clampedCount;
    _trimPreparedPaywallPool();
  }

  static void registerHostMounted(bool mounted) {
    if (mounted) {
      _hostMountCount++;
    } else {
      _hostMountCount = (_hostMountCount - 1).clamp(0, 1 << 20);
    }

    if (_hostMountCount == 0) {
      _activePreparedTriggerKey.value = null;
    }
  }

  Future<void> setPreparedPaywallPreferences({
    List<String>? preferredTriggerKeys,
    List<String>? excludedTriggerKeys,
    bool warmPool = true,
  }) async {
    if (preferredTriggerKeys != null) {
      _preferredPreparedTriggerKeys
        ..clear()
        ..addAll(_normalizeTriggerKeys(preferredTriggerKeys));
    }

    if (excludedTriggerKeys != null) {
      _excludedPreparedTriggerKeys
        ..clear()
        ..addAll(_normalizeTriggerKeys(excludedTriggerKeys));
    }

    _preferredPreparedTriggerKeys.removeWhere(
      _excludedPreparedTriggerKeys.contains,
    );

    await _persistPreparedPaywallPreferences();

    final excludedToDispose = _preparedPaywallPool.keys
        .where(_excludedPreparedTriggerKeys.contains)
        .toList(growable: false);
    clearPreparedPaywallPool(triggerKeys: excludedToDispose);
    _trimPreparedPaywallPool();

    if (warmPool) {
      await warmPreparedPaywalls();
    }
  }

  Future<void> excludePreparedTrigger(
    String triggerKey, {
    bool warmPool = true,
  }) async {
    final normalized = _normalizeTriggerKey(triggerKey);
    if (normalized == null) {
      return;
    }

    _excludedPreparedTriggerKeys.add(normalized);
    _preferredPreparedTriggerKeys.remove(normalized);
    await _persistPreparedPaywallPreferences();
    clearPreparedPaywallPool(triggerKeys: [normalized]);

    if (warmPool) {
      await warmPreparedPaywalls();
    }
  }

  Future<void> includePreparedTrigger(
    String triggerKey, {
    bool warmPool = true,
  }) async {
    final normalized = _normalizeTriggerKey(triggerKey);
    if (normalized == null) {
      return;
    }

    if (_excludedPreparedTriggerKeys.remove(normalized)) {
      await _persistPreparedPaywallPreferences();
    }

    if (warmPool) {
      await warmPreparedPaywalls(preferredTriggerKeys: [normalized]);
    }
  }

  Future<void> warmPreparedPaywalls({
    List<String>? preferredTriggerKeys,
  }) async {
    if (_maxPreparedPaywalls <= 0) {
      return;
    }

    final explicitPreferredTriggerKeys = _normalizeTriggerKeys(
      preferredTriggerKeys,
    ).toSet();
    final candidateTriggerKeys = LinkedHashSet<String>()
      ..addAll(_preferredPreparedTriggerKeys)
      ..addAll(explicitPreferredTriggerKeys)
      ..addAll(
        _paywallCache.entries
            .where(
              (entry) =>
                  !_excludedPreparedTriggerKeys.contains(entry.key) &&
                  entry.value.show &&
                  entry.value.paywall != null,
            )
            .map((entry) => entry.key),
      );

    final orderedTriggerKeys = candidateTriggerKeys.toList(growable: false)
      ..sort((left, right) {
        final leftPreferred =
            _preferredPreparedTriggerKeys.contains(left) ||
            explicitPreferredTriggerKeys.contains(left);
        final rightPreferred =
            _preferredPreparedTriggerKeys.contains(right) ||
            explicitPreferredTriggerKeys.contains(right);
        if (leftPreferred != rightPreferred) {
          return leftPreferred ? -1 : 1;
        }

        final priorityDiff =
            _preparedPriorityFor(right) - _preparedPriorityFor(left);
        if (priorityDiff != 0) {
          return priorityDiff;
        }

        return 0;
      });

    for (final triggerKey in orderedTriggerKeys) {
      if (_preparedPaywallPool.length >= _maxPreparedPaywalls &&
          !_preparedPaywallPool.containsKey(triggerKey)) {
        final weakestTriggerKey = _findWeakestPreparedTriggerKey();
        if (weakestTriggerKey == null ||
            !_shouldReplacePreparedTrigger(
              incomingTriggerKey: triggerKey,
              existingTriggerKey: weakestTriggerKey,
            )) {
          continue;
        }
      }

      final result =
          _freshMemoryResult(triggerKey) ?? await _loadFromDisk(triggerKey);
      if (result == null || !result.show || result.paywall == null) {
        continue;
      }

      await _preparePaywallController(triggerKey, result);
    }
  }

  void clearPreparedPaywallPool({List<String>? triggerKeys}) {
    if (triggerKeys == null || triggerKeys.isEmpty) {
      for (final controller in _preparedPaywallPool.values) {
        controller.dispose();
      }
      _preparedPaywallPool.clear();
      _preparedPoolVersion.value++;
      return;
    }

    for (final triggerKey in triggerKeys) {
      _preparedPaywallPool.remove(triggerKey)?.dispose();
    }
    _preparedPoolVersion.value++;
  }

  Future<void> clearCachedPaywalls({bool clearPreparedPaywalls = true}) async {
    _paywallCache.clear();
    _paywallCachedAt.clear();
    _preparedPriorityByTrigger.clear();

    if (clearPreparedPaywalls) {
      clearPreparedPaywallPool();
    }

    if (_prefs == null) {
      return;
    }

    final cacheKeys = _prefs!.getKeys().where(
      (key) => key.startsWith('mysuperwall_cache_'),
    );

    for (final key in cacheKeys.toList(growable: false)) {
      try {
        await _prefs!.remove(key);
      } catch (e) {
        _logger.w('[MySuperWall] Failed to clear cached paywall "$key": $e');
      }
    }
  }

  Future<void> setProductPrices(
    Map<String, String> prices, {
    bool replace = true,
    bool clearCachedPaywalls = false,
  }) async {
    await setProductData(
      prices,
      replace: replace,
      clearCachedPaywalls: clearCachedPaywalls,
    );
  }

  Future<void> setProductData(
    Map<String, dynamic> productData, {
    bool replace = true,
    bool clearCachedPaywalls = false,
  }) async {
    // Rendered HTML contains store prices. A product update invalidates every
    // representation, including the offline manifest and prepared WebViews.
    final previous = jsonEncode(_productData);
    final captured =
        jsonDecode(jsonEncode(productData)) as Map<String, dynamic>;
    if (replace) {
      _productData
        ..clear()
        ..addAll(captured);
    } else {
      _productData.addAll(captured);
    }
    final changed = previous != jsonEncode(_productData);
    if (changed) {
      final revision = ++_productDataRevision;
      final scope = _cacheScope;
      // clear() invalidates the in-memory manifest and pending fetches before
      // its first await, so no stale USD HTML remains eligible for local rules.
      final manifestClear = _manifestService?.clear(scope).catchError((
        Object error,
      ) {
        _logger.w(
          '[MySuperWall] Could not remove stale price manifest: $error',
        );
      });
      await this.clearCachedPaywalls();
      if (manifestClear != null) {
        await manifestClear;
      }
      if (revision == _productDataRevision && scope == _cacheScope) {
        await _syncManifestInBackground();
      }
    } else if (clearCachedPaywalls) {
      await this.clearCachedPaywalls();
    }

    final productIds = _productData.keys.toList(growable: false);
    _logger.i(
      '[MySuperWall] Product data loaded for ${productIds.length} product(s): $productIds',
    );
  }

  Future<void> setStructuredProductData(
    Map<String, MySuperWallProductDataEntry> productData, {
    bool replace = true,
    bool clearCachedPaywalls = false,
  }) async {
    final normalized = productData.map(
      (productId, entry) => MapEntry(productId, entry.toJson()),
    );

    await setProductData(
      normalized,
      replace: replace,
      clearCachedPaywalls: clearCachedPaywalls,
    );
  }

  String? _normalizeTriggerKey(String triggerKey) {
    final normalized = triggerKey.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  Iterable<String> _normalizeTriggerKeys(Iterable<String>? triggerKeys) sync* {
    if (triggerKeys == null) {
      return;
    }

    final seen = <String>{};
    for (final triggerKey in triggerKeys) {
      final normalized = _normalizeTriggerKey(triggerKey);
      if (normalized == null || !seen.add(normalized)) {
        continue;
      }
      yield normalized;
    }
  }

  void _loadPreparedPaywallPreferences() {
    if (_prefs == null) {
      return;
    }

    _preferredPreparedTriggerKeys
      ..clear()
      ..addAll(
        _normalizeTriggerKeys(
          _prefs!.getStringList(_preparedPreferredTriggersCacheKey),
        ),
      );
    _excludedPreparedTriggerKeys
      ..clear()
      ..addAll(
        _normalizeTriggerKeys(
          _prefs!.getStringList(_preparedExcludedTriggersCacheKey),
        ),
      );
    _preferredPreparedTriggerKeys.removeWhere(
      _excludedPreparedTriggerKeys.contains,
    );
  }

  Future<void> _persistPreparedPaywallPreferences() async {
    if (_prefs == null) {
      return;
    }

    try {
      await _prefs!.setStringList(
        _preparedPreferredTriggersCacheKey,
        preferredPreparedTriggerKeys,
      );
      await _prefs!.setStringList(
        _preparedExcludedTriggersCacheKey,
        excludedPreparedTriggerKeys,
      );
    } catch (e) {
      _logger.w(
        '[MySuperWall] Failed to persist prepared paywall preferences: $e',
      );
    }
  }

  Future<void> _migratePaywallCacheIfNeeded() async {
    if (_prefs == null) {
      return;
    }

    final storedVersion = _prefs!.getInt(_paywallCacheSchemaVersionKey) ?? 0;
    if (storedVersion == _paywallCacheSchemaVersion) {
      return;
    }

    try {
      await clearCachedPaywalls();
      await _prefs!.setInt(
        _paywallCacheSchemaVersionKey,
        _paywallCacheSchemaVersion,
      );
      _logger.i(
        '[MySuperWall] Cleared stale paywall cache after schema upgrade to v$_paywallCacheSchemaVersion.',
      );
    } catch (e) {
      _logger.w('[MySuperWall] Failed to migrate paywall cache schema: $e');
    }
  }

  /// Initializes the MySuperWall SDK instance.
  static Future<MySuperWallClient> initialize({
    String? appKey,
    String? userId,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 8),
    bool failOpenOnNetworkError = true,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (userId == null || userId.trim().isEmpty) {
        userId = prefs.getString('mysuperwall_anonymous_user_id');
        if (userId == null) {
          userId = const Uuid().v4();
          await prefs.setString('mysuperwall_anonymous_user_id', userId);
        }
      }

      final client = MySuperWallClient._(
        baseUrl: defaultBaseUrl,
        appKey: appKey,
        userId: userId,
        httpClient: httpClient,
        timeout: requestTimeout,
        failOpenOnNetworkError: failOpenOnNetworkError,
      );
      client._prefs = prefs;
      client._manifestService = ManifestService(
        preferences: prefs,
        httpClient: client._httpClient,
        logger: _logger,
      );
      client._localRuleEngine = const LocalRuleEngine();
      client._eventQueue = OfflineEventQueue(
        preferences: prefs,
        httpClient: client._httpClient,
        logger: _logger,
      );

      // Instant 0ms readiness: load offline manifest from disk
      client._manifestService?.loadFromDisk(client._cacheScope);

      await client._migratePaywallCacheIfNeeded();
      client._loadPreparedPaywallPreferences();

      await client._validateConfiguration();

      // Non-blocking background manifest sync with ETag / 304 validation
      unawaited(client._syncManifestInBackground());

      // Manage internal metrics
      await client._updateInternalMetrics(prefs);
      // Compute which lifecycle triggers apply this session
      await client._computeLifecycleTriggers(prefs);

      _instance = client;
      return client;
    } catch (e) {
      _logger.e('[MySuperWall] SDK initialization failed: $e');
      rethrow;
    }
  }

  Future<void> _validateConfiguration() async {
    final appInfo = await PackageInfo.fromPlatform();
    final body = {
      if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
      if (Platform.isIOS) 'bundleId': appInfo.packageName,
      if (Platform.isAndroid) 'packageName': appInfo.packageName,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'appVersion': appInfo.version,
    };
    final cachedValidation = _loadCachedValidation(body);

    http.Response response;
    try {
      response = await _httpClient
          .post(
            Uri.parse('${baseUrl}paywall/sdk-init'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (e) {
      if (cachedValidation != null) {
        _logger.w(
          '[MySuperWall] SDK validation request failed, using cached validation: $e',
        );
        return;
      }

      if (failOpenOnNetworkError && _isTransientFailure(e)) {
        _logger.w(
          '[MySuperWall] Starting offline without a validated configuration.',
        );
        return;
      }
      _logger.e(
        '[MySuperWall] SDK initialization validation request failed: $e',
      );
      throw MySuperWallException(
        'Failed to validate MySuperWall SDK configuration.',
        code: 'sdk_init_request_failed',
        details: {'error': e.toString()},
      );
    }

    final payload = _decodeJsonMap(response.body);
    if (response.statusCode != 200) {
      if (response.statusCode >= 500 || response.statusCode == 429) {
        if (cachedValidation != null || failOpenOnNetworkError) return;
      } else {
        await _prefs?.remove(_sdkValidationCacheKey);
        await clearCachedPaywalls();
      }
      final exception = _buildExceptionFromResponse(
        response,
        payload,
        fallbackCode: 'sdk_init_failed',
        fallbackMessage:
            'MySuperWall SDK initialization failed because the app configuration could not be validated.',
      );
      _logger.e('[MySuperWall] ${exception.toString()}');
      throw exception;
    }

    await _saveValidationCache(body, payload);
    _logger.i(
      '[MySuperWall] SDK initialized for app ${payload['appKey'] ?? appKey ?? appInfo.packageName}.',
    );
  }

  Future<void> _syncManifestInBackground() async {
    try {
      final appInfo = await PackageInfo.fromPlatform();
      await _manifestService?.fetchManifest(
        baseUrl: baseUrl,
        scope: _cacheScope,
        appKey: appKey,
        bundleId: Platform.isIOS ? appInfo.packageName : null,
        packageName: Platform.isAndroid ? appInfo.packageName : null,
        platform: Platform.isIOS ? 'ios' : 'android',
        appVersion: appInfo.version,
        lang: _locale,
        substitutionData: _productData,
        timeout: timeout,
      );
    } catch (e) {
      _logger.d('[MySuperWall] Background manifest sync error: $e');
    }
  }

  Future<void> _flushEventQueue() async {
    try {
      final appInfo = await PackageInfo.fromPlatform();
      await _eventQueue?.flush(
        baseUrl: baseUrl,
        appKey: appKey,
        bundleId: Platform.isIOS ? appInfo.packageName : null,
        packageName: Platform.isAndroid ? appInfo.packageName : null,
        platform: Platform.isIOS ? 'ios' : 'android',
        appVersion: appInfo.version,
        userId: _userId,
      );
    } catch (_) {}
  }

  /// Internal: Handle session count and install date
  Future<void> _updateInternalMetrics(SharedPreferences prefs) async {
    // 1. Session Count
    final sessionCount = (prefs.getInt('mysuperwall_session_count') ?? 0) + 1;
    await prefs.setInt('mysuperwall_session_count', sessionCount);

    // 2. Install Date
    String? installDate = prefs.getString('mysuperwall_install_date');
    if (installDate == null) {
      installDate = DateTime.now().toIso8601String();
      await prefs.setString('mysuperwall_install_date', installDate);
    }
  }

  // ── Lifecycle Trigger Computation ──────────────────────────────────────────

  /// Computes which system lifecycle triggers should fire this session.
  /// Called once during initialize(). Results stored in [_pendingLifecycleTriggers].
  Future<void> _computeLifecycleTriggers(SharedPreferences prefs) async {
    _pendingLifecycleTriggers.clear();

    final sessionCount = prefs.getInt('mysuperwall_session_count') ?? 1;
    final installStr = prefs.getString('mysuperwall_install_date');
    final daysSince = installStr != null
        ? DateTime.now().difference(DateTime.parse(installStr)).inDays
        : 0;

    String appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } catch (_) {}

    // 1. App Install (first ever session)
    if (!prefs.containsKey('mysuperwall_lc_install_fired')) {
      _pendingLifecycleTriggers.add('mysuperwall.install');
      await prefs.setBool('mysuperwall_lc_install_fired', true);
    }

    // 2. App Update (version change since last launch)
    final lastVersion = prefs.getString('mysuperwall_last_known_version');
    if (lastVersion != null && lastVersion != appVersion) {
      _pendingLifecycleTriggers.add('mysuperwall.update');
    }
    await prefs.setString('mysuperwall_last_known_version', appVersion);

    // 3. Every Session
    _pendingLifecycleTriggers.add('mysuperwall.session');

    // 4. Session Milestones (fire once per milestone)
    for (final milestone in [3, 5, 10, 20, 50]) {
      final key = 'mysuperwall_lc_session${milestone}_fired';
      if (sessionCount >= milestone && !prefs.containsKey(key)) {
        _pendingLifecycleTriggers.add('mysuperwall.session_$milestone');
        await prefs.setBool(key, true);
      }
    }

    // 5. Day Thresholds (fire once per threshold)
    for (final day in [1, 3, 7, 14, 30]) {
      final key = 'mysuperwall_lc_day${day}_fired';
      if (daysSince >= day && !prefs.containsKey(key)) {
        _pendingLifecycleTriggers.add('mysuperwall.day_$day');
        await prefs.setBool(key, true);
      }
    }
  }

  // ── Public Lifecycle API ───────────────────────────────────────────────────

  /// Returns all lifecycle events computed for this session.
  /// For informational use — e.g. logging or custom logic.
  List<String> get pendingLifecycleTriggers =>
      List.unmodifiable(_pendingLifecycleTriggers);

  /// Fires pending lifecycle triggers in priority order and shows the
  /// first paywall that matches. Call this once after your app's main
  /// widget is ready (e.g., in initState after navigation is set up).
  ///
  /// Example:
  ///   await MySuperWallClient.instance.handleLifecycleTriggers(
  ///     context,
  ///     onPurchase: (pid) => yourPurchaseHandler(pid),
  ///   );
  Future<void> handleLifecycleTriggers(
    BuildContext context, {
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
  }) async {
    for (final triggerKey in List.of(_pendingLifecycleTriggers)) {
      try {
        final result = await handleTrigger(
          context,
          triggerKey: triggerKey,
          onPurchase: onPurchase,
          onRestore: onRestore,
          onDismiss: onDismiss,
        );
        // Stop at first paywall shown — don't bombard the user
        if (result.show) {
          _logger.i('[MySuperWall] Lifecycle trigger shown: $triggerKey');
          break;
        }
      } catch (e) {
        _logger.w('[MySuperWall] Lifecycle trigger failed: $triggerKey — $e');
      }
    }
  }

  // ── Prefetch Lifecycle Paywalls ─────────────────────────────────────────────

  /// Pre-fetches all pending lifecycle paywalls in the background.
  /// Pair with handleLifecycleTriggers() for instant display.
  Future<void> prefetchLifecycleTriggers() async {
    for (final triggerKey in List.of(_pendingLifecycleTriggers)) {
      try {
        await prefetchPaywall(triggerKey: triggerKey);
      } catch (_) {
        /* best-effort, non-critical */
      }
    }
  }

  /// Internal: Increment total paywall views
  Future<void> _incrementViewCount() async {
    if (_prefs == null) return;
    try {
      final views = (_prefs!.getInt('mysuperwall_total_views') ?? 0) + 1;
      await _prefs!.setInt('mysuperwall_total_views', views);
    } catch (_) {}
  }

  /// Set or update the centralized User ID for all subsequent events/paywalls.
  void setUserId(String userId) {
    if (userId.trim().isEmpty) {
      throw const MySuperWallException('User ID cannot be empty');
    }
    if (_userId == userId.trim()) return;
    _userId = userId.trim();
    _subscriptionPremium = false;
    _clearIdentityState();
  }

  /// Set the locale explicitly, rather than relying on the backend default
  void setLocale(String locale) {
    final normalizedLocale = locale.trim().replaceAll('_', '-').toLowerCase();
    if (normalizedLocale.isEmpty) return;
    if (_locale == normalizedLocale) {
      return;
    }

    _locale = normalizedLocale;
    _clearIdentityState();
  }

  /// Country is a region code such as TR; it is independent of the paywall language.
  void setCountry(String country) {
    _country = country.trim().toUpperCase();
  }

  String get _deviceCountry {
    final parts = Platform.localeName.replaceAll('_', '-').split('-');
    for (final part in parts.skip(1)) {
      if (RegExp(r'^[a-zA-Z]{2}$').hasMatch(part)) return part.toUpperCase();
    }
    return '';
  }

  String get _cacheScope => jsonEncode([baseUrl, appKey, _userId, _locale]);

  void _clearIdentityState() {
    _flowGeneration++;
    _followUps.reset();
    _followUpEvent = null;
    _followUpPaywall = null;
    _followUpOutcomePaywallId = null;
    _manifestService?.loadFromDisk(_cacheScope);
    unawaited(_syncManifestInBackground());
    _paywallCache.clear();
    _paywallCachedAt.clear();
    _purchaseContexts.clear();
    clearPreparedPaywallPool();
  }

  PaywallResult? _freshMemoryResult(String key) {
    final savedAt = _paywallCachedAt[key];
    if (savedAt == null ||
        DateTime.now().difference(savedAt) >
            PaywallCacheService.freshLifetime) {
      return null;
    }
    return _paywallCache[key];
  }

  bool _isTransientFailure(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException) {
      return true;
    }
    if (error is MySuperWallException) {
      final status = error.statusCode;
      return status != null && (status >= 500 || status == 429);
    }
    return false;
  }

  /// Dismisses any currently presented paywall, whether it's a prepared layer or a route.
  void dismiss() {
    dismissPreparedPaywall();
    PaywallView.dismissCurrent();
  }

  /// Dismisses the currently presented prepared paywall, if any.
  void dismissPreparedPaywall() {
    final activeKey = _activePreparedTriggerKey.value;
    if (activeKey != null) {
      _preparedPaywallPool[activeKey]?.deactivate();
    }
    _activePreparedTriggerKey.value = null;
    _removePreparedBackInterceptor();
  }

  void _installPreparedBackInterceptor(
    BuildContext context, {
    required String triggerKey,
  }) {
    _removePreparedBackInterceptor();

    final navigator = Navigator.of(context, rootNavigator: true);
    final route = PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) {
        return const IgnorePointer(ignoring: true, child: SizedBox.expand());
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
    );

    _preparedBackInterceptorNavigator = navigator;
    _preparedBackInterceptorRoute = route;
    navigator.push(route);

    route.popped.then((_) {
      if (!identical(_preparedBackInterceptorRoute, route)) {
        return;
      }

      _preparedBackInterceptorRoute = null;
      _preparedBackInterceptorNavigator = null;

      if (_activePreparedTriggerKey.value == triggerKey) {
        _preparedPaywallPool[triggerKey]?.dismiss();
      }
    });
  }

  void _removePreparedBackInterceptor() {
    final navigator = _preparedBackInterceptorNavigator;
    final route = _preparedBackInterceptorRoute;
    _preparedBackInterceptorNavigator = null;
    _preparedBackInterceptorRoute = null;

    if (navigator != null && route != null) {
      navigator.removeRoute(route);
    }
  }

  /// Get currently set user ID
  String? get currentUserId => _userId;

  /// Returns the current initialized instance.
  static MySuperWallClient get instance {
    if (_instance == null) {
      const error = 'MySuperWall SDK not initialized. Call initialize() first.';
      _logger.e('[MySuperWall] $error');
      throw const MySuperWallException(error);
    }
    return _instance!;
  }

  /// Returns true if the SDK has been initialized.
  static bool get isInitialized => _instance != null;

  /// Verifies connectivity with the backend server.
  Future<bool> healthCheck() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('${baseUrl}health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _decodeJsonMap(String body) {
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}

    return <String, dynamic>{'rawBody': body};
  }

  Map<String, dynamic>? _loadCachedValidation(
    Map<String, dynamic> requestBody,
  ) {
    final raw = _prefs?.getString(_sdkValidationCacheKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }

      final cache = Map<String, dynamic>.from(decoded);
      final validatedAt = DateTime.tryParse(
        cache['validatedAt']?.toString() ?? '',
      );
      if (validatedAt == null) return null;
      final age = DateTime.now().difference(validatedAt);
      if (age.isNegative || age > PaywallCacheService.offlineLifetime) {
        return null;
      }
      final appIdentity = cache['appIdentity'];
      if (appIdentity is! Map) {
        return null;
      }

      final appIdentityMap = Map<String, dynamic>.from(appIdentity);
      final matchesAppKey =
          appIdentityMap['appKey']?.toString() ==
          requestBody['appKey']?.toString();
      final matchesBundleId =
          appIdentityMap['bundleId']?.toString() ==
          requestBody['bundleId']?.toString();
      final matchesPackageName =
          appIdentityMap['packageName']?.toString() ==
          requestBody['packageName']?.toString();
      final matchesPlatform =
          appIdentityMap['platform']?.toString() ==
          requestBody['platform']?.toString();

      final hasMatchingExplicitKey =
          requestBody.containsKey('appKey') && matchesAppKey;
      final hasMatchingStoreId =
          (requestBody.containsKey('bundleId') && matchesBundleId) ||
          (requestBody.containsKey('packageName') && matchesPackageName);

      if (!matchesPlatform ||
          (requestBody.containsKey('appKey')
              ? !hasMatchingExplicitKey
              : !hasMatchingStoreId)) {
        return null;
      }

      return cache;
    } catch (e) {
      _logger.w('[MySuperWall] Failed to decode cached SDK validation: $e');
      return null;
    }
  }

  Future<void> _saveValidationCache(
    Map<String, dynamic> requestBody,
    Map<String, dynamic> responsePayload,
  ) async {
    if (_prefs == null) {
      return;
    }

    final cache = <String, dynamic>{
      'validatedAt': DateTime.now().toIso8601String(),
      'appIdentity': {
        'appKey': requestBody['appKey'],
        'bundleId': requestBody['bundleId'],
        'packageName': requestBody['packageName'],
        'platform': requestBody['platform'],
      },
      'response': responsePayload,
    };

    try {
      await _prefs!.setString(_sdkValidationCacheKey, jsonEncode(cache));
    } catch (e) {
      _logger.w('[MySuperWall] Failed to persist SDK validation cache: $e');
    }
  }

  MySuperWallException _buildExceptionFromResponse(
    http.Response response,
    Map<String, dynamic> payload, {
    required String fallbackCode,
    required String fallbackMessage,
  }) {
    return MySuperWallException(
      payload['message']?.toString() ?? fallbackMessage,
      code: payload['reason']?.toString() ?? fallbackCode,
      statusCode: response.statusCode,
      details: payload.isEmpty ? null : payload,
    );
  }

  void _logNoPaywallResult(
    String triggerKey,
    PaywallResult result, {
    required String phase,
  }) {
    final reason = result.reason ?? 'unknown_reason';
    final message = result.message ?? 'Backend returned show=false.';
    _logger.e(
      '[MySuperWall] No paywall shown during $phase for trigger "$triggerKey". '
      'reason=$reason message=$message details=${result.details}',
    );
  }

  bool _isTerminalNoPaywallResult(PaywallResult result) {
    if (result.show || result.paywall != null) {
      return false;
    }

    final reason = result.reason?.trim();
    return reason != null && _terminalNoPaywallReasons.contains(reason);
  }

  Future<void> _cacheResolvedPaywall(
    String triggerKey,
    PaywallResult result,
  ) async {
    if (!result.show || result.paywall == null) {
      return;
    }

    final scope = _cacheScope;
    await _stashAssetsAsBase64(result.paywall!);
    if (_cacheScope != scope) return;
    final productDetails = <String>[];
    for (final productId in result.paywall!.productIds) {
      final data = _productData[productId];
      if (data is Map) {
        final displayPrice =
            data['displayPrice']?.toString() ??
            data['priceString']?.toString() ??
            '';
        productDetails.add('$productId => $displayPrice');
      } else if (data != null) {
        productDetails.add('$productId => ${data.toString()}');
      } else {
        productDetails.add('$productId => missing_product_data');
      }
    }

    _logger.i(
      '[MySuperWall] Paywall "$triggerKey" product data resolved with live prices: $productDetails',
    );
    _paywallCache[triggerKey] = result;
    await _saveToDisk(triggerKey, result);
    await _preparePaywallController(triggerKey, result);
    if (_cacheScope != scope) _clearIdentityState();
  }

  void _trimPreparedPaywallPool() {
    while (_preparedPaywallPool.length > _maxPreparedPaywalls) {
      final weakestKey =
          _findWeakestPreparedTriggerKey() ?? _preparedPaywallPool.keys.first;
      _preparedPaywallPool.remove(weakestKey)?.dispose();
    }
    _preparedPoolVersion.value++;
  }

  String? _findWeakestPreparedTriggerKey() {
    if (_preparedPaywallPool.isEmpty) {
      return null;
    }

    String? weakestKey;
    for (final key in _preparedPaywallPool.keys) {
      if (weakestKey == null) {
        weakestKey = key;
        continue;
      }

      final keyPreferred = _preferredPreparedTriggerKeys.contains(key);
      final weakestPreferred = _preferredPreparedTriggerKeys.contains(
        weakestKey,
      );
      if (keyPreferred != weakestPreferred) {
        if (!keyPreferred) {
          weakestKey = key;
        }
        continue;
      }

      final keyPriority = _preparedPriorityFor(key);
      final weakestPriority = _preparedPriorityFor(weakestKey);
      if (keyPriority < weakestPriority) {
        weakestKey = key;
      }
    }

    return weakestKey;
  }

  bool _shouldReplacePreparedTrigger({
    required String incomingTriggerKey,
    required String existingTriggerKey,
  }) {
    final incomingPreferred = _preferredPreparedTriggerKeys.contains(
      incomingTriggerKey,
    );
    final existingPreferred = _preferredPreparedTriggerKeys.contains(
      existingTriggerKey,
    );
    if (incomingPreferred != existingPreferred) {
      return incomingPreferred && !existingPreferred;
    }

    return _preparedPriorityFor(incomingTriggerKey) >
        _preparedPriorityFor(existingTriggerKey);
  }

  Future<void> _preparePaywallController(
    String triggerKey,
    PaywallResult result,
  ) async {
    if (_maxPreparedPaywalls <= 0 ||
        !result.show ||
        result.paywall == null ||
        _excludedPreparedTriggerKeys.contains(triggerKey)) {
      return;
    }

    if (_preparedPaywallPool.containsKey(triggerKey)) {
      final existing = _preparedPaywallPool.remove(triggerKey)!;
      _preparedPaywallPool[triggerKey] = existing;
      _preparedPoolVersion.value++;
      return;
    }

    if (_preparedPaywallPool.length >= _maxPreparedPaywalls) {
      final candidateToEvict =
          _findWeakestPreparedTriggerKey() ?? _preparedPaywallPool.keys.first;

      if (!_shouldReplacePreparedTrigger(
        incomingTriggerKey: triggerKey,
        existingTriggerKey: candidateToEvict,
      )) {
        return;
      }

      _preparedPaywallPool.remove(candidateToEvict)?.dispose();
    }

    final preparedController = PreparedPaywallController(
      paywall: result.paywall!,
    );
    _preparedPaywallPool[triggerKey] = preparedController;
    _preparedPoolVersion.value++;
    await WidgetsBinding.instance.endOfFrame;
    try {
      await preparedController.warm(baseUrl: baseUrl);
    } catch (e) {
      _preparedPaywallPool.remove(triggerKey)?.dispose();
      _preparedPoolVersion.value++;
      rethrow;
    }
  }

  Future<PreparedPaywallController> _prepareRouteController(
    PaywallResult result,
  ) async {
    final preparedController = PreparedPaywallController(
      paywall: result.paywall!,
    );
    await preparedController.warm(baseUrl: baseUrl);
    await preparedController.waitUntilReady(
      timeout: const Duration(seconds: 8),
    );
    return preparedController;
  }

  Future<void> _presentPreparedPaywall(
    BuildContext? presentationContext,
    String triggerKey,
    PaywallResult result, {
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) {
    final preparedController = _preparedPaywallPool[triggerKey];
    if (preparedController == null || result.paywall == null) {
      return Future<void>.value();
    }
    final paywall = result.paywall!;
    final presentationScope = _cacheScope;

    Future<void> showPreparedPaywall() async {
      if (_preparedPaywallPool[triggerKey] != preparedController) {
        return;
      }

      if (presentationContext != null) {
        if (presentationContext is Element && !presentationContext.mounted) {
          return;
        }
        _installPreparedBackInterceptor(
          presentationContext,
          triggerKey: triggerKey,
        );
      }

      preparedController.activate(
        PaywallCallbacks(
          onPurchase: (pid) {
            if (presentationScope == _cacheScope) {
              _rememberPurchaseContext(
                productId: pid,
                paywallId: paywall.id,
                triggerKey: triggerKey,
                abVariant: paywall.abVariant,
                experimentContext: paywall.experimentContext,
              );
              trackPurchase(
                productId: pid,
                paywallId: paywall.id,
                triggerKey: triggerKey,
              );
            }
            if (onPurchase != null) {
              onPurchase(pid);
            }
          },
          onRestore: () {
            if (presentationScope == _cacheScope) {
              _trackDisplayedEvent('restore_started', paywall, triggerKey);
            }
            onRestore?.call();
          },
          onOpenUrl: onOpenUrl,
          onOpenTerms: (_) => onOpenTerms?.call(_extractTermsUrl(paywall)),
          onOpenPrivacy: (_) =>
              onOpenPrivacy?.call(_extractPrivacyUrl(paywall)),
          onDismiss: (durationInSeconds) {
            if (presentationScope == _cacheScope) {
              trackDismiss(
                paywallId: paywall.id,
                triggerKey: triggerKey,
                duration: durationInSeconds,
                abVariant: paywall.abVariant,
                experimentContext: paywall.experimentContext,
              );
            }
            dismissPreparedPaywall();
            if (onDismiss != null) {
              onDismiss();
            }
          },
        ),
      );
      _logger.i(
        '[MySuperWall] Prepared paywall presentation config '
        'trigger="$triggerKey" paywallId="${paywall.id}" '
        'style=${paywall.presentation.style.name} '
        'durationMs=${paywall.presentation.duration.inMilliseconds} '
        'curve=${paywall.presentation.curve.runtimeType}.',
      );
      final wasAlreadyVisible = _activePreparedTriggerKey.value == triggerKey;
      _activePreparedTriggerKey.value = triggerKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (presentationScope == _cacheScope &&
            !wasAlreadyVisible &&
            _activePreparedTriggerKey.value == triggerKey &&
            isHostMounted) {
          _trackDisplayedEvent('paywall_shown', paywall, triggerKey);
        }
      });
    }

    return showPreparedPaywall();
  }

  void _presentRoutePaywall(
    BuildContext context, {
    required String triggerKey,
    required PaywallData paywall,
    PreparedPaywallController? preparedController,
    bool disposeProvidedPreparedController = false,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) {
    final presentationScope = _cacheScope;
    PaywallView.show(
      context,
      paywall: paywall,
      onShown: () {
        if (presentationScope == _cacheScope) {
          _trackDisplayedEvent('paywall_shown', paywall, triggerKey);
        }
      },
      preparedController: preparedController,
      disposeProvidedPreparedController: disposeProvidedPreparedController,
      onPurchase: (pid) {
        if (presentationScope == _cacheScope) {
          _rememberPurchaseContext(
            productId: pid,
            paywallId: paywall.id,
            triggerKey: triggerKey,
            abVariant: paywall.abVariant,
            experimentContext: paywall.experimentContext,
          );
          trackPurchase(
            productId: pid,
            paywallId: paywall.id,
            triggerKey: triggerKey,
          );
        }
        if (onPurchase != null) {
          onPurchase(pid);
        }
      },
      onRestore: () {
        if (presentationScope == _cacheScope) {
          _trackDisplayedEvent('restore_started', paywall, triggerKey);
        }
        if (onRestore != null) {
          onRestore();
        }
      },
      onOpenUrl: onOpenUrl,
      onOpenTerms: (_) => onOpenTerms?.call(_extractTermsUrl(paywall)),
      onOpenPrivacy: (_) => onOpenPrivacy?.call(_extractPrivacyUrl(paywall)),
      onDismiss: () {
        if (presentationScope == _cacheScope) {
          trackDismiss(
            paywallId: paywall.id,
            triggerKey: triggerKey,
            abVariant: paywall.abVariant,
            experimentContext: paywall.experimentContext,
          );
        }
        if (onDismiss != null) {
          onDismiss();
        }
      },
    );
  }

  Future<bool> presentPreparedPaywallIfAvailable({
    required String triggerKey,
    BuildContext? presentationContext,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) async {
    if (!isHostMounted) {
      _logger.i(
        '[MySuperWall] Prepared presentation skipped for "$triggerKey": host not mounted.',
      );
      return false;
    }

    final preparedController = _preparedPaywallPool[triggerKey];
    if (preparedController == null) {
      _logger.i(
        '[MySuperWall] Prepared presentation skipped for "$triggerKey": controller missing.',
      );
      return false;
    }

    if (!preparedController.hasCompletedInitialLoad) {
      _logger.i(
        '[MySuperWall] Prepared presentation skipped for "$triggerKey": controller not ready yet.',
      );
      return false;
    }

    var result = _freshMemoryResult(triggerKey);
    result ??= await _loadFromDisk(triggerKey);
    if (result == null || !result.show || result.paywall == null) {
      clearPreparedPaywallPool(triggerKeys: [triggerKey]);
      return false;
    }

    _logger.i(
      '[MySuperWall] Presenting already-prepared paywall for trigger "$triggerKey".',
    );
    _incrementViewCount();
    await _presentPreparedPaywall(
      presentationContext,
      triggerKey,
      result,
      onPurchase: onPurchase,
      onRestore: onRestore,
      onDismiss: onDismiss,
      onOpenUrl: onOpenUrl,
      onOpenTerms: onOpenTerms,
      onOpenPrivacy: onOpenPrivacy,
    );
    return true;
  }

  /// Prefetches a paywall for a given trigger and stores it in cache.
  /// Useful for showing paywalls instantly.
  Future<PaywallResult> prefetchPaywall({
    required String triggerKey,
    Map<String, dynamic>? metadata,
    bool logNoPaywallResult = true,
  }) async {
    final scope = _cacheScope;
    final hasExplicitTargeting = metadata != null && metadata.isNotEmpty;
    if (hasExplicitTargeting) {
      clearPreparedPaywallPool(triggerKeys: [triggerKey]);
    }
    try {
      final result = await _fetchPaywallData(
        triggerKey: triggerKey,
        metadata: metadata,
      );

      if (_cacheScope != scope) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'identity_changed',
        );
      }
      if (!result.show || result.paywall == null) {
        // A successful holdout/disabled response must replace an older positive result.
        _paywallCache[triggerKey] = result;
        clearPreparedPaywallPool(triggerKeys: [triggerKey]);
        await _saveToDisk(triggerKey, result);
        if (logNoPaywallResult) {
          _logNoPaywallResult(triggerKey, result, phase: 'prefetch');
        }
        return result;
      }

      if (hasExplicitTargeting) return result;
      await _cacheResolvedPaywall(triggerKey, result);
      if (_cacheScope != scope) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'identity_changed',
        );
      }
      return result;
    } catch (e) {
      _logger.w('[MySuperWall] Preload failed for $triggerKey: $e');
      if (!_isTransientFailure(e) ||
          _cacheScope != scope ||
          hasExplicitTargeting) {
        rethrow;
      }
      // Stale cache is permitted only for transient failures, for at most 24 hours.
      try {
        final cached = await _loadFromDisk(triggerKey, allowStale: true);
        if (cached != null) {
          _paywallCache[triggerKey] = cached;
          return cached;
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<Map<String, PaywallResult>> prefetchAllActivePaywalls({
    Map<String, dynamic>? metadata,
  }) async {
    final scope = _cacheScope;
    final hasExplicitTargeting = metadata != null && metadata.isNotEmpty;
    try {
      if (_userId == null) {
        throw const MySuperWallException(
          'User ID not set. Call initialize(userId: ...) or setUserId().',
        );
      }

      final appInfo = await PackageInfo.fromPlatform();
      final systemMetadata = await _getSystemMetadata();
      final body = {
        if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
        if (Platform.isIOS) 'bundleId': appInfo.packageName,
        if (Platform.isAndroid) 'packageName': appInfo.packageName,
        'userId': _userId,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'appVersion': appInfo.version,
        if (_locale != null) 'lang': _locale,
        'metadata': {...?metadata, ...systemMetadata},
        'substitutionData': _productData,
      };

      final response = await _httpClient
          .post(
            Uri.parse('${baseUrl}paywall/prefetch-active'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);

      final payload = _decodeJsonMap(response.body);
      if (response.statusCode != 200) {
        if (response.statusCode >= 400 &&
            response.statusCode < 500 &&
            response.statusCode != 429) {
          await clearCachedPaywalls();
        }
        throw _buildExceptionFromResponse(
          response,
          payload,
          fallbackCode: 'prefetch_all_failed',
          fallbackMessage: 'Failed to prefetch active paywalls.',
        );
      }

      if (_cacheScope != scope) return {};
      final items = payload['items'];
      if (items is! List) {
        throw MySuperWallException(
          'Backend returned an invalid active paywall prefetch response.',
          code: 'invalid_prefetch_all_response',
          details: payload,
        );
      }

      final results = <String, PaywallResult>{};
      for (final item in items) {
        if (item is! Map) {
          continue;
        }

        final itemMap = Map<String, dynamic>.from(item);
        final triggerKey = itemMap['triggerKey']?.toString();
        final paywallPayload = itemMap['paywall'];
        if (triggerKey == null ||
            triggerKey.isEmpty ||
            paywallPayload is! Map<String, dynamic>) {
          continue;
        }

        final prewarmPriority = switch (itemMap['prewarmPriority']) {
          final int value => value,
          final num value => value.toInt(),
          final String value => int.tryParse(value) ?? 0,
          _ => 0,
        };
        _preparedPriorityByTrigger[triggerKey] = prewarmPriority;

        final paywallResult = PaywallResult.fromJson({
          'show': true,
          'abVariant': itemMap['abVariant'],
          'paywall': Map<String, dynamic>.from(paywallPayload),
        });
        if (!hasExplicitTargeting) {
          await _cacheResolvedPaywall(triggerKey, paywallResult);
        }
        if (_cacheScope != scope) return {};
        results[triggerKey] = paywallResult;
      }

      _logger.i(
        '[MySuperWall] Prefetched ${results.length} active paywall(s) in a single request.',
      );
      if (hasExplicitTargeting) {
        clearPreparedPaywallPool();
        return results;
      }
      final prefs = _prefs;
      if (prefs != null) {
        await PaywallCacheService(
          prefs,
        ).removeExcept(scope, results.keys.toSet());
      }
      if (_cacheScope != scope) return {};
      final removed = _paywallCache.keys
          .where((key) => !results.containsKey(key))
          .toList(growable: false);
      for (final key in removed) {
        _paywallCache.remove(key);
        _paywallCachedAt.remove(key);
      }
      clearPreparedPaywallPool(triggerKeys: removed);
      return results;
    } catch (error) {
      if (!_isTransientFailure(error) ||
          _cacheScope != scope ||
          hasExplicitTargeting) {
        rethrow;
      }
      final prefs = _prefs;
      final cached = prefs == null
          ? <String, PaywallResult>{}
          : PaywallCacheService(prefs).readAll(scope, allowStale: true);
      if (cached.isNotEmpty || failOpenOnNetworkError) return cached;
      rethrow;
    }
  }

  /// Caches image assets to local disk files for offline access & fast WebView loading
  /// without inflating memory with Base64 strings.
  Future<void> _stashAssetsAsBase64(dynamic paywall) async {
    try {
      final Map<String, dynamic> content = paywall.contentJson;
      final List<Future> downloads = [];

      final cacheDir = Directory(
        '${Directory.systemTemp.path}/mysuperwall_assets',
      );
      if (!cacheDir.existsSync()) {
        await cacheDir.create(recursive: true);
      }

      for (final key in content.keys) {
        final value = content[key];
        if (key.toLowerCase().contains('url') &&
            value is String &&
            value.startsWith('http')) {
          downloads.add(() async {
            final localFilePath = await _downloadOrGetCachedAsset(
              value,
              cacheDir,
            );
            if (localFilePath != null) {
              content[key] = Uri.file(localFilePath).toString();
            }
          }());
        }
      }

      await Future.wait(downloads);
    } catch (e) {
      _logger.w('[MySuperWall] Asset caching error: $e');
    }
  }

  Future<String?> _downloadOrGetCachedAsset(
    String url,
    Directory cacheDir,
  ) async {
    try {
      final sanitizedName = url.replaceAll(RegExp(r'[^a-zA-Z0-9_\.-]'), '_');
      final fileName = sanitizedName.length > 100
          ? sanitizedName.substring(sanitizedName.length - 100)
          : sanitizedName;
      final file = File('${cacheDir.path}/$fileName');

      if (await file.exists()) {
        return file.path;
      }

      final response = await _httpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveToDisk(String key, PaywallResult result) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _paywallCachedAt[key] = DateTime.now();
    try {
      await PaywallCacheService(prefs).save(_cacheScope, key, result);
    } catch (error) {
      _logger.w('[MySuperWall] Disk save failed: $error');
    }
  }

  Future<PaywallResult?> _loadFromDisk(
    String key, {
    bool allowStale = false,
  }) async {
    final prefs = _prefs;
    if (prefs == null) return null;
    try {
      final cached = PaywallCacheService(
        prefs,
      ).read(_cacheScope, key, allowStale: allowStale);
      if (cached == null) return null;
      _paywallCachedAt[key] = cached.savedAt;
      return cached.result;
    } catch (error) {
      _logger.w('[MySuperWall] Disk load failed: $error');
      return null;
    }
  }

  /// Internal method to fetch paywall data from backend
  Future<PaywallResult> _fetchPaywallData({
    required String triggerKey,
    Map<String, dynamic>? metadata,
  }) async {
    if (_userId == null) {
      throw const MySuperWallException(
        'User ID not set. Call initialize(userId: ...) or setUserId().',
      );
    }

    final appInfo = await PackageInfo.fromPlatform();
    final systemMetadata = await _getSystemMetadata();

    final body = {
      if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
      if (Platform.isIOS) 'bundleId': appInfo.packageName,
      if (Platform.isAndroid) 'packageName': appInfo.packageName,
      'triggerKey': triggerKey,
      'userId': _userId,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'appVersion': appInfo.version,
      'country': _country ?? _deviceCountry,
      if (_locale != null) 'lang': _locale,
      'metadata': {...?metadata, ...systemMetadata},
      'substitutionData': _productData,
    };

    final response = await _httpClient
        .post(
          Uri.parse('${baseUrl}paywall'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);

    final payload = _decodeJsonMap(response.body);

    if (response.statusCode != 200) {
      if (response.statusCode >= 400 &&
          response.statusCode < 500 &&
          response.statusCode != 429) {
        await clearCachedPaywalls();
      }
      throw _buildExceptionFromResponse(
        response,
        payload,
        fallbackCode: 'paywall_request_failed',
        fallbackMessage: 'Paywall request failed.',
      );
    }

    final result = PaywallResult.fromJson(payload);
    if (result.show && result.paywall == null) {
      throw MySuperWallException(
        'Backend returned show=true but no paywall payload for trigger "$triggerKey".',
        code: 'invalid_paywall_response',
        statusCode: response.statusCode,
        details: payload,
      );
    }

    return result;
  }

  /// Triggers a paywall event.
  /// It automatically displays the configured paywall over the current screen context.
  Future<PaywallResult> handleTrigger(
    BuildContext context, {
    required String triggerKey,
    Map<String, dynamic>? metadata,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) async {
    _flowGeneration++;
    _followUps.cancel();
    _followUpEvent = null;
    _followUpPaywall = null;
    _followUpOutcomePaywallId = null;
    return _handleTrigger(
      context,
      triggerKey: triggerKey,
      metadata: metadata,
      onPurchase: onPurchase,
      onRestore: onRestore,
      onDismiss: onDismiss,
      onOpenUrl: onOpenUrl,
      onOpenTerms: onOpenTerms,
      onOpenPrivacy: onOpenPrivacy,
    );
  }

  Future<PaywallResult> _handleTrigger(
    BuildContext context, {
    required String triggerKey,
    Map<String, dynamic>? metadata,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
    int followUpDepth = 0,
    List<String> followUpVisited = const [],
    bool preventFollowUpRepeat = true,
  }) async {
    final scope = _cacheScope;
    try {
      PaywallResult? result;

      // 0. ZERO LATENCY (0ms): In-memory client-side rule evaluation from offline manifest
      final manifest = _manifestService?.manifest;
      final manifestTrigger = manifest?.findTrigger(triggerKey);
      if (manifest != null && manifestTrigger != null) {
        final appInfo = await PackageInfo.fromPlatform();
        final systemMetadata = await _getSystemMetadata();
        final evalContext = <String, dynamic>{
          'platform': Platform.isIOS ? 'ios' : 'android',
          'appVersion': appInfo.version,
          'country': _country ?? _deviceCountry,
          'metadata': {...?metadata, ...systemMetadata},
          'userAttributes': {...?metadata, ...systemMetadata},
        };

        final resolution = _localRuleEngine.resolveTrigger(
          trigger: manifestTrigger,
          userId: _userId,
          context: evalContext,
        );

        if (resolution.isHoldout) {
          result = const PaywallResult(
            show: false,
            paywall: null,
            reason: 'holdout',
          );
          _eventQueue?.enqueue({
            'type': 'trigger_fired',
            'triggerKey': triggerKey,
            'isHoldout': true,
            'ruleName': resolution.matchedRuleName,
            'userId': _userId,
            'metadata': metadata,
          });
          unawaited(_flushEventQueue());
          return result;
        }

        if (resolution.show && resolution.paywallId != null) {
          final manifestPaywall = manifest.paywalls[resolution.paywallId];
          if (manifestPaywall != null) {
            result = manifestPaywall.toPaywallResult(
              triggerKey: triggerKey,
              appKey: appKey ?? appInfo.packageName,
              abVariant: resolution.abVariant,
              experimentContext: resolution.experimentContext,
            );
            _paywallCache[triggerKey] = result;
            _eventQueue?.enqueue({
              'type': 'trigger_fired',
              'triggerKey': triggerKey,
              'paywallId': manifestPaywall.id,
              'paywallName': manifestPaywall.name,
              'abVariant': resolution.abVariant,
              if (result.paywall?.experimentContext != null)
                'experimentContext': result.paywall?.experimentContext,
              'ruleName': resolution.matchedRuleName,
              'userId': _userId,
              'metadata': metadata,
            });
            unawaited(_flushEventQueue());
          }
        }
      }

      // 1. Try Memory Cache
      if (result == null) {
        result = metadata == null || metadata.isEmpty
            ? _freshMemoryResult(triggerKey)
            : null;
      }

      if (result != null && _isTerminalNoPaywallResult(result)) {
        return result;
      }

      // 2. Try Disk Cache
      if (result == null && (metadata == null || metadata.isEmpty)) {
        result = await _loadFromDisk(triggerKey);
        if (result != null) {
          _paywallCache[triggerKey] = result;
        }
      }

      // 3. Logic for Background Update vs Fresh Fetch
      if (result != null) {
        // Cache found. Present it directly without triggering another
        // background prefetch on every paywall open.
      } else {
        // No cache found (likely first run). Must wait for fresh data.
        try {
          result = await prefetchPaywall(
            triggerKey: triggerKey,
            metadata: metadata,
            logNoPaywallResult: false,
          );
        } catch (e) {
          _logger.w('[MySuperWall] Fresh fetch failed for $triggerKey: $e');
          if (failOpenOnNetworkError && _isTransientFailure(e)) {
            return const PaywallResult(
              show: false,
              paywall: null,
              reason: 'network_unavailable',
            );
          }
          rethrow;
        }
      }

      if (!result.show || result.paywall == null) {
        _logNoPaywallResult(triggerKey, result, phase: 'handleTrigger');
        return result;
      }

      if (_cacheScope != scope) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'identity_changed',
        );
      }
      // Increment global view count for analytics
      _incrementViewCount();

      if (!context.mounted) {
        final exception = MySuperWallException(
          'Paywall was resolved for trigger "$triggerKey", but the BuildContext is no longer mounted.',
          code: 'unmounted_context',
        );
        _logger.e('[MySuperWall] ${exception.toString()}');
        throw exception;
      }

      if (followUpDepth > 0 &&
          preventFollowUpRepeat &&
          followUpVisited.contains(result.paywall!.id)) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'follow_up_repeat',
        );
      }
      _bindFollowUp(
        context,
        result.paywall!,
        metadata: metadata,
        depth: followUpDepth,
        visited: followUpVisited,
        legacyPaywallId: manifestTrigger?.dismissFollowUpPaywallId,
        onPurchase: onPurchase,
        onRestore: onRestore,
        onDismiss: onDismiss,
        onOpenUrl: onOpenUrl,
        onOpenTerms: onOpenTerms,
        onOpenPrivacy: onOpenPrivacy,
      );

      final allowPrepared = metadata == null || metadata.isEmpty;
      PreparedPaywallController? preparedController = allowPrepared
          ? _preparedPaywallPool[triggerKey]
          : null;
      if (isHostMounted && allowPrepared) {
        if (preparedController == null) {
          _logger.w(
            '[MySuperWall] Prepared controller missing for "$triggerKey". Rebuilding before presentation.',
          );
          setHostLoadingOverlayVisible(true);
          try {
            await _preparePaywallController(triggerKey, result);
            await WidgetsBinding.instance.endOfFrame;
          } finally {
            setHostLoadingOverlayVisible(false);
          }
          preparedController = _preparedPaywallPool[triggerKey];
        }
      }

      if (isHostMounted && preparedController != null) {
        final needsReadyWait = !preparedController.hasCompletedInitialLoad;
        if (needsReadyWait) {
          _logger.i(
            '[MySuperWall] Prepared paywall for "$triggerKey" is not ready yet, waiting before presentation.',
          );
          setHostLoadingOverlayVisible(true);
        }

        try {
          await preparedController.waitUntilReady();
        } finally {
          if (needsReadyWait) {
            setHostLoadingOverlayVisible(false);
          }
        }

        if (_cacheScope != scope) {
          return const PaywallResult(
            show: false,
            paywall: null,
            reason: 'identity_changed',
          );
        }
        if (preparedController.hasCompletedInitialLoad) {
          _logger.i(
            '[MySuperWall] Using prepared ready paywall for trigger "$triggerKey".',
          );
          await _presentPreparedPaywall(
            context,
            triggerKey,
            result,
            onPurchase: onPurchase,
            onRestore: onRestore,
            onDismiss: onDismiss,
            onOpenUrl: onOpenUrl,
            onOpenTerms: onOpenTerms,
            onOpenPrivacy: onOpenPrivacy,
          );
        } else {
          _logger.w(
            '[MySuperWall] Prepared paywall for "$triggerKey" was still not ready after waiting. Falling back to route presentation.',
          );
          final paywall = result.paywall!;
          final preparedRouteController = await _prepareRouteController(result);
          if (_cacheScope != scope) {
            preparedRouteController.dispose();
            return const PaywallResult(
              show: false,
              paywall: null,
              reason: 'identity_changed',
            );
          }
          _presentRoutePaywall(
            context,
            triggerKey: triggerKey,
            paywall: paywall,
            preparedController: preparedRouteController,
            disposeProvidedPreparedController: true,
            onPurchase: onPurchase,
            onRestore: onRestore,
            onDismiss: onDismiss,
            onOpenUrl: onOpenUrl,
            onOpenTerms: onOpenTerms,
            onOpenPrivacy: onOpenPrivacy,
          );
        }
      } else {
        final paywall = result.paywall!;
        final preparedRouteController = await _prepareRouteController(result);
        if (_cacheScope != scope) {
          preparedRouteController.dispose();
          return const PaywallResult(
            show: false,
            paywall: null,
            reason: 'identity_changed',
          );
        }
        _presentRoutePaywall(
          context,
          triggerKey: triggerKey,
          paywall: paywall,
          preparedController: preparedRouteController,
          disposeProvidedPreparedController: true,
          onPurchase: onPurchase,
          onRestore: onRestore,
          onDismiss: onDismiss,
          onOpenUrl: onOpenUrl,
          onOpenTerms: onOpenTerms,
          onOpenPrivacy: onOpenPrivacy,
        );
      }

      return result;
    } catch (e) {
      if (e is MySuperWallException) {
        _logger.e('[MySuperWall] ${e.toString()}');
        rethrow;
      }
      final error = 'Failed to trigger paywall: $e';
      _logger.e('[MySuperWall] $error');
      throw MySuperWallException(
        error,
        code: 'trigger_execution_failed',
        details: {'triggerKey': triggerKey},
      );
    }
  }

  String? _extractTermsUrl(PaywallData paywall) {
    final value = paywall.contentJson['termsUrl']?.toString().trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  String? _extractPrivacyUrl(PaywallData paywall) {
    final value = paywall.contentJson['privacyUrl']?.toString().trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  void _bindFollowUp(
    BuildContext context,
    PaywallData paywall, {
    Map<String, dynamic>? metadata,
    required int depth,
    required List<String> visited,
    String? legacyPaywallId,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) {
    _followUpPaywall = paywall;
    _followUpOutcomePaywallId = null;
    final generation = _flowGeneration;
    final scope = _cacheScope;
    final seen = [...visited, paywall.id];
    bool valid() =>
        identical(_followUpPaywall, paywall) &&
        generation == _flowGeneration &&
        scope == _cacheScope &&
        context.mounted;
    final followUpRules = paywall.contentJson['followUpRules'];
    _followUpEvent = (event, sourcePaywallId) {
      if (!valid() ||
          sourcePaywallId != paywall.id ||
          _automationActionHandler != null) {
        return;
      }
      if (event == 'onDismiss' && _followUpOutcomePaywallId == paywall.id) {
        return;
      }
      if (event == 'onPurchase' ||
          event == 'onRestore' ||
          event == 'onPurchaseFailed') {
        _followUpOutcomePaywallId = paywall.id;
      }
      final raw = followUpRules is Map ? followUpRules[event] : null;
      final explicit =
          raw is Map<String, dynamic> &&
          raw['enabled'] == true &&
          (raw['actionType'] ?? 'trigger') == 'trigger' &&
          (raw['triggerKey']?.toString().trim().isNotEmpty ?? false);
      final legacy =
          legacyPaywallId ??
          paywall.contentJson['followUpPaywallId']?.toString();
      if (!explicit &&
          (event != 'onDismiss' ||
              depth != 0 ||
              (legacy != null && seen.contains(legacy)))) {
        return;
      }
      final rule = explicit
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{
              'enabled': true,
              'actionType': 'trigger',
              'triggerKey': 'legacy',
              'maxChainDepth': 1,
            };
      _followUps.schedule(
        key: '${paywall.id}:$event:${rule['triggerKey']}',
        rule: rule,
        depth: depth,
        premium: _subscriptionPremium,
        run: () async {
          if (!valid() ||
              (rule['skipIfPremium'] == true && _subscriptionPremium)) {
            return;
          }
          if (explicit) {
            final nextKey = rule['triggerKey'].toString();
            final manifest = _manifestService?.manifest;
            final nextTrigger = manifest?.findTrigger(nextKey);
            if (manifest != null &&
                nextTrigger != null &&
                rule['preventRepeatPaywall'] != false) {
              final resolution = LocalRuleEngine().resolveTrigger(
                trigger: nextTrigger,
                userId: _userId,
                context: {
                  'platform': Platform.isIOS ? 'ios' : 'android',
                  'country': _country ?? _deviceCountry,
                  'metadata': metadata ?? <String, dynamic>{},
                  'userAttributes': metadata ?? <String, dynamic>{},
                },
              );
              if (seen.contains(resolution.paywallId)) return;
            }
            dismiss();
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!valid()) return;
            await _handleTrigger(
              context,
              triggerKey: nextKey,
              metadata: metadata,
              followUpDepth: depth + 1,
              followUpVisited: seen,
              preventFollowUpRepeat: rule['preventRepeatPaywall'] != false,
              onPurchase: onPurchase,
              onRestore: onRestore,
              onDismiss: onDismiss,
              onOpenUrl: onOpenUrl,
              onOpenTerms: onOpenTerms,
              onOpenPrivacy: onOpenPrivacy,
            );
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (!valid()) return;
            if (_manifestService?.manifest == null) {
              await _syncManifestInBackground();
            }
            if (!valid()) return;
            final resolvedLegacy =
                legacy ??
                _manifestService?.manifest
                    ?.findTrigger(paywall.triggerKey)
                    ?.dismissFollowUpPaywallId;
            if (resolvedLegacy == null || seen.contains(resolvedLegacy)) return;
            final next = _manifestService?.manifest?.paywalls[resolvedLegacy];
            if (next == null) return;
            final result = next.toPaywallResult(
              triggerKey: paywall.triggerKey,
              appKey: paywall.appKey,
            );
            final controller = await _prepareRouteController(result);
            if (!valid()) {
              controller.dispose();
              return;
            }
            _bindFollowUp(
              context,
              result.paywall!,
              metadata: metadata,
              depth: depth + 1,
              visited: seen,
              onPurchase: onPurchase,
              onRestore: onRestore,
              onDismiss: onDismiss,
              onOpenUrl: onOpenUrl,
              onOpenTerms: onOpenTerms,
              onOpenPrivacy: onOpenPrivacy,
            );
            _presentRoutePaywall(
              context,
              triggerKey: paywall.triggerKey,
              paywall: result.paywall!,
              preparedController: controller,
              disposeProvidedPreparedController: true,
              onPurchase: onPurchase,
              onRestore: onRestore,
              onDismiss: onDismiss,
              onOpenUrl: onOpenUrl,
              onOpenTerms: onOpenTerms,
              onOpenPrivacy: onOpenPrivacy,
            );
          }
        },
      );
    };
  }

  /// Call only after the host billing provider confirms restored entitlement.
  void trackRestoreSuccess({required String paywallId}) {
    final paywall = _followUpPaywall;
    if (paywall == null || paywall.id != paywallId) return;
    _followUpEvent?.call('onRestore', paywallId);
    _trackDisplayedEvent('restore_success', paywall, paywall.triggerKey);
  }

  void setAutomationActionHandler(
    Future<void> Function(MySuperWallAutomationAction action)? handler,
  ) {
    _automationActionHandler = handler;
  }

  MySuperWallAutomationAction? _extractAutomationAction(
    Map<String, dynamic> payload,
  ) {
    final raw = payload['nextAction'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }

    final action = MySuperWallAutomationAction.fromJson(raw);
    return action.isTriggerAction ? action : null;
  }

  void _dispatchAutomationAction(MySuperWallAutomationAction action) {
    final handler = _automationActionHandler;
    if (handler == null) {
      return;
    }
    unawaited(handler(action));
  }

  void _trackDisplayedEvent(
    String type,
    PaywallData paywall,
    String triggerKey,
  ) {
    _eventQueue?.enqueue({
      'type': type,
      'userId': _userId,
      'triggerKey': triggerKey,
      'paywallId': paywall.id,
      'paywallName': paywall.name,
      'abVariant': paywall.abVariant,
      if (paywall.experimentContext != null)
        'experimentContext': paywall.experimentContext,
    });
    unawaited(_flushEventQueue());
  }

  void _rememberPurchaseContext({
    required String productId,
    String? paywallId,
    String? triggerKey,
    String? abVariant,
    Map<String, dynamic>? experimentContext,
  }) {
    _purchaseContexts[productId.trim()] = {
      'productId': productId,
      if (paywallId != null) 'paywallId': paywallId,
      if (triggerKey != null) 'triggerKey': triggerKey,
      if (abVariant != null) 'abVariant': abVariant,
      if (experimentContext != null)
        'experimentContext': Map<String, dynamic>.from(experimentContext),
      'createdAt': DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _resolvePurchaseContext({
    required String productId,
    String? paywallId,
    String? triggerKey,
  }) {
    final latest = _purchaseContexts[productId.trim()];
    final hasMatchingLatestProduct =
        latest != null &&
        latest['productId']?.toString().trim() == productId.trim();

    return {
      'productId': productId,
      'paywallId':
          paywallId ??
          (hasMatchingLatestProduct ? latest['paywallId']?.toString() : null),
      'triggerKey':
          triggerKey ??
          (hasMatchingLatestProduct ? latest['triggerKey']?.toString() : null),
      'abVariant': hasMatchingLatestProduct
          ? latest['abVariant']?.toString()
          : null,
      'experimentContext':
          hasMatchingLatestProduct &&
              (paywallId == null || paywallId == latest['paywallId']) &&
              (triggerKey == null || triggerKey == latest['triggerKey'])
          ? latest['experimentContext']
          : null,
    };
  }

  Future<void> _trackPurchaseEvent({
    required String eventType,
    required String productId,
    String? paywallId,
    double? revenueUsd,
    String? triggerKey,
    String? errorMessage,
    Map<String, dynamic>? metadata,
  }) async {
    Map<String, dynamic>? pendingEvent;
    try {
      final eventUserId = _userId;
      if (eventUserId == null) return;
      final purchaseContext = _resolvePurchaseContext(
        productId: productId,
        paywallId: paywallId,
        triggerKey: triggerKey,
      );
      final followUpEvent = <String, String>{
        'purchase': 'onPurchase',
        'purchase_success': 'onPurchase',
        'purchase_failed': 'onPurchaseFailed',
        'restore': 'onRestore',
        'restore_success': 'onRestore',
      }[eventType];
      if (followUpEvent != null) {
        _followUpEvent?.call(
          followUpEvent,
          purchaseContext['paywallId']?.toString(),
        );
      }
      final appInfo = await PackageInfo.fromPlatform();
      final systemMetadata = await _getSystemMetadata();

      final body = {
        if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
        if (Platform.isIOS) 'bundleId': appInfo.packageName,
        if (Platform.isAndroid) 'packageName': appInfo.packageName,
        'type': eventType,
        'eventId': const Uuid().v4(),
        if (purchaseContext['experimentContext'] != null)
          'experimentContext': purchaseContext['experimentContext'],
        'userId': eventUserId,
        'productId': productId,
        if (purchaseContext['paywallId'] != null)
          'paywallId': purchaseContext['paywallId'],
        if (revenueUsd != null) 'revenueUsd': revenueUsd,
        if (purchaseContext['triggerKey'] != null)
          'triggerKey': purchaseContext['triggerKey'],
        if (errorMessage != null && errorMessage.trim().isNotEmpty)
          'errorMessage': errorMessage.trim(),
        'platform': Platform.isIOS ? 'ios' : 'android',
        'appVersion': appInfo.version,
        'metadata': {
          ...systemMetadata,
          if (purchaseContext['abVariant'] != null)
            'ab_variant': purchaseContext['abVariant'],
          ...?metadata,
        },
      };

      pendingEvent = body;
      final response = await _httpClient
          .post(
            Uri.parse('${baseUrl}paywall/purchase'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _eventQueue?.enqueue(body);
        return;
      }
      final payload = _decodeJsonMap(response.body);
      if (payload['analyticsRecorded'] == false) {
        _eventQueue?.enqueue(body);
      }
      final automationAction = _extractAutomationAction(payload);
      if (automationAction != null) {
        _dispatchAutomationAction(automationAction);
      }
    } catch (e) {
      if (pendingEvent != null) _eventQueue?.enqueue(pendingEvent);
      _logger.e('[MySuperWall] Purchase tracking error: $e');
    }
  }

  /// Sends a purchase-started event to the backend.
  Future<void> trackPurchase({
    required String productId,
    String? paywallId,
    double? revenueUsd,
    String? triggerKey,
  }) async {
    await _trackPurchaseEvent(
      eventType: 'purchase_started',
      productId: productId,
      paywallId: paywallId,
      revenueUsd: revenueUsd,
      triggerKey: triggerKey,
    );
  }

  /// Tracks reported analytics, and verifies a completed store purchase when
  /// proof is supplied. Verification failure never changes the billing result.
  Future<void> trackPurchaseSuccess({
    required String productId,
    String? paywallId,
    double? revenueUsd,
    String? triggerKey,
    Map<String, dynamic>? metadata,
    StorePurchaseProof? proof,
    void Function(PurchaseVerificationResult result)? onVerification,
  }) async {
    await _trackPurchaseEvent(
      eventType: 'purchase_success',
      productId: productId,
      paywallId: paywallId,
      revenueUsd: revenueUsd,
      triggerKey: triggerKey,
      metadata: metadata,
    );
    if (proof == null) return;
    final result = await verifyPurchase(productId: productId, proof: proof);
    onVerification?.call(result);
  }

  /// Reverify a purchase without creating another SDK analytics event.
  Future<PurchaseVerificationResult> verifyPurchase({
    required String productId,
    required StorePurchaseProof proof,
  }) {
    return PurchaseVerificationService(
      client: _httpClient,
      baseUrl: baseUrl,
      timeout: timeout,
    ).verify(appKey: appKey ?? '', productId: productId, proof: proof);
  }

  Future<void> trackPurchaseFailed({
    required String productId,
    String? paywallId,
    String? triggerKey,
    String? errorMessage,
    Map<String, dynamic>? metadata,
  }) async {
    await _trackPurchaseEvent(
      eventType: 'purchase_failed',
      productId: productId,
      paywallId: paywallId,
      triggerKey: triggerKey,
      errorMessage: errorMessage,
      metadata: metadata,
    );
  }

  Future<void> trackPurchaseCancelled({
    required String productId,
    String? paywallId,
    String? triggerKey,
    Map<String, dynamic>? metadata,
  }) async {
    await _trackPurchaseEvent(
      eventType: 'purchase_cancelled',
      productId: productId,
      paywallId: paywallId,
      triggerKey: triggerKey,
      metadata: metadata,
    );
  }

  /// Sends a dismiss event to the backend.
  Future<void> trackDismiss({
    required String paywallId,
    String? triggerKey,
    int? duration,
    String? abVariant,
    Map<String, dynamic>? experimentContext,
  }) async {
    _followUpEvent?.call('onDismiss', paywallId);
    Map<String, dynamic>? pendingEvent;
    try {
      final eventUserId = _userId;
      if (eventUserId == null) return;

      final appInfo = await PackageInfo.fromPlatform();
      final systemMetadata = await _getSystemMetadata();

      final body = {
        if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
        if (Platform.isIOS) 'bundleId': appInfo.packageName,
        if (Platform.isAndroid) 'packageName': appInfo.packageName,
        'type': 'paywall_dismissed',
        'userId': eventUserId,
        'paywallId': paywallId,
        'eventId': const Uuid().v4(),
        if (experimentContext != null) 'experimentContext': experimentContext,
        if (triggerKey != null) 'triggerKey': triggerKey,
        if (duration != null) 'duration': duration,
        if (abVariant != null) 'abVariant': abVariant,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'appVersion': appInfo.version,
        'metadata': systemMetadata,
      };

      pendingEvent = body;
      final response = await _httpClient
          .post(
            Uri.parse('${baseUrl}paywall/dismiss'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _eventQueue?.enqueue(body);
        return;
      }
      final payload = _decodeJsonMap(response.body);
      if (payload['analyticsRecorded'] == false) {
        _eventQueue?.enqueue(body);
      }
      final automationAction = _extractAutomationAction(payload);
      if (automationAction != null) {
        _dispatchAutomationAction(automationAction);
      }
    } catch (e) {
      if (pendingEvent != null) _eventQueue?.enqueue(pendingEvent);
      _logger.e('[MySuperWall] Dismiss tracking error: $e');
    }
  }

  void dispose() {
    _httpClient.close();
  }

  /// Collects background system metadata automatically.
  Future<Map<String, dynamic>> _getSystemMetadata() async {
    String appVer = "unknown";
    try {
      final info = await PackageInfo.fromPlatform();
      appVer = info.version;
    } catch (_) {}

    final Map<String, dynamic> metadata = {
      'timestamp': DateTime.now().toIso8601String(),
      'p_os_version': Platform.operatingSystemVersion,
      'p_locale': Platform.localeName,
      'p_app_version': appVer,
    };

    // Internal metrics from Prefs
    if (_prefs != null) {
      try {
        final sessionCount = _prefs!.getInt('mysuperwall_session_count') ?? 1;
        final totalViews = _prefs!.getInt('mysuperwall_total_views') ?? 0;
        final installStr = _prefs!.getString('mysuperwall_install_date');

        metadata['p_session_count'] = sessionCount;
        metadata['p_total_views'] = totalViews;

        if (installStr != null) {
          final installDate = DateTime.parse(installStr);
          final days = DateTime.now().difference(installDate).inDays;
          metadata['p_days_since_install'] = days;
        }
      } catch (_) {}
    }

    try {
      // 1. Device Info
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        metadata['p_device_model'] = androidInfo.model;
        metadata['p_device_manufacturer'] = androidInfo.manufacturer;
        metadata['p_os_sdk'] = androidInfo.version.sdkInt;
        metadata['p_is_simulator'] = !androidInfo.isPhysicalDevice;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        metadata['p_device_model'] = iosInfo.utsname.machine;
        metadata['p_device_name'] = iosInfo.name;
        metadata['p_os_ver_ios'] = iosInfo.systemVersion;
        metadata['p_is_simulator'] = !iosInfo.isPhysicalDevice;
      }
    } catch (e) {
      _logger.w('[MySuperWall] Failed to collect full system metadata: $e');
    }

    return metadata;
  }
}
