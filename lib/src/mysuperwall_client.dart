import 'package:flutter/foundation.dart';
import 'models/paywall_state.dart';
import 'services/sdk_endpoint.dart';
import 'models/log_level.dart';
import 'services/sdk_logging.dart';
import 'services/paywall_diagnostic_policy.dart';
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
import 'services/lifecycle_history.dart';
import 'services/follow_up_service.dart';
import 'services/pending_follow_up_service.dart';
import 'services/offline_event_queue.dart';
import 'ui/paywall_view.dart';
import 'ui/paywall_session.dart';

/// The core MySuperWall SDK client.
class MySuperWallClient {
  static MySuperWallClient? _instance;
  static int _hostMountCount = 0;
  static const String _sdkValidationCacheKey =
      'mysuperwall_sdk_validation_cache';
  static const String _paywallCacheSchemaVersionKey =
      'mysuperwall_paywall_cache_schema_version';
  static const String _preparedPreferredTriggersCacheKey =
      'mysuperwall_prepared_preferred_triggers';
  static const String _preparedExcludedTriggersCacheKey =
      'mysuperwall_prepared_excluded_triggers';
  static const int _paywallCacheSchemaVersion = 3;
  final String? appKey; // Optional if package identifier is used
  String? _userId; // Centralized user ID
  String? _locale = Platform.localeName.replaceAll('_', '-').toLowerCase();
  String? _country;
  bool _subscriptionPremium = false;
  final FollowUpService _followUps = FollowUpService();
  int _flowGeneration = 0;
  PaywallData? _followUpPaywall;
  String? _followUpOutcomePaywallId;
  String? _restoreRequestPaywallId;
  int? _restoreRequestGeneration;
  void Function(String event, String? paywallId)? _followUpEvent;

  /// Pass the host billing provider's current entitlement; never inferred from taps.
  void setSubscriptionStatus(bool premium) {
    _subscriptionPremium = premium;
    if (premium) unawaited(_cancelPendingPurchasedOffers());
  }

  final ValueNotifier<Map<String, MySuperWallPaywallState>> _paywallStates =
      ValueNotifier(const {});

  /// Listen for lifecycle changes without modifying SDK state.
  ValueListenable<Map<String, MySuperWallPaywallState>> get paywallStates =>
      _paywallStates;

  MySuperWallPaywallState paywallStateFor(String triggerKey) =>
      _paywallStates.value[triggerKey] ?? MySuperWallPaywallState.idle;

  void _updatePaywallState(String triggerKey, MySuperWallPaywallState state) {
    if (_disposed || paywallStateFor(triggerKey) == state) return;
    _paywallStates.value = Map.unmodifiable({
      ..._paywallStates.value,
      triggerKey: state,
    });
  }

  bool _disposed = false;
  bool _presentationInProgress = false;
  bool get _hasActivePresentation =>
      _presentationInProgress ||
      _activePreparedTriggerKey.value != null ||
      PaywallView.isShowing;

  final http.Client _httpClient;
  final Duration timeout;
  final bool failOpenOnNetworkError;
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
  final Map<String, DateTime> _pendingLifecycleDates = {};
  bool _handlingLifecycleTriggers = false;
  bool _presentationHandlersExplicit = false;
  WeakReference<BuildContext>? _presentationHandlerOwner;
  ValueChanged<String>? _presentationPurchase;
  VoidCallback? _presentationRestore;
  ValueChanged<String>? _presentationOpenUrl;
  ValueChanged<String?>? _presentationOpenTerms;
  ValueChanged<String?>? _presentationOpenPrivacy;

  /// Registers app-level billing handlers shared by manual and automatic paywalls.
  /// Existing presentation calls also register their supplied handlers.
  void setPresentationHandlers({
    required ValueChanged<String> onPurchase,
    VoidCallback? onRestore,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) {
    if (_disposed) return;
    _presentationHandlersExplicit = true;
    _presentationHandlerOwner = null;
    _presentationPurchase = onPurchase;
    _presentationRestore = onRestore;
    _presentationOpenUrl = onOpenUrl;
    _presentationOpenTerms = onOpenTerms;
    _presentationOpenPrivacy = onOpenPrivacy;
  }

  bool get hasPresentationHandlers {
    if (!_presentationHandlersExplicit &&
        !(_presentationHandlerOwner?.target?.mounted ?? false)) {
      // Inferred screen callbacks may retain State objects; release the whole
      // bundle as soon as its owning context is no longer usable.
      _presentationHandlerOwner = null;
      _presentationPurchase = null;
      _presentationRestore = null;
      _presentationOpenUrl = null;
      _presentationOpenTerms = null;
      _presentationOpenPrivacy = null;
    }
    return !_disposed && _presentationPurchase != null;
  }

  void _rememberPresentationHandlers({
    required BuildContext? owner,
    ValueChanged<String>? onPurchase,
    VoidCallback? onRestore,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) {
    if (_disposed ||
        _presentationHandlersExplicit ||
        owner == null ||
        !owner.mounted ||
        onPurchase == null ||
        identical(onPurchase, _presentationPurchase)) {
      return;
    }
    // Keep one coherent bundle. Never combine restore/link callbacks from
    // a different screen with a newly supplied purchase handler.
    final weakOwner = WeakReference(owner);
    bool valid() => weakOwner.target?.mounted ?? false;
    _presentationHandlerOwner = weakOwner;
    _presentationPurchase = (id) {
      if (valid()) onPurchase(id);
    };
    _presentationRestore = onRestore == null
        ? null
        : () {
            if (valid()) onRestore();
          };
    _presentationOpenUrl = onOpenUrl == null
        ? null
        : (url) {
            if (valid()) onOpenUrl(url);
          };
    _presentationOpenTerms = onOpenTerms == null
        ? null
        : (url) {
            if (valid()) onOpenTerms(url);
          };
    _presentationOpenPrivacy = onOpenPrivacy == null
        ? null
        : (url) {
            if (valid()) onOpenPrivacy(url);
          };
  }

  DateTime? _lifecycleActiveSince;
  DateTime? _lifecycleBackgroundSince;
  // One prepared paywall by default, so MySuperWallHost keeps the preferred
  // trigger warm and handleTrigger presents it without rebuilding a WebView.
  // configurePreparedPaywallPool(maxCount: 0) opts out.
  int _maxPreparedPaywalls = 1;
  static final ValueNotifier<int> _preparedPoolVersion = ValueNotifier<int>(0);
  static final ValueNotifier<String?> _activePreparedTriggerKey =
      ValueNotifier<String?>(null);
  static final ValueNotifier<bool> _hostLoadingOverlayVisible =
      ValueNotifier<bool>(false);
  static Route<void>? _preparedBackInterceptorRoute;
  static NavigatorState? _preparedBackInterceptorNavigator;

  static final Logger _logger = MySuperWallLogging.createLogger(
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

  static final Map<Object, BuildContext? Function()> _hostContextProviders = {};

  /// Internal host bridge for prepared presentations that omit a context.
  static void registerHostContextProvider(
    Object host,
    BuildContext? Function()? provider,
  ) {
    if (provider == null) {
      _hostContextProviders.remove(host);
    } else {
      _hostContextProviders[host] = provider;
    }
  }

  BuildContext? _followUpContext(BuildContext? supplied) {
    if (supplied != null && supplied.mounted) return supplied;
    for (final provider in _hostContextProviders.values) {
      final context = provider();
      if (context != null && context.mounted) return context;
    }
    return null;
  }

  static void registerHostMounted(bool mounted) {
    if (mounted) {
      _hostMountCount++;
    } else {
      _hostMountCount = (_hostMountCount - 1).clamp(0, 1 << 20);
    }

    if (_hostMountCount == 0) {
      final activeKey = _activePreparedTriggerKey.value;
      if (activeKey != null) {
        _instance?._preparedPaywallPool[activeKey]?.deactivate();
      }
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

      if (_excludedPreparedTriggerKeys.contains(triggerKey)) continue;
      final result = await _refreshTriggerDecision(triggerKey: triggerKey);
      if (!result.show || result.paywall == null) {
        continue;
      }

      await _preparePaywallController(triggerKey, result);
    }
  }

  /// Loads the paywall for [triggerKey] and keeps it prepared, so presenting it
  /// right after is instant instead of showing a blank page while its web view
  /// loads. Use it before presenting a trigger that is not part of your usual
  /// prepared set, for example the one a push notification points at. Returns
  /// false when the trigger has no paywall to show.
  Future<bool> prepareTrigger(String triggerKey) async {
    final result = await prefetchPaywall(
      triggerKey: triggerKey,
      logNoPaywallResult: false,
    );
    if (!result.show) return false;
    await warmPreparedPaywalls(preferredTriggerKeys: [triggerKey]);
    return true;
  }

  void clearPreparedPaywallPool({List<String>? triggerKeys}) {
    if (triggerKeys != null && triggerKeys.isEmpty) return;
    final activeKey = _activePreparedTriggerKey.value;
    if (activeKey != null &&
        (triggerKeys == null || triggerKeys.contains(activeKey))) {
      dismissPreparedPaywall();
    }
    if (triggerKeys == null) {
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

  /// Changes logging immediately for all SDK components.
  static void setLogLevel(MySuperWallLogLevel level) {
    MySuperWallLogging.level = level;
  }

  static MySuperWallLogLevel get logLevel => MySuperWallLogging.level;

  /// Initializes the MySuperWall SDK instance.
  static Future<MySuperWallClient> initialize({
    String? appKey,
    String? userId,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 8),
    bool failOpenOnNetworkError = true,
    MySuperWallLogLevel logLevel = MySuperWallLogLevel.warning,
    String? locale,
  }) async {
    setLogLevel(logLevel);
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
        appKey: appKey,
        userId: userId,
        httpClient: httpClient,
        timeout: requestTimeout,
        failOpenOnNetworkError: failOpenOnNetworkError,
      );
      client._prefs = prefs;
      // Set the paywall language before anything is cached: changing it later
      // with setLocale clears the manifest and every prepared paywall.
      final initialLocale = locale?.trim().replaceAll('_', '-').toLowerCase();
      if (initialLocale != null && initialLocale.isNotEmpty) {
        client._locale = initialLocale;
      }
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
      unawaited(client._syncManifestInBackground().then<void>((_) {}));

      // Manage internal metrics
      await client._updateInternalMetrics(prefs);
      // Compute which lifecycle triggers apply this session
      try {
        await client._computeLifecycleTriggers(prefs);
      } catch (error) {
        _logger.w('[MySuperWall] Lifecycle initialization deferred: $error');
      }

      // A token saved by an earlier session is refreshed at most once a day.
      unawaited(client._syncPushToken());

      _instance?.dispose();
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
            Uri.parse('${sdkServiceUrl}paywall/sdk-init'),
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

  Future<bool> _syncManifestInBackground({bool requireFresh = false}) async {
    try {
      final appInfo = await PackageInfo.fromPlatform();
      if (_disposed) return false;
      final manifest = await _manifestService?.fetchManifest(
        baseUrl: sdkServiceUrl,
        scope: _cacheScope,
        appKey: appKey,
        bundleId: Platform.isIOS ? appInfo.packageName : null,
        packageName: Platform.isAndroid ? appInfo.packageName : null,
        platform: Platform.isIOS ? 'ios' : 'android',
        appVersion: appInfo.version,
        lang: _locale,
        substitutionData: _productData,
        timeout: timeout,
        allowCachedOnError: !requireFresh,
      );
      return !_disposed && manifest != null;
    } catch (e) {
      _logger.d('[MySuperWall] Background manifest sync error: $e');
      return false;
    }
  }

  Future<void> _flushEventQueue() async {
    try {
      final appInfo = await PackageInfo.fromPlatform();
      if (_disposed) return;
      await _eventQueue?.flush(
        baseUrl: sdkServiceUrl,
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
    await _recordLifecycleHistory(prefs);
    // 1. Session Count
    final sessionCount = (prefs.getInt('mysuperwall_session_count') ?? 0) + 1;
    await prefs.setInt('mysuperwall_session_count', sessionCount);
    await _recordLifecycleHistory(prefs);

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
  final Map<String, String> _lifecycleDiagnosticStates = {};

  void _reportLifecycleStatus(String key, String status, String reason) {
    final signature = '$status:$reason';
    if (_disposed || _lifecycleDiagnosticStates[key] == signature) return;
    _lifecycleDiagnosticStates[key] = signature;
    _eventQueue?.enqueue({
      'type': 'lifecycle_status',
      'userId': _userId,
      'triggerKey': key,
      'metadata': {
        'lifecycle_status': status,
        'reason': reason,
        if (_pendingLifecycleDates[key] != null)
          'occurred_at': _pendingLifecycleDates[key]?.toIso8601String(),
      },
    });
  }

  /// Reports why automatic lifecycle presentation is currently deferred.
  void reportLifecycleWaiting(String reason) {
    for (final key in _pendingLifecycleTriggers) {
      _reportLifecycleStatus(key, 'pending', reason);
    }
    unawaited(_flushEventQueue());
  }

  LifecycleHistory _lifecycleHistory(SharedPreferences prefs) =>
      LifecycleHistory(prefs, '${_lifecycleQueueKey}_history');

  bool _lifecycleHistoryHealthy = true;

  Future<void> _recordLifecycleHistory(
    SharedPreferences prefs, {
    bool boundary = false,
  }) async {
    try {
      await _lifecycleHistory(prefs).record(
        DateTime.now().toUtc(),
        prefs.getInt('mysuperwall_session_count') ?? 0,
        prefs.getInt('mysuperwall_active_seconds') ?? 0,
        boundary: boundary,
      );
      _lifecycleHistoryHealthy = true;
    } catch (error) {
      _lifecycleHistoryHealthy = false;
      _logger.w('[MySuperWall] Lifecycle history unavailable: $error');
    }
  }

  String get _lifecycleQueueKey =>
      'mysuperwall_lifecycle_queue_${base64Url.encode(utf8.encode(jsonEncode([sdkServiceUrl, appKey])))}';

  Future<void> _saveLifecycleQueue() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final saved = await prefs.setString(
      _lifecycleQueueKey,
      jsonEncode({
        for (final entry in _pendingLifecycleDates.entries)
          entry.key: entry.value.toUtc().toIso8601String(),
      }),
    );
    if (!saved) throw StateError('Lifecycle queue could not be persisted');
  }

  Future<void> _computeLifecycleTriggers(SharedPreferences prefs) async {
    _pendingLifecycleTriggers.clear();
    _pendingLifecycleDates.clear();
    final now = DateTime.now().toUtc();
    try {
      final raw = prefs.getString(_lifecycleQueueKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final date = DateTime.tryParse(entry.value.toString())?.toUtc();
          if (entry.key is String &&
              date != null &&
              !date.isAfter(now) &&
              now.difference(date) <= const Duration(days: 30)) {
            _pendingLifecycleDates[entry.key as String] = date;
          }
        }
      }
    } catch (e) {
      _logger.w('[MySuperWall] Invalid lifecycle queue: $e');
    }

    void enqueue(String key) {
      _pendingLifecycleDates.putIfAbsent(key, () => now);
    }

    final sessionCount = prefs.getInt('mysuperwall_session_count') ?? 1;
    final installStr = prefs.getString('mysuperwall_install_date');
    final installDate = installStr == null
        ? null
        : DateTime.tryParse(installStr);
    final daysSince = installDate == null
        ? 0
        : now.difference(installDate.toUtc()).inDays;
    String? appVersion;
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (e) {
      _logger.w('[MySuperWall] Could not read app version: $e');
    }

    // Older SDK versions set these flags before attempting presentation. Keep
    // them as migration markers to avoid replaying already processed events.
    if (!prefs.containsKey('mysuperwall_lc_install_fired')) {
      enqueue('mysuperwall.install');
      await _saveLifecycleQueue();
      await prefs.setBool('mysuperwall_lc_install_fired', true);
    }
    final lastVersion = prefs.getString('mysuperwall_last_known_version');
    if (appVersion != null && appVersion.isNotEmpty) {
      if (lastVersion != null &&
          lastVersion != 'unknown' &&
          lastVersion != appVersion) {
        enqueue('mysuperwall.update');
        await _saveLifecycleQueue();
      }
      await prefs.setString('mysuperwall_last_known_version', appVersion);
    }
    _pendingLifecycleTriggers.add('mysuperwall.session');
    for (final milestone in [3, 5, 10, 20, 50]) {
      final marker = 'mysuperwall_lc_session${milestone}_fired';
      if (_lifecycleHistoryHealthy &&
          sessionCount >= milestone &&
          !prefs.containsKey(marker)) {
        final occurred = _lifecycleHistory(
          prefs,
        ).crossing(session: true, threshold: milestone);
        if (occurred != null &&
            now.difference(occurred) <= const Duration(days: 30)) {
          _pendingLifecycleDates.putIfAbsent(
            'mysuperwall.session_$milestone',
            () => occurred,
          );
          await _saveLifecycleQueue();
        }
        await prefs.setBool(marker, true);
      }
    }
    for (final day in [1, 3, 7, 14, 30]) {
      final marker = 'mysuperwall_lc_day${day}_fired';
      if (daysSince >= day && !prefs.containsKey(marker)) {
        final occurred = installDate?.toUtc().add(Duration(days: day));
        if (occurred != null &&
            now.difference(occurred) <= const Duration(days: 30)) {
          _pendingLifecycleDates.putIfAbsent(
            'mysuperwall.day_$day',
            () => occurred,
          );
          await _saveLifecycleQueue();
        }
        await prefs.setBool(marker, true);
      }
    }
    // Durable one-time events are checked before the recurring session event.
    _pendingLifecycleTriggers.insertAll(0, _pendingLifecycleDates.keys);
    for (final key in _pendingLifecycleTriggers) {
      _reportLifecycleStatus(key, 'received', 'sdk_initialized');
    }
    await _saveLifecycleQueue();
  }

  /// Collects automatic lifecycle signals and refreshes configured thresholds.
  /// Active time excludes time spent in the background.
  Future<void> updateLifecycleSignals({
    bool foreground = false,
    bool background = false,
  }) async {
    final prefs = _prefs;
    if (prefs == null || _disposed) return;
    final now = DateTime.now().toUtc();
    final previousBackground = foreground ? _lifecycleBackgroundSince : null;
    if (foreground) _lifecycleBackgroundSince = null;
    final started = _lifecycleActiveSince;
    final elapsed = started == null ? 0 : now.difference(started).inSeconds;
    if (background) {
      _lifecycleActiveSince = null;
      _lifecycleBackgroundSince ??= now;
    } else {
      // Commit each active interval before awaiting I/O. A lifecycle transition
      // during manifest fetching must not count background time as active.
      _lifecycleActiveSince = now;
    }
    if (elapsed > 0) {
      await prefs.setInt(
        'mysuperwall_active_seconds',
        (prefs.getInt('mysuperwall_active_seconds') ?? 0) + elapsed,
      );
    }
    await _recordLifecycleHistory(
      prefs,
      boundary: background || foreground || started == null,
    );
    if (background) return;
    if (foreground) {
      _foregroundSequence++;
      if (!_pendingLifecycleTriggers.contains('mysuperwall.foreground')) {
        _pendingLifecycleTriggers.add('mysuperwall.foreground');
      }
      final backgroundSince = previousBackground;
      if (backgroundSince != null &&
          now.difference(backgroundSince) >= const Duration(minutes: 30)) {
        await prefs.setInt(
          'mysuperwall_session_count',
          (prefs.getInt('mysuperwall_session_count') ?? 0) + 1,
        );
        if (!_pendingLifecycleTriggers.contains('mysuperwall.session')) {
          _pendingLifecycleTriggers.add('mysuperwall.session');
        }
      }
    }
    await _recordLifecycleHistory(prefs);
    if (!_lifecycleHistoryHealthy) return;
    final scope = _cacheScope;
    await _syncManifestInBackground(requireFresh: true);
    if (_disposed || scope != _cacheScope) return;
    final manifest = _manifestService?.manifest;
    if (manifest == null || _disposed) return;
    final install = DateTime.tryParse(
      prefs.getString('mysuperwall_install_date') ?? '',
    )?.toUtc();
    final sessions = prefs.getInt('mysuperwall_session_count') ?? 0;
    final activeSeconds = prefs.getInt('mysuperwall_active_seconds') ?? 0;
    final legacySessions = {3, 5, 10, 20, 50};
    final legacyDays = {1, 3, 7, 14, 30};
    for (final trigger in manifest.triggers) {
      final match = RegExp(
        r'^mysuperwall\.(session|day|active_minutes)_(\d+)$',
      ).firstMatch(trigger.key);
      if (match == null) continue;
      final kind = match.group(1);
      final threshold = int.tryParse(match.group(2) ?? '');
      if (threshold == null || threshold < 1 || threshold > 100000) continue;
      final reached = kind == 'session'
          ? sessions >= threshold
          : kind == 'day'
          ? install != null && now.difference(install).inDays >= threshold
          : activeSeconds >= threshold * 60;
      if (!reached) continue;
      final marker = kind == 'session' && legacySessions.contains(threshold)
          ? 'mysuperwall_lc_session${threshold}_fired'
          : kind == 'day' && legacyDays.contains(threshold)
          ? 'mysuperwall_lc_day${threshold}_fired'
          : 'mysuperwall_dynamic_${base64Url.encode(utf8.encode(trigger.key))}';
      if (prefs.containsKey(marker)) continue;
      final occurred = kind == 'day' && install != null
          ? install.add(Duration(days: threshold))
          : _lifecycleHistory(prefs).crossing(
              session: kind == 'session',
              threshold: kind == 'session' ? threshold : threshold * 60,
            );
      if (occurred != null &&
          now.difference(occurred) <= const Duration(days: 30)) {
        _pendingLifecycleDates.putIfAbsent(trigger.key, () => occurred);
        if (!_pendingLifecycleTriggers.contains(trigger.key)) {
          _pendingLifecycleTriggers.insert(0, trigger.key);
          _reportLifecycleStatus(trigger.key, 'received', 'threshold_reached');
        }
        await _saveLifecycleQueue();
      }
      if (occurred == null) {
        _reportLifecycleStatus(
          trigger.key,
          'rejected',
          'historical_timestamp_unavailable',
        );
      } else if (now.difference(occurred) > const Duration(days: 30)) {
        _reportLifecycleStatus(trigger.key, 'expired', 'retention_exceeded');
      }
      await prefs.setBool(marker, true);
    }
    unawaited(_flushEventQueue());
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
    bool Function()? canPresent,
  }) async {
    final useSharedHandlers = onPurchase == null && hasPresentationHandlers;
    if (useSharedHandlers) {
      onPurchase = _presentationPurchase;
      onRestore ??= _presentationRestore;
    }
    if (_handlingLifecycleTriggers || _disposed) return;
    _handlingLifecycleTriggers = true;
    try {
      // A host may remain alive for longer than the retention window.
      final now = DateTime.now().toUtc();
      final expired = _pendingLifecycleDates.entries
          .where(
            (entry) =>
                entry.value.isAfter(now) ||
                now.difference(entry.value) > const Duration(days: 30),
          )
          .map((entry) => entry.key)
          .toList();
      for (final key in expired) {
        _reportLifecycleStatus(key, 'expired', 'retention_exceeded');
        _pendingLifecycleDates.remove(key);
        _pendingLifecycleTriggers.remove(key);
      }
      if (expired.isNotEmpty) await _saveLifecycleQueue();
      // A built-in signal can exist without any configured trigger. Keep it
      // pending for future configuration, but do not request delivery or start
      // a presentation flow just to discover it is absent.
      if (_manifestService?.manifest == null &&
          !await _syncManifestInBackground(requireFresh: true)) {
        return;
      }
      final lifecycleManifest = _manifestService?.manifest;
      if (lifecycleManifest == null || _disposed) return;
      final ordered = List<String>.of(_pendingLifecycleTriggers)
        ..sort((a, b) {
          final manifest = _manifestService?.manifest;
          final priority = (manifest?.findTrigger(b)?.prewarmPriority ?? 0)
              .compareTo(manifest?.findTrigger(a)?.prewarmPriority ?? 0);
          if (priority != 0) return priority;
          final age = (_pendingLifecycleDates[a] ?? now).compareTo(
            _pendingLifecycleDates[b] ?? now,
          );
          return age != 0 ? age : a.compareTo(b);
        });
      for (final triggerKey in ordered) {
        if (!context.mounted || _disposed || canPresent?.call() == false) break;
        if (lifecycleManifest.findTrigger(triggerKey) == null) continue;
        try {
          final result = await handleTrigger(
            context,
            triggerKey: triggerKey,
            presentationGuard: canPresent,
            onPurchase: onPurchase,
            onRestore: onRestore,
            onDismiss: onDismiss,
            onOpenUrl: useSharedHandlers ? _presentationOpenUrl : null,
            onOpenTerms: useSharedHandlers ? _presentationOpenTerms : null,
            onOpenPrivacy: useSharedHandlers ? _presentationOpenPrivacy : null,
          );
          if (result.show) {
            // Completion is committed by the actual paywall_shown callback.
            _logger.i(
              '[MySuperWall] Lifecycle presentation started: $triggerKey',
            );
            break;
          }
          _reportLifecycleStatus(
            triggerKey,
            'pending',
            result.reason ?? 'no_match',
          );
          _logger.d(
            '[MySuperWall] Lifecycle trigger pending: $triggerKey (${result.reason})',
          );
          if (result.reason == 'presentation_in_progress' ||
              result.reason == 'identity_changed' ||
              result.reason == 'sdk_disposed' ||
              result.reason == 'presentation_deferred') {
            break;
          }
        } catch (e) {
          _reportLifecycleStatus(
            triggerKey,
            'pending',
            'presentation_or_network_failure',
          );
          _logger.w('[MySuperWall] Lifecycle trigger failed: $triggerKey — $e');
          break;
        }
      }
    } finally {
      _handlingLifecycleTriggers = false;
      unawaited(_flushEventQueue());
    }
  }

  // ── Prefetch Lifecycle Paywalls ─────────────────────────────────────────────

  /// Pre-fetches all pending lifecycle paywalls in the background.
  /// Pair with handleLifecycleTriggers() for instant display.
  Future<void> prefetchLifecycleTriggers() async {
    for (final triggerKey in List.of(_pendingLifecycleTriggers)) {
      if (_manifestService?.manifest?.findTrigger(triggerKey) == null) continue;
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
    unawaited(_syncPushToken());
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
    unawaited(_syncPushToken());
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

  String get _cacheScope =>
      jsonEncode([sdkServiceUrl, appKey, _userId, _locale]);

  void _clearIdentityState() {
    _flowGeneration++;
    _pendingOfferTimer?.cancel();
    _pendingOfferDisplay = null;
    _pendingOfferCallbacks.clear();
    _pendingOfferOwners.clear();
    _restoreRequestPaywallId = null;
    _restoreRequestGeneration = null;
    _followUps.reset();
    _followUpEvent = null;
    _followUpPaywall = null;
    _followUpOutcomePaywallId = null;
    _manifestService?.loadFromDisk(_cacheScope);
    unawaited(_syncManifestInBackground().then<void>((_) {}));
    _paywallCache.clear();
    _purchaseContexts.clear();
    clearPreparedPaywallPool();
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
  Future<void>? _preparedDismissal;

  void dismissPreparedPaywall() {
    if (_preparedDismissal != null) return;
    final activeKey = _activePreparedTriggerKey.value;
    if (activeKey == null) return;
    final controller = _preparedPaywallPool[activeKey];
    final animation = controller?.animateDismiss;
    if (animation == null || _disposed) {
      controller?.deactivate();
      _activePreparedTriggerKey.value = null;
      _removePreparedBackInterceptor();
      return;
    }
    _preparedDismissal = () async {
      try {
        await animation();
      } catch (error) {
        _logger.d('[MySuperWall] Dismiss transition interrupted: $error');
      } finally {
        if (_activePreparedTriggerKey.value == activeKey &&
            identical(_preparedPaywallPool[activeKey], controller)) {
          controller?.deactivate();
          _activePreparedTriggerKey.value = null;
          _removePreparedBackInterceptor();
        }
        _preparedDismissal = null;
      }
    }();
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
        return PopScope<void>(
          canPop:
              _preparedPaywallPool[triggerKey]
                  ?.paywall
                  .presentation
                  .allowsSystemBack ??
              false,
          child: const IgnorePointer(ignoring: true, child: SizedBox.expand()),
        );
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
          .get(Uri.parse('${sdkServiceUrl}health'))
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
    final diagnostic =
        '[MySuperWall] No paywall shown during $phase for trigger "$triggerKey". '
        'reason=$reason message=$message details=${result.details}';
    if (PaywallDiagnosticPolicy.isExpectedNoDisplay(result.reason)) {
      _logger.d(diagnostic);
    } else {
      _logger.e(diagnostic);
    }
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
    if (_disposed || _cacheScope != scope) return;
    final prepared = _preparedPaywallPool[triggerKey];
    if (prepared != null &&
        jsonEncode(prepared.paywall.toJson()) !=
            jsonEncode(result.paywall!.toJson())) {
      clearPreparedPaywallPool(triggerKeys: [triggerKey]);
    }
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
    if (_disposed || _cacheScope != scope) _clearIdentityState();
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
      onStateChanged: (state) =>
          _updatePaywallState(result.paywall!.triggerKey, state),
    );
    _preparedPaywallPool[triggerKey] = preparedController;
    _preparedPoolVersion.value++;
    await WidgetsBinding.instance.endOfFrame;
    try {
      await preparedController.warm();
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
      onStateChanged: (state) =>
          _updatePaywallState(result.paywall!.triggerKey, state),
    );
    await preparedController.warm();
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
      if (_disposed || _activePreparedTriggerKey.value == triggerKey) return;
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
          onShown: () {
            if (!_disposed &&
                presentationScope == _cacheScope &&
                _activePreparedTriggerKey.value == triggerKey &&
                isHostMounted) {
              _trackDisplayedEvent('paywall_shown', paywall, triggerKey);
            }
          },
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
              _restoreRequestPaywallId = paywall.id;
              _restoreRequestGeneration = _flowGeneration;
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
      _activePreparedTriggerKey.value = triggerKey;
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
    if (_disposed || PaywallView.isShowing) {
      if (disposeProvidedPreparedController) preparedController?.dispose();
      return;
    }
    final presentationScope = _cacheScope;
    PaywallView.show(
      context,
      paywall: paywall,
      trackDismissInternally: false,
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
          _restoreRequestPaywallId = paywall.id;
          _restoreRequestGeneration = _flowGeneration;
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
    _rememberPresentationHandlers(
      owner: presentationContext,
      onPurchase: onPurchase,
      onRestore: onRestore,
      onOpenUrl: onOpenUrl,
      onOpenTerms: onOpenTerms,
      onOpenPrivacy: onOpenPrivacy,
    );
    if (_disposed || _hasActivePresentation) return false;
    _presentationInProgress = true;
    try {
      if (!isHostMounted) {
        _logger.i(
          '[MySuperWall] Prepared presentation skipped for "$triggerKey": host not mounted.',
        );
        return false;
      }

      final result = await _refreshTriggerDecision(triggerKey: triggerKey);
      if (!result.show || result.paywall == null || _disposed) return false;

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

      _logger.i(
        '[MySuperWall] Presenting already-prepared paywall for trigger "$triggerKey".',
      );
      _flowGeneration++;
      _restoreRequestPaywallId = null;
      _restoreRequestGeneration = null;
      _followUps.cancel();
      _followUpEvent = null;
      _followUpPaywall = null;
      _followUpOutcomePaywallId = null;
      final followUpContext = _followUpContext(presentationContext);
      if (followUpContext != null) {
        _bindFollowUp(
          followUpContext,
          result.paywall!,
          depth: 0,
          visited: const [],
          legacyPaywallId: _manifestService?.manifest
              ?.findTrigger(triggerKey)
              ?.dismissFollowUpPaywallId,
          onPurchase: onPurchase,
          onRestore: onRestore,
          onDismiss: onDismiss,
          onOpenUrl: onOpenUrl,
          onOpenTerms: onOpenTerms,
          onOpenPrivacy: onOpenPrivacy,
        );
      } else {
        _logger.w(
          '[MySuperWall] Follow-up requires a mounted host or presentation context.',
        );
      }
      _incrementViewCount();
      await _presentPreparedPaywall(
        followUpContext,
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
    } finally {
      _presentationInProgress = false;
    }
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

      if (_disposed || _cacheScope != scope) {
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
      if (_disposed || _cacheScope != scope) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'identity_changed',
        );
      }
      return result;
    } catch (e) {
      _logger.w('[MySuperWall] Preload failed for $triggerKey: $e');
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
        'sdkCapabilities': ['deferred_follow_up_v1'],
      };

      final response = await _httpClient
          .post(
            Uri.parse('${sdkServiceUrl}paywall/prefetch-active'),
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

      if (_disposed || _cacheScope != scope) return {};
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
        if (_disposed || _cacheScope != scope) return {};
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
      if (_disposed || _cacheScope != scope) return {};
      final removed = _paywallCache.keys
          .where((key) => !results.containsKey(key))
          .toList(growable: false);
      for (final key in removed) {
        _paywallCache.remove(key);
      }
      clearPreparedPaywallPool(triggerKeys: removed);
      return results;
    } catch (error) {
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
    try {
      await PaywallCacheService(prefs).save(_cacheScope, key, result);
    } catch (error) {
      _logger.w('[MySuperWall] Disk save failed: $error');
    }
  }

  /// Cached HTML is reusable; permission to show must come from the server.
  /// A network failure must never resurrect a remotely disabled paywall.
  Future<PaywallResult> _refreshTriggerDecision({
    required String triggerKey,
    Map<String, dynamic>? metadata,
  }) async {
    final scope = _cacheScope;
    final result = await _fetchPaywallData(
      triggerKey: triggerKey,
      metadata: metadata,
    );
    if (_disposed || scope != _cacheScope) {
      return const PaywallResult(
        show: false,
        paywall: null,
        reason: 'identity_changed',
      );
    }
    if (!result.show || result.paywall == null) {
      clearPreparedPaywallPool(triggerKeys: [triggerKey]);
      _paywallCache[triggerKey] = result;
      await _saveToDisk(triggerKey, result);
      return result;
    }
    if (metadata == null || metadata.isEmpty) {
      await _cacheResolvedPaywall(triggerKey, result);
    } else {
      clearPreparedPaywallPool(triggerKeys: [triggerKey]);
    }
    if (_disposed || scope != _cacheScope) {
      return const PaywallResult(
        show: false,
        paywall: null,
        reason: 'identity_changed',
      );
    }
    return result;
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
      'sdkCapabilities': ['deferred_follow_up_v1'],
    };

    final response = await _httpClient
        .post(
          Uri.parse('${sdkServiceUrl}paywall'),
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
    bool Function()? presentationGuard,
  }) async {
    _rememberPresentationHandlers(
      owner: context,
      onPurchase: onPurchase,
      onRestore: onRestore,
      onOpenUrl: onOpenUrl,
      onOpenTerms: onOpenTerms,
      onOpenPrivacy: onOpenPrivacy,
    );
    if (_disposed || _hasActivePresentation) {
      return PaywallResult(
        show: false,
        paywall: null,
        reason: _disposed ? 'sdk_disposed' : 'presentation_in_progress',
      );
    }
    _presentationInProgress = true;
    try {
      _flowGeneration++;
      _restoreRequestPaywallId = null;
      _restoreRequestGeneration = null;
      _followUps.cancel();
      _followUpEvent = null;
      _followUpPaywall = null;
      _followUpOutcomePaywallId = null;
      return await _handleTrigger(
        context,
        triggerKey: triggerKey,
        presentationGuard: presentationGuard,
        metadata: metadata,
        onPurchase: onPurchase,
        onRestore: onRestore,
        onDismiss: onDismiss,
        onOpenUrl: onOpenUrl,
        onOpenTerms: onOpenTerms,
        onOpenPrivacy: onOpenPrivacy,
      );
    } finally {
      _presentationInProgress = false;
    }
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
    bool Function()? presentationGuard,
    int followUpDepth = 0,
    List<String> followUpVisited = const [],
    bool preventFollowUpRepeat = true,
  }) async {
    PaywallResult deferred() => const PaywallResult(
      show: false,
      paywall: null,
      reason: 'presentation_deferred',
    );
    if (presentationGuard?.call() == false) return deferred();
    final scope = _cacheScope;
    _updatePaywallState(triggerKey, MySuperWallPaywallState.loading);
    try {
      final manifestTrigger = _manifestService?.manifest?.findTrigger(
        triggerKey,
      );
      final result = await _refreshTriggerDecision(
        triggerKey: triggerKey,
        metadata: metadata,
      );

      if (!result.show || result.paywall == null) {
        _logNoPaywallResult(triggerKey, result, phase: 'handleTrigger');
        return result;
      }

      if (_disposed || _cacheScope != scope) {
        return const PaywallResult(
          show: false,
          paywall: null,
          reason: 'identity_changed',
        );
      }
      if (presentationGuard?.call() == false) return deferred();
      if (_pendingLifecycleTriggers.contains(triggerKey) ||
          _pendingOfferDisplay?['key'] == triggerKey) {
        _reportLifecycleStatus(triggerKey, 'matched', 'server_authorized');
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

        if (_disposed || _cacheScope != scope) {
          return const PaywallResult(
            show: false,
            paywall: null,
            reason: 'identity_changed',
          );
        }
        if (presentationGuard?.call() == false) return deferred();
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
          if (_disposed || _cacheScope != scope) {
            preparedRouteController.dispose();
            return const PaywallResult(
              show: false,
              paywall: null,
              reason: 'identity_changed',
            );
          }
          if (presentationGuard?.call() == false) {
            preparedRouteController.dispose();
            return deferred();
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
        if (_disposed || _cacheScope != scope) {
          preparedRouteController.dispose();
          return const PaywallResult(
            show: false,
            paywall: null,
            reason: 'identity_changed',
          );
        }
        if (presentationGuard?.call() == false) {
          preparedRouteController.dispose();
          return deferred();
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
      _updatePaywallState(triggerKey, MySuperWallPaywallState.failed);
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
    } finally {
      if (paywallStateFor(triggerKey) == MySuperWallPaywallState.loading) {
        _updatePaywallState(triggerKey, MySuperWallPaywallState.idle);
      }
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

  String _followUpPolicySignature(Map policy) {
    final keys = policy.keys.whereType<String>().toList()..sort();
    return jsonEncode({for (final key in keys) key: policy[key]});
  }

  Timer? _pendingOfferTimer;
  void _wakePendingFollowUps(Duration delay) {
    _pendingOfferTimer?.cancel();
    _pendingOfferTimer = Timer(delay, () {
      if (_disposed) return;
      final context = _followUpContext(null);
      if (context == null) return;
      unawaited(
        handlePendingFollowUps(
          context,
          canPresent: () =>
              !_disposed &&
              isHostMounted &&
              WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed,
        ),
      );
    });
  }

  PendingFollowUpService? get _pendingOffers {
    final prefs = _prefs;
    if (prefs == null) return null;
    final scope = jsonEncode([sdkServiceUrl, appKey, _userId]);
    return PendingFollowUpService(
      prefs,
      'mysuperwall_pending_offers_${base64Url.encode(utf8.encode(scope))}',
    );
  }

  Future<void> _cancelPendingPurchasedOffers() async {
    try {
      await _pendingOffers?.cancelPurchasedOffers();
    } catch (error) {
      _logger.w('[MySuperWall] Could not cancel pending offers: $error');
    }
  }

  int _foregroundSequence = 0;
  bool _pendingOfferRunning = false;
  final Map<String, PaywallCallbacks> _pendingOfferCallbacks = {};
  final Map<String, WeakReference<BuildContext>> _pendingOfferOwners = {};
  Map<String, dynamic>? _pendingOfferDisplay;

  Future<bool> _enqueueDeferredOffer(
    PaywallData paywall,
    String event,
    Map<String, dynamic> rule,
    int depth,
    List<String> seen,
    BuildContext owner,
    PaywallCallbacks callbacks,
    Map<String, dynamic>? metadata,
  ) async {
    final store = _pendingOffers;
    if (store == null || _disposed) return false;
    final now = DateTime.now().toUtc();
    final id = '${paywall.id}:$event:${rule['triggerKey']}';
    final session = _prefs?.getInt('mysuperwall_session_count') ?? 1;
    final maxDepth = (rule['maxChainDepth'] as num?)?.toInt() ?? 2;
    if (depth >= maxDepth ||
        (rule['skipIfPremium'] == true && _subscriptionPremium) ||
        !store.allowed(id, rule, session, now)) {
      return false;
    }
    final activeSince = _lifecycleActiveSince;
    final elapsedActive = activeSince == null
        ? 0
        : now.difference(activeSince).inSeconds;
    await store.enqueue({
      'id': id,
      'sourceId': paywall.id,
      'sourceTrigger': paywall.triggerKey,
      'event': event,
      'rule': rule,
      'policy': _followUpPolicySignature(rule),
      'created': now.toIso8601String(),
      'session': session,
      'foreground': _foregroundSequence,
      'active':
          (_prefs?.getInt('mysuperwall_active_seconds') ?? 0) +
          (elapsedActive > 0 ? elapsedActive : 0),
      'depth': depth,
      'seen': seen,
      if (metadata != null) 'metadata': metadata,
    });
    _pendingOfferCallbacks[id] = callbacks;
    _pendingOfferOwners[id] = WeakReference(owner);
    _reportLifecycleStatus(
      rule['triggerKey'].toString(),
      'pending',
      'follow_up_scheduled',
    );
    final mode = rule['timingMode'];
    final delay = mode == 'immediate'
        ? Duration(
            milliseconds: ((rule['delayMs'] as num?)?.toInt() ?? 0) + 350,
          )
        : mode == 'elapsed'
        ? Duration(minutes: (rule['waitMinutes'] as num?)?.toInt() ?? 10)
        : const Duration(seconds: 15);
    _wakePendingFollowUps(delay);
    return true;
  }

  /// Called by the host after metrics refresh. Deferred offers never interrupt
  /// another paywall and always request a fresh server delivery decision.
  Future<bool> handlePendingFollowUps(
    BuildContext context, {
    required bool Function() canPresent,
  }) async {
    if (_disposed ||
        _automationActionHandler != null ||
        _pendingOfferRunning ||
        hostLoadingOverlayListenable.value ||
        _hasActivePresentation ||
        !canPresent()) {
      return false;
    }
    final store = _pendingOffers;
    final prefs = _prefs;
    if (store == null || prefs == null || store.jobs.isEmpty) return false;
    _pendingOfferRunning = true;
    final scope = _cacheScope;
    try {
      if (!await _syncManifestInBackground(requireFresh: true) ||
          scope != _cacheScope) {
        return false;
      }
      final now = DateTime.now().toUtc();
      final session = prefs.getInt('mysuperwall_session_count') ?? 1;
      final install = DateTime.tryParse(
        prefs.getString('mysuperwall_install_date') ?? '',
      );
      for (final job in store.jobs) {
        if (_disposed ||
            scope != _cacheScope ||
            !canPresent() ||
            hostLoadingOverlayListenable.value ||
            _hasActivePresentation) {
          return false;
        }
        final id = job['id']?.toString();
        final rule = job['rule'];
        final created = DateTime.tryParse(job['created']?.toString() ?? '');
        if (id == null || rule is! Map<String, dynamic> || created == null) {
          continue;
        }
        void waiting(String reason) => _reportLifecycleStatus(
          rule['triggerKey'].toString(),
          'pending',
          reason,
        );
        final expiry = (rule['expiresMinutes'] as num?)?.toInt() ?? 1440;
        if (now.difference(created).inMinutes >= expiry ||
            (_subscriptionPremium && rule['cancelOnPurchase'] != false)) {
          _reportLifecycleStatus(
            rule['triggerKey'].toString(),
            'expired',
            _subscriptionPremium
                ? 'follow_up_cancelled_after_purchase'
                : 'follow_up_expired',
          );
          await store.remove(id);
          continue;
        }
        if (_subscriptionPremium && rule['skipIfPremium'] == true) {
          waiting('premium_user');
          continue;
        }
        if (rule['excludeFirstSession'] == true && session <= 1) {
          waiting('first_session_excluded');
          continue;
        }
        if (session < ((rule['minSessions'] as num?)?.toInt() ?? 1)) {
          waiting('minimum_sessions');
          continue;
        }
        if ((install == null ? 0 : now.difference(install).inDays) <
            ((rule['minDays'] as num?)?.toInt() ?? 0)) {
          continue;
        }
        if (!store.allowed(id, rule, session, now)) {
          waiting('follow_up_frequency_limit');
          continue;
        }
        final wait = (rule['waitMinutes'] as num?)?.toInt() ?? 10;
        final mode = rule['timingMode'];
        if (mode == 'immediate' &&
            now.difference(created).inMilliseconds <
                ((rule['delayMs'] as num?)?.toInt() ?? 0)) {
          continue;
        }

        if (mode == 'elapsed' &&
            now.difference(created).inSeconds < wait * 60) {
          continue;
        }
        if (mode == 'active' &&
            (prefs.getInt('mysuperwall_active_seconds') ?? 0) -
                    ((job['active'] as num?)?.toInt() ?? 0) <
                wait * 60) {
          continue;
        }
        if (mode == 'next_session' &&
            session <= ((job['session'] as num?)?.toInt() ?? session)) {
          continue;
        }
        if (mode == 'next_foreground' &&
            session <= ((job['session'] as num?)?.toInt() ?? session) &&
            _foregroundSequence <=
                ((job['foreground'] as num?)?.toInt() ?? _foregroundSequence)) {
          continue;
        }
        // Source policy must still be published and unchanged. A removed rule
        // must not survive indefinitely in the installation's pending queue.
        final source = _manifestService?.manifest?.paywalls[job['sourceId']];
        final rules = source?.contentJson['followUpRules'];
        final current = rules is Map ? rules[job['event']] : null;
        if (current is! Map ||
            current['enabled'] != true ||
            _followUpPolicySignature(current) !=
                _followUpPolicySignature(rule)) {
          _reportLifecycleStatus(
            rule['triggerKey'].toString(),
            'rejected',
            'follow_up_policy_changed',
          );
          await store.remove(id);
          continue;
        }
        final inferred = _pendingOfferOwners[id]?.target;
        if (inferred?.mounted != true) {
          _pendingOfferOwners.remove(id);
          _pendingOfferCallbacks.remove(id);
        }
        final callbacks = inferred?.mounted == true
            ? _pendingOfferCallbacks[id]
            : null;
        if (callbacks?.onPurchase == null && !hasPresentationHandlers) {
          waiting('billing_handlers_unavailable');
          continue;
        }
        _presentationInProgress = true;
        _flowGeneration++;
        _followUps.cancel();
        _pendingOfferDisplay = {
          'id': id,
          'key': rule['triggerKey'],
          'scope': scope,
          'session': session,
          'generation': _flowGeneration,
        };
        try {
          final result = await _handleTrigger(
            context,
            triggerKey: rule['triggerKey'].toString(),
            metadata: job['metadata'] is Map<String, dynamic>
                ? Map<String, dynamic>.from(job['metadata'])
                : null,
            followUpDepth: ((job['depth'] as num?)?.toInt() ?? 0) + 1,
            followUpVisited: (job['seen'] as List? ?? [])
                .whereType<String>()
                .toList(),
            preventFollowUpRepeat: rule['preventRepeatPaywall'] != false,
            presentationGuard: () =>
                scope == _cacheScope &&
                canPresent() &&
                !(_subscriptionPremium &&
                    (rule['skipIfPremium'] == true ||
                        rule['cancelOnPurchase'] != false)),
            onPurchase: callbacks?.onPurchase ?? _presentationPurchase,
            onRestore: callbacks?.onRestore ?? _presentationRestore,
            onDismiss: callbacks?.onDismiss == null
                ? null
                : () => callbacks?.onDismiss?.call(0),
            onOpenUrl: callbacks?.onOpenUrl ?? _presentationOpenUrl,
            onOpenTerms: callbacks?.onOpenTerms ?? _presentationOpenTerms,
            onOpenPrivacy: callbacks?.onOpenPrivacy ?? _presentationOpenPrivacy,
          );
          if (!result.show) {
            _pendingOfferDisplay = null;
            waiting(result.reason ?? 'no_match');
          }
          return result.show;
        } finally {
          _presentationInProgress = false;
        }
      }
    } catch (error) {
      _pendingOfferDisplay = null;
      _logger.w('[MySuperWall] Pending follow-up failed: $error');
    } finally {
      _pendingOfferRunning = false;
    }
    return false;
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
    bool flowValid() =>
        !_disposed &&
        generation == _flowGeneration &&
        scope == _cacheScope &&
        context.mounted;
    bool valid() => flowValid() && identical(_followUpPaywall, paywall);
    Future<bool> closeSource() async {
      dismiss();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (!valid()) return false;
        if (!PaywallView.isShowing && _activePreparedTriggerKey.value == null) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _logger.w(
        '[MySuperWall] Follow-up deferred: source paywall is still closing.',
      );
      return false;
    }

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
      if (event == 'onPurchase' || event == 'onRestore') {
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
      if (!explicit && raw is Map) return;
      if (!explicit &&
          (legacy == null ||
              event != 'onDismiss' ||
              depth != 0 ||
              seen.contains(legacy))) {
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
      if (explicit && rule['timingMode'] != null) {
        unawaited(
          _enqueueDeferredOffer(
                paywall,
                event,
                rule,
                depth,
                seen,
                context,
                PaywallCallbacks(
                  onPurchase: onPurchase,
                  onRestore: onRestore,
                  onDismiss: (_) => onDismiss?.call(),
                  onOpenUrl: onOpenUrl,
                  onOpenTerms: onOpenTerms,
                  onOpenPrivacy: onOpenPrivacy,
                ),
                metadata,
              )
              .then<void>((scheduled) {
                if (scheduled &&
                    valid() &&
                    rule['timingMode'] == 'immediate' &&
                    event != 'onDismiss') {
                  dismiss();
                }
              })
              .catchError((Object error) {
                _logger.w('[MySuperWall] Could not schedule follow-up: $error');
              }),
        );
        if (event == 'onPurchaseCancelled' || event == 'onPurchaseFailed') {
          _followUpOutcomePaywallId = paywall.id;
        }
        return;
      }
      final scheduled = _followUps.schedule(
        key: '${paywall.id}:$event:${rule['triggerKey']}',
        rule: rule,
        depth: depth,
        premium: _subscriptionPremium,
        onError: (error) => _logger.w('[MySuperWall] Follow-up failed: $error'),
        run: () async {
          if (_presentationInProgress) return false;
          _presentationInProgress = true;
          try {
            if (!valid() ||
                WidgetsBinding.instance.lifecycleState !=
                    AppLifecycleState.resumed ||
                (rule['skipIfPremium'] == true && _subscriptionPremium)) {
              return false;
            }
            if (explicit) {
              final nextKey = rule['triggerKey'].toString();
              if (!await closeSource()) return false;
              final outcome = await _handleTrigger(
                context,
                triggerKey: nextKey,
                presentationGuard: () =>
                    flowValid() &&
                    WidgetsBinding.instance.lifecycleState ==
                        AppLifecycleState.resumed &&
                    !(rule['skipIfPremium'] == true && _subscriptionPremium),
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
              return outcome.show;
            } else {
              if (!await closeSource()) return false;
              if (!await _syncManifestInBackground(requireFresh: true)) {
                return false;
              }
              if (!valid()) return false;
              if (_manifestService?.manifest?.findTrigger(paywall.triggerKey) ==
                  null) {
                return false;
              }
              final resolvedLegacy =
                  legacy ??
                  _manifestService?.manifest
                      ?.findTrigger(paywall.triggerKey)
                      ?.dismissFollowUpPaywallId;
              if (resolvedLegacy == null || seen.contains(resolvedLegacy)) {
                return false;
              }
              final next = _manifestService?.manifest?.paywalls[resolvedLegacy];
              if (next == null) return false;
              final result = next.toPaywallResult(
                triggerKey: paywall.triggerKey,
                appKey: paywall.appKey,
              );
              final controller = await _prepareRouteController(result);
              if (!valid()) {
                controller.dispose();
                return false;
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
              return true;
            }
          } finally {
            _presentationInProgress = false;
          }
        },
      );
      if (scheduled &&
          (event == 'onPurchaseFailed' || event == 'onPurchaseCancelled')) {
        _followUpOutcomePaywallId = paywall.id;
      }
    };
  }

  /// Call only after the host billing provider confirms restored entitlement.
  /// Confirms a real restore. A captured restore-button context takes precedence
  /// over a reused callback's original source ID within the same active flow.
  void trackRestoreSuccess({required String paywallId}) {
    final paywall = _followUpPaywall;
    if (paywall == null || _disposed) return;
    final trackedRestore =
        _restoreRequestGeneration == _flowGeneration &&
        _restoreRequestPaywallId == paywall.id;
    final resolvedId = trackedRestore ? _restoreRequestPaywallId : paywallId;
    if (resolvedId != paywall.id) return;
    _restoreRequestPaywallId = null;
    _restoreRequestGeneration = null;
    unawaited(_cancelPendingPurchasedOffers());
    _followUpEvent?.call('onRestore', resolvedId);
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
    final offer = _pendingOfferDisplay;
    if (type == 'paywall_shown' &&
        offer != null &&
        offer['key'] == triggerKey &&
        offer['scope'] == _cacheScope &&
        offer['generation'] == _flowGeneration) {
      _pendingOfferDisplay = null;
      _reportLifecycleStatus(
        triggerKey,
        'shown',
        'deferred_follow_up_displayed',
      );
      final id = offer['id'].toString();
      final pendingStore = _pendingOffers;
      if (pendingStore != null) {
        unawaited(
          pendingStore
              .shown(id, offer['session'] as int, DateTime.now().toUtc())
              .catchError((Object error) {
                _logger.w(
                  '[MySuperWall] Could not complete pending offer: $error',
                );
              }),
        );
      }
      _pendingOfferCallbacks.remove(id);
      _pendingOfferOwners.remove(id);
    }
    if (type == 'paywall_shown' &&
        _pendingLifecycleTriggers.contains(triggerKey)) {
      _reportLifecycleStatus(triggerKey, 'shown', 'display_callback');
      _pendingLifecycleTriggers.remove(triggerKey);
      _pendingLifecycleDates.remove(triggerKey);
      unawaited(
        _saveLifecycleQueue().catchError((Object error) {
          _logger.w(
            '[MySuperWall] Could not persist lifecycle completion: $error',
          );
        }),
      );
    }
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
        'purchase_cancelled': 'onPurchaseCancelled',
        'restore': 'onRestore',
        'restore_success': 'onRestore',
      }[eventType];
      if (eventType == 'purchase_success') {
        await _cancelPendingPurchasedOffers();
      }
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
        'sdkCapabilities': ['deferred_follow_up_v1'],
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
            Uri.parse('${sdkServiceUrl}paywall/purchase'),
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
      baseUrl: sdkServiceUrl,
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
        'sdkCapabilities': ['deferred_follow_up_v1'],
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
            Uri.parse('${sdkServiceUrl}paywall/dismiss'),
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

  // ---------------------------------------------------------------------
  // Push notifications (optional)
  //
  // The SDK does not depend on Firebase. Your app reads the FCM token with
  // firebase_messaging and hands it over with [setPushToken]; MySuperWall then
  // sends notifications (for example after a paywall is closed) through the
  // Firebase project connected in the dashboard.
  // ---------------------------------------------------------------------

  static const _pushTokenKey = 'mysuperwall_push_token';
  static const _pushSyncKey = 'mysuperwall_push_sync';
  String? _pushToken;

  /// Registers this device's FCM token so notifications can reach it.
  ///
  /// Call it once the user allowed notifications, and again from
  /// `FirebaseMessaging.instance.onTokenRefresh`. The token is registered for
  /// the current user and language and re-registered automatically when
  /// [setUserId] or [setLocale] change them.
  Future<void> setPushToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      throw const MySuperWallException('Push token cannot be empty');
    }
    _pushToken = value;
    try {
      await _prefs?.setString(_pushTokenKey, value);
    } catch (_) {}
    await _syncPushToken(force: true);
  }

  /// Stops notifications for this device, for example when the user turns
  /// them off in your app or logs out.
  Future<void> clearPushToken() async {
    final token = _pushToken ?? _prefs?.getString(_pushTokenKey);
    _pushToken = null;
    try {
      await _prefs?.remove(_pushTokenKey);
      await _prefs?.remove(_pushSyncKey);
    } catch (_) {}
    if (token == null || _disposed) return;
    try {
      final appInfo = await PackageInfo.fromPlatform();
      await _httpClient
          .post(
            Uri.parse('${sdkServiceUrl}paywall/push-token/remove'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
              if (Platform.isIOS) 'bundleId': appInfo.packageName,
              if (Platform.isAndroid) 'packageName': appInfo.packageName,
              'token': token,
            }),
          )
          .timeout(timeout);
    } catch (e) {
      _logger.e('[MySuperWall] Push token removal error: $e');
    }
  }

  Future<void> _syncPushToken({bool force = false}) async {
    if (_disposed) return;
    final token = _pushToken ?? _prefs?.getString(_pushTokenKey);
    final userId = _userId;
    if (token == null || userId == null) return;
    _pushToken = token;
    try {
      final appInfo = await PackageInfo.fromPlatform();
      final offset = DateTime.now().timeZoneOffset.inMinutes;
      final signature = jsonEncode([
        token,
        userId,
        _locale,
        appInfo.version,
        offset,
      ]);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force) {
        final last = _prefs?.getString(_pushSyncKey);
        if (last != null) {
          final saved = jsonDecode(last) as Map<String, dynamic>;
          if (saved['s'] == signature && now - (saved['t'] as int) < 86400000) {
            return;
          }
        }
      }
      final response = await _httpClient
          .post(
            Uri.parse('${sdkServiceUrl}paywall/push-token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
              if (Platform.isIOS) 'bundleId': appInfo.packageName,
              if (Platform.isAndroid) 'packageName': appInfo.packageName,
              'userId': userId,
              'token': token,
              'platform': Platform.isIOS ? 'ios' : 'android',
              if (_locale != null) 'locale': _locale,
              'utcOffsetMinutes': offset,
              'appVersion': appInfo.version,
            }),
          )
          .timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _prefs?.setString(
          _pushSyncKey,
          jsonEncode({'s': signature, 't': now}),
        );
      }
    } catch (e) {
      _logger.e('[MySuperWall] Push token registration error: $e');
    }
  }

  /// True when a push message was sent by MySuperWall. Use it to tell these
  /// messages apart from your own in `onMessageOpenedApp`.
  static bool isMySuperWallNotification(Map<String, dynamic> data) =>
      data['mysuperwall'] == '1';

  /// Reports that the user tapped a MySuperWall notification and returns the
  /// trigger key chosen for it in the dashboard, or null when the message did
  /// not come from MySuperWall (or names no trigger).
  ///
  /// Use it when your app presents paywalls itself (for example with its own
  /// purchase callbacks) and only needs to know which trigger to run.
  Future<String?> trackNotificationOpened(Map<String, dynamic> data) async {
    if (_disposed || !isMySuperWallNotification(data)) return null;
    unawaited(_reportNotificationOpened(data['jobId']?.toString()));
    final triggerKey = data['triggerKey']?.toString() ?? '';
    return triggerKey.isEmpty ? null : triggerKey;
  }

  /// Call with `RemoteMessage.data` when the user taps a notification
  /// (`FirebaseMessaging.onMessageOpenedApp` and `getInitialMessage()`).
  ///
  /// Reports the open for analytics and runs the trigger chosen for the
  /// notification in the dashboard, which shows its paywall. Returns false when
  /// the message did not come from MySuperWall.
  Future<bool> handleNotificationOpened(
    BuildContext context,
    Map<String, dynamic> data, {
    Map<String, dynamic>? metadata,
    Function(String productId)? onPurchase,
    VoidCallback? onRestore,
    VoidCallback? onDismiss,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
  }) async {
    if (_disposed || !isMySuperWallNotification(data)) return false;
    final triggerKey = await trackNotificationOpened(data);
    if (triggerKey != null && context.mounted) {
      await handleTrigger(
        context,
        triggerKey: triggerKey,
        metadata: {...?metadata, 'source': 'notification'},
        onPurchase: onPurchase,
        onRestore: onRestore,
        onDismiss: onDismiss,
        onOpenUrl: onOpenUrl,
        onOpenTerms: onOpenTerms,
        onOpenPrivacy: onOpenPrivacy,
      );
    }
    return true;
  }

  Future<void> _reportNotificationOpened(String? jobId) async {
    final userId = _userId;
    if (jobId == null || jobId.isEmpty || userId == null) return;
    try {
      final appInfo = await PackageInfo.fromPlatform();
      await _httpClient
          .post(
            Uri.parse('${sdkServiceUrl}paywall/notification-opened'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (appKey != null && appKey!.isNotEmpty) 'appKey': appKey,
              if (Platform.isIOS) 'bundleId': appInfo.packageName,
              if (Platform.isAndroid) 'packageName': appInfo.packageName,
              'userId': userId,
              'jobId': jobId,
              'platform': Platform.isIOS ? 'ios' : 'android',
              'appVersion': appInfo.version,
            }),
          )
          .timeout(timeout);
    } catch (e) {
      _logger.e('[MySuperWall] Notification open report error: $e');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pendingOfferTimer?.cancel();
    _flowGeneration++;
    _pendingOfferDisplay = null;
    _pendingOfferCallbacks.clear();
    _pendingOfferOwners.clear();

    _restoreRequestPaywallId = null;
    _restoreRequestGeneration = null;
    _followUps.reset();
    _followUpEvent = null;
    _followUpPaywall = null;
    _followUpOutcomePaywallId = null;
    _automationActionHandler = null;
    _presentationHandlerOwner = null;
    _presentationHandlersExplicit = false;
    _presentationPurchase = null;
    _presentationRestore = null;
    _presentationOpenUrl = null;
    _presentationOpenTerms = null;
    _presentationOpenPrivacy = null;
    _eventQueue?.dispose();
    _eventQueue = null;
    if (identical(_instance, this)) {
      dismiss();
      setHostLoadingOverlayVisible(false);
      _instance = null;
    }
    clearPreparedPaywallPool();
    _paywallCache.clear();
    _purchaseContexts.clear();
    _pendingLifecycleTriggers.clear();
    _paywallStates.dispose();
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
