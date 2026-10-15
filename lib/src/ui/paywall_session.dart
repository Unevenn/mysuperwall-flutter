import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/paywall_data.dart';

class PaywallCallbacks {
  const PaywallCallbacks({
    this.onPurchase,
    this.onRestore,
    this.onDismiss,
    this.onOpenUrl,
    this.onOpenTerms,
    this.onOpenPrivacy,
  });

  final void Function(String productId)? onPurchase;
  final VoidCallback? onRestore;
  final void Function(int durationInSeconds)? onDismiss;
  final ValueChanged<String>? onOpenUrl;
  final ValueChanged<String?>? onOpenTerms;
  final ValueChanged<String?>? onOpenPrivacy;
}

class PreparedPaywallController {
  PreparedPaywallController({required this.paywall});

  static const Color defaultBackgroundColor = Color(0x00000000);
  static const Color fallbackBackgroundColor = Color(0x00000000);
  static const Duration _readyFallbackDelay = Duration(milliseconds: 700);

  static final Logger _logger = Logger(
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
    _callbacks = callbacks;
    _openedAt = DateTime.now();
    _presentationSession++;
  }

  void deactivate() {
    _callbacks = null;
    _openedAt = null;
  }

  void dismiss() {
    _callbacks?.onDismiss?.call(activeDurationInSeconds);
  }

  Future<void> warm({required String baseUrl}) async {
    if (!_configured) {
      _configureController();
    }
    if (_warmed) {
      return;
    }

    await controller.loadHtmlString(buildHtml(baseUrl, paywall.html));
    _warmed = true;
    _logger.i(
      '[MySuperWall] Prepared paywall warmed for trigger "${paywall.triggerKey}".',
    );
  }

  Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (isReady.value) {
      return true;
    }

    final completer = _readyCompleter ??= Completer<void>();
    try {
      await completer.future.timeout(timeout);
    } catch (_) {}
    return isReady.value;
  }

  void dispose() {
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
            _loadGeneration++;
            isLoading.value = true;
            isReady.value = false;
            if (_readyCompleter == null || _readyCompleter!.isCompleted) {
              _readyCompleter = Completer<void>();
            }
          },
          onPageFinished: (String url) {
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
          unawaited(_markReadyAfterPaint(_loadGeneration));
        },
      );

    _configured = true;
  }

  void _completeReady(int generation) {
    if (generation != _loadGeneration || isReady.value) {
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
