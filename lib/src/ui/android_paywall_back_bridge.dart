import 'dart:io';

import 'package:flutter/services.dart';

class AndroidPaywallBackBridge {
  AndroidPaywallBackBridge._();

  static const MethodChannel _channel = MethodChannel('mysuperwall/back');
  static bool _isConfigured = false;

  static void configure({required Future<void> Function() onDismissRequested}) {
    if (!Platform.isAndroid || _isConfigured) {
      return;
    }

    _isConfigured = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dismissPaywall':
          await onDismissRequested();
          return true;
        default:
          return null;
      }
    });
  }

  static Future<void> setPaywallVisible(bool visible) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod('setPaywallVisible', {'visible': visible});
    } catch (_) {}
  }
}
