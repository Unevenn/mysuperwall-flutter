import '../models/paywall_state.dart';
import '../services/sdk_endpoint.dart';
import '../services/sdk_logging.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/paywall_data.dart';

class PaywallCallbacks {
  const PaywallCallbacks({
    this.onShown,
    this.onPurchase,
    this.onRestore,
    this.onDismiss,
    this.onOpenUrl,
    this.onOpenTerms,
    this.onOpenPrivacy,
  });

  final VoidCallback? onShown;
  final void Function(String productId)? onPurchase;
  final VoidCallback? onRestore;
  final void Function(int durationInSeconds)? onDismiss;
  final ValueChanged<String>? onOpenUrl;
  final ValueChanged<String?>? onOpenTerms;
  final ValueChanged<String?>? onOpenPrivacy;
}

class PreparedPaywallController with WidgetsBindingObserver {
  PreparedPaywallController({required this.paywall, this.onStateChanged});

  final ValueChanged<MySuperWallPaywallState>? onStateChanged;
  bool _hasPaintSignal = false;
  bool _loadFailed = false;
  bool _presentationFinished = false;
  bool _shownReported = false;
  bool Function()? _isPresentationVisible;

  void presentationCompleted({required bool Function() isVisible}) {
    _isPresentationVisible = isVisible;
    _presentationFinished = true;
    _reportVisibleAfterFrame();
  }

  void _reportVisibleAfterFrame() {
    final session = _presentationSession;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (_disposed ||
          _callbacks == null ||
          session != _presentationSession ||
          _shownReported ||
          !_presentationFinished ||
          !_hasPaintSignal ||
          _loadFailed ||
          _isPresentationVisible?.call() != true ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed))
        return;
      _shownReported = true;
      _openedAt = DateTime.now();
      onStateChanged?.call(MySuperWallPaywallState.visible);
      _callbacks?.onShown?.call();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reportVisibleAfterFrame();
  }

  void _markFailed() {
    if (_disposed) return;
    _loadFailed = true;
    isLoading.value = false;
    isReady.value = false;
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    onStateChanged?.call(MySuperWallPaywallState.failed);
  }

  static const Color defaultBackgroundColor = Color(0x00000000);
  static const Color fallbackBackgroundColor = Color(0x00000000);
  static const Duration _readyFallbackDelay = Duration(milliseconds: 700);

  static final Logger _logger = MySuperWallLogging.createLogger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 3,
      lineLength: 50,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  final PaywallData paywall;
  final WebViewController controller = WebViewController();
  final ValueNotifier<bool> isLoading = ValueNotifier(true);
  final ValueNotifier<bool> isReady = ValueNotifier(false);

  bool _disposed = false;
  bool _configured = false;
  bool _warmed = false;
  bool _hasLoggedReady = false;
  PaywallCallbacks? _callbacks;
  DateTime? _openedAt;
  Completer<void>? _readyCompleter;
  int _presentationSession = 0;
  int _loadGeneration = 0;

  bool get isWarmed => _warmed;
  bool get hasCompletedInitialLoad => isReady.value;
  int get presentationSession => _presentationSession;
  int get activeDurationInSeconds =>
      _openedAt == null ? 0 : DateTime.now().difference(_openedAt!).inSeconds;

  void activate(PaywallCallbacks callbacks) {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    _callbacks = callbacks;
    _presentationFinished = false;
    _isPresentationVisible = null;
    _shownReported = false;
    _openedAt = null;
    onStateChanged?.call(
      _loadFailed
          ? MySuperWallPaywallState.failed
          : MySuperWallPaywallState.presenting,
    );
    _presentationSession++;
  }

  void deactivate() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_disposed && _callbacks != null) {
      onStateChanged?.call(MySuperWallPaywallState.dismissed);
    }
    _callbacks = null;
    _isPresentationVisible = null;
    _openedAt = null;
  }

  void dismiss() {
    _callbacks?.onDismiss?.call(activeDurationInSeconds);
  }

  Future<void> warm() async {
    if (_disposed) return;
    if (!_configured) {
      _configureController();
    }
    if (_warmed) {
      return;
    }

    onStateChanged?.call(MySuperWallPaywallState.loading);
    try {
      await controller.loadHtmlString(buildHtml(sdkServiceUrl, paywall.html));
    } catch (_) {
      _markFailed();
      rethrow;
    }
    _warmed = true;
    _logger.i(
      '[MySuperWall] Prepared paywall warmed for trigger "${paywall.triggerKey}".',
    );
  }

  Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_disposed) return false;
    if (isReady.value) {
      return true;
    }

    final completer = _readyCompleter ??= Completer<void>();
    try {
      await completer.future.timeout(timeout);
    } catch (_) {}
    return !_disposed && isReady.value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadGeneration++;
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    deactivate();
    isLoading.dispose();
    isReady.dispose();
  }

  void _configureController() {
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(defaultBackgroundColor)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (_disposed) return;
            _loadGeneration++;
            _hasPaintSignal = false;
            _loadFailed = false;
            onStateChanged?.call(
              _callbacks == null
                  ? MySuperWallPaywallState.loading
                  : MySuperWallPaywallState.presenting,
            );
            isLoading.value = true;
            isReady.value = false;
            if (_readyCompleter == null || _readyCompleter!.isCompleted) {
              _readyCompleter = Completer<void>();
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) _markFailed();
          },
          onPageFinished: (String url) {
            if (_disposed) return;
            final finishedGeneration = _loadGeneration;
            unawaited(_markReadyFallback(finishedGeneration));
            if (Platform.isAndroid) {
              unawaited(_installAndroidBackDismissBridge());
            }
            if (!_hasLoggedReady) {
              _hasLoggedReady = true;
              _logger.i(
                '[MySuperWall] Prepared paywall ready for trigger "${paywall.triggerKey}".',
              );
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        'MySuperWall',
        onMessageReceived: (JavaScriptMessage message) {
          final data = jsonDecode(message.message);
          final action = data['action'];

          if (action == 'purchase') {
            final productId = data['productId'];
            if (productId != null) {
              _callbacks?.onPurchase?.call(productId.toString());
            }
          } else if (action == 'openURL' || action == 'openUrl') {
            final url = data['url']?.toString().trim();
            if (url != null && url.isNotEmpty) {
              _callbacks?.onOpenUrl?.call(url);
            }
          } else if (action == 'openTerms') {
            final url = data['url']?.toString().trim();
            _callbacks?.onOpenTerms?.call(
              (url == null || url.isEmpty) ? null : url,
            );
          } else if (action == 'openPrivacy') {
            final url = data['url']?.toString().trim();
            _callbacks?.onOpenPrivacy?.call(
              (url == null || url.isEmpty) ? null : url,
            );
          } else if (action == 'dismiss') {
            dismiss();
          } else if (action == 'restore') {
            _callbacks?.onRestore?.call();
          }
        },
      )
      ..addJavaScriptChannel(
        'MySuperWallReady',
        onMessageReceived: (_) {
          if (_disposed || _loadFailed) return;
          _hasPaintSignal = true;
          unawaited(_markReadyAfterPaint(_loadGeneration));
          if (_callbacks == null) {
            onStateChanged?.call(MySuperWallPaywallState.ready);
          }
          _reportVisibleAfterFrame();
        },
      );

    _configured = true;
  }

  void _completeReady(int generation) {
    if (_disposed ||
        _loadFailed ||
        generation != _loadGeneration ||
        isReady.value) {
      return;
    }

    isLoading.value = false;
    isReady.value = true;
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.complete();
    }
  }

  Future<void> _markReadyAfterPaint(int generation) async {
    await WidgetsBinding.instance.endOfFrame;
    _completeReady(generation);
  }

  Future<void> _markReadyFallback(int generation) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(_readyFallbackDelay);
    _completeReady(generation);
  }

  static String _buildPaintReadyScript() {
    return '''
<script>
(function () {
  if (window.__mySuperWallPaintReadyInstalled) {
    return;
  }
  window.__mySuperWallPaintReadyInstalled = true;

  var notifyReady = function () {
    if (document.readyState !== 'complete') return;
    try {
      if (window.MySuperWallReady && window.MySuperWallReady.postMessage) {
        window.MySuperWallReady.postMessage('paint-ready');
      }
    } catch (_) {}
  };

  var afterPaint = function () {
    try {
      requestAnimationFrame(function () {
        requestAnimationFrame(notifyReady);
      });
    } catch (_) {
      setTimeout(notifyReady, 80);
    }
  };

  if (document.readyState === 'complete') {
    afterPaint();
  } else {
    window.addEventListener('load', afterPaint, { once: true });
    setTimeout(afterPaint, 900);
  }
})();
</script>
''';
  }

  Future<void> _installAndroidBackDismissBridge() async {
    try {
      await controller.runJavaScript('''
(() => {
  if (window.__mySuperWallAndroidBackBridgeInstalled) {
    return;
  }

  window.__mySuperWallAndroidBackBridgeInstalled = true;

  const dismiss = () => {
    try {
      MySuperWall.postMessage(JSON.stringify({ action: 'dismiss' }));
    } catch (_) {}
  };

  try {
    window.history.pushState(
      { __mySuperWallDismissEntry: true },
      document.title,
      window.location.href
    );
  } catch (_) {}

  window.addEventListener('popstate', () => {
    dismiss();
  }, { once: true });
})();
''');
    } catch (error) {
      _logger.w(
        '[MySuperWall] Failed to install Android back dismiss bridge: $error',
      );
    }
  }

  static String buildHtml(String baseUrl, String html) {
    var normalizedBaseUrl = baseUrl;
    if (normalizedBaseUrl.endsWith('/')) {
      normalizedBaseUrl = normalizedBaseUrl.substring(
        0,
        normalizedBaseUrl.length - 1,
      );
    }

    final baseTag = '<base href="$normalizedBaseUrl/">';
    final readyScript = _buildPaintReadyScript();

    String resultHtml = html;

    // 1. Inject <base href="...">
    final headRegex = RegExp(r'<head\b[^>]*>', caseSensitive: false);
    if (headRegex.hasMatch(resultHtml)) {
      resultHtml = resultHtml.replaceFirstMapped(
        headRegex,
        (match) => '${match.group(0)}$baseTag',
      );
    } else {
      resultHtml = '$baseTag$resultHtml';
    }

    // 2. Inject PaintReady script before </body> or at the end
    final bodyRegex = RegExp(r'</body\s*>', caseSensitive: false);
    if (bodyRegex.hasMatch(resultHtml)) {
      resultHtml = resultHtml.replaceFirstMapped(
        bodyRegex,
        (match) => '$readyScript${match.group(0)}',
      );
    } else {
      resultHtml = '$resultHtml$readyScript';
    }

    // 3. Normalize relative asset paths
    return resultHtml
        .replaceAll('"/assets/', '"$normalizedBaseUrl/assets/')
        .replaceAll("'/assets/", "'$normalizedBaseUrl/assets/")
        .replaceAll('url(/assets/', 'url($normalizedBaseUrl/assets/')
        .replaceAll('url("/assets/', 'url("$normalizedBaseUrl/assets/')
        .replaceAll("url('/assets/", "url('$normalizedBaseUrl/assets/");
  }
}
