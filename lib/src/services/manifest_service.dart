import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/paywall_manifest.dart';

class ManifestService {
  ManifestService({
    required this.preferences,
    required this.httpClient,
    Logger? logger,
  }) : _logger = logger ?? Logger();

  final SharedPreferences preferences;
  final http.Client httpClient;
  final Logger _logger;

  PaywallManifest? _currentManifest;
  String? _activeScope;
  int _generation = 0;

  void _activateScope(String scope) {
    if (_activeScope == scope) return;
    _activeScope = scope;
    _generation++;
    _currentManifest = null;
  }

  PaywallManifest? get manifest => _currentManifest;

  String _cacheKey(String scope) =>
      'mysuperwall_manifest_${base64Url.encode(utf8.encode(scope))}';

  /// Loads cached manifest from disk instantly (0ms execution).
  PaywallManifest? loadFromDisk(String scope) {
    _activateScope(scope);
    try {
      final raw = preferences.getString(_cacheKey(scope));
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _currentManifest = PaywallManifest.fromJson(decoded);
        return _currentManifest;
      }
    } catch (e) {
      _logger.w('[MySuperWall] Failed to decode cached manifest from disk: $e');
    }
    return null;
  }

  /// Persists manifest to disk.
  Future<void> saveToDisk(String scope, PaywallManifest manifest) async {
    if (_activeScope != scope) return;
    _currentManifest = manifest;
    try {
      final jsonString = jsonEncode(manifest.toJson());
      await preferences.setString(_cacheKey(scope), jsonString);
    } catch (e) {
      _logger.w('[MySuperWall] Failed to persist manifest to disk: $e');
    }
  }

  /// Fetches fresh manifest from backend with ETag/hash optimization.
  /// Runs asynchronously in background without blocking UI or triggers.
  Future<PaywallManifest?> fetchManifest({
    required String baseUrl,
    required String scope,
    String? appKey,
    String? bundleId,
    String? packageName,
    String? platform,
    String? appVersion,
    String? lang,
    Map<String, dynamic>? substitutionData,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _activateScope(scope);
    final generation = _generation;
    try {
      final uri = Uri.parse('${baseUrl}paywall/manifest');
      final currentHash = _currentManifest?.hash;

      final body = <String, dynamic>{
        if (appKey != null && appKey.isNotEmpty) 'appKey': appKey,
        if (bundleId != null && bundleId.isNotEmpty) 'bundleId': bundleId,
        if (packageName != null && packageName.isNotEmpty)
          'packageName': packageName,
        if (platform != null) 'platform': platform,
        if (appVersion != null) 'appVersion': appVersion,
        if (lang != null) 'lang': lang,
        if (currentHash != null && currentHash.isNotEmpty) 'hash': currentHash,
        if (substitutionData != null) 'substitutionData': substitutionData,
      };

      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (currentHash != null && currentHash.isNotEmpty)
          'If-None-Match': '"$currentHash"',
      };

      final response = await httpClient
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(timeout);

      if (_activeScope != scope || generation != _generation) return null;

      // 304 Not Modified: Cache is 100% up to date, 0 bytes overhead!
      if (response.statusCode == 304) {
        _logger.d('[MySuperWall] Manifest is up to date (304 Not Modified).');
        return _currentManifest;
      }

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body);
        if (payload is Map<String, dynamic>) {
          if (payload['notModified'] == true) {
            _logger.d('[MySuperWall] Manifest is up to date (hash match).');
            return _currentManifest;
          }

          final newManifest = PaywallManifest.fromJson(payload);
          await saveToDisk(scope, newManifest);
          _logger.i(
            '[MySuperWall] Loaded active manifest with ${newManifest.triggers.length} triggers and ${newManifest.paywalls.length} paywalls.',
          );
          return newManifest;
        }
      }
    } catch (e) {
      _logger.w(
        '[MySuperWall] Background manifest sync failed (using offline cache if present): $e',
      );
    }
    return _activeScope == scope && generation == _generation
        ? _currentManifest
        : null;
  }

  /// Clears stored manifest for the given scope.
  Future<void> clear(String scope) async {
    if (_activeScope == scope) {
      _currentManifest = null;
      _generation++;
    }
    await preferences.remove(_cacheKey(scope));
  }
}
