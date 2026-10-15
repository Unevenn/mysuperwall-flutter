import 'package:flutter/material.dart';

enum PaywallPresentationStyle { system, slideLeft, slideUp, slideDown, none }

enum PaywallDismissStyle { system, swipeRight, none }

extension PaywallDismissStyleX on PaywallDismissStyle {
  bool get allowsSystemBackLegacy => this == PaywallDismissStyle.system;

  bool get allowsEdgeSwipeLegacy => this != PaywallDismissStyle.none;
}

class PaywallPresentationConfig {
  const PaywallPresentationConfig({
    this.style = PaywallPresentationStyle.system,
    this.duration = const Duration(milliseconds: 280),
    this.curve = Curves.easeOutCubic,
    this.dismissStyle = PaywallDismissStyle.system,
    this.dismissable,
  });

  final PaywallPresentationStyle style;
  final Duration duration;
  final Curve curve;
  final PaywallDismissStyle dismissStyle;
  final bool? dismissable;

  bool get allowsSystemBack =>
      dismissable ?? dismissStyle.allowsSystemBackLegacy;

  bool get allowsEdgeSwipe => dismissable ?? dismissStyle.allowsEdgeSwipeLegacy;

  static const PaywallPresentationConfig defaults = PaywallPresentationConfig();

  factory PaywallPresentationConfig.fromContentJson(
    Map<String, dynamic> contentJson,
  ) {
    final dynamic rawPresentation = contentJson['presentation'];
    final presentation = rawPresentation is Map<String, dynamic>
        ? rawPresentation
        : rawPresentation is Map
        ? Map<String, dynamic>.from(rawPresentation)
        : const <String, dynamic>{};

    final durationMs = _parseDurationMs(presentation['durationMs']);

    return PaywallPresentationConfig(
      style: _parseStyle(presentation['style']?.toString()),
      duration: Duration(milliseconds: durationMs),
      curve: _parseCurve(presentation['curve']?.toString()),
      dismissStyle: _parseDismissStyle(
        presentation['dismissStyle']?.toString(),
      ),
      dismissable: _parseDismissable(
        presentation.containsKey('dismissable')
            ? presentation['dismissable']
            : presentation['dismissible'],
      ),
    );
  }

  Offset get beginOffset {
    switch (style) {
      case PaywallPresentationStyle.slideLeft:
        return const Offset(28, 0);
      case PaywallPresentationStyle.slideUp:
        return const Offset(0, 36);
      case PaywallPresentationStyle.slideDown:
        return const Offset(0, -36);
      case PaywallPresentationStyle.none:
      case PaywallPresentationStyle.system:
        return Offset.zero;
    }
  }

  static int _parseDurationMs(dynamic value) {
    final parsed = value is int
        ? value
        : int.tryParse(value?.toString() ?? '') ??
              defaults.duration.inMilliseconds;
    return parsed.clamp(0, 4000);
  }

  static Curve _parseCurve(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'easeout':
        return Curves.easeOut;
      case 'easeinout':
        return Curves.easeInOut;
      case 'linear':
        return Curves.linear;
      case 'easeoutquart':
        return Curves.easeOutQuart;
      case 'easeoutback':
        return Curves.easeOutBack;
      case 'easeoutcubic':
      default:
        return Curves.easeOutCubic;
    }
  }

  static bool? _parseDismissable(dynamic value) {
    if (value is bool) {
      return value;
    }

    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
    return null;
  }

  static PaywallDismissStyle _parseDismissStyle(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'none':
        return PaywallDismissStyle.none;
      case 'swipe_right':
      case 'swiperight':
        return PaywallDismissStyle.swipeRight;
      case 'system':
      default:
        return PaywallDismissStyle.system;
    }
  }

  static PaywallPresentationStyle _parseStyle(String? raw) {
    final normalized = _normalizeToken(raw);
    final compact = normalized.replaceAll('_', '');

    switch (normalized) {
      case 'slide_left':
      case 'right_to_left':
      case 'slide_right':
      case 'left_to_right':
      case 'from_right':
      case 'right':
        return PaywallPresentationStyle.slideLeft;
      case 'slide_up':
      case 'bottom_up':
      case 'bottom_to_top':
      case 'from_bottom':
      case 'up_from_bottom':
      case 'up':
        return PaywallPresentationStyle.slideUp;
      case 'slide_down':
      case 'top_down':
      case 'top_to_bottom':
      case 'from_top':
      case 'down_from_top':
      case 'down':
        return PaywallPresentationStyle.slideDown;
      case 'none':
        return PaywallPresentationStyle.none;
      case 'system':
        return PaywallPresentationStyle.system;
    }

    switch (compact) {
      case 'slideleft':
      case 'righttoleft':
      case 'slideright':
      case 'lefttoright':
      case 'fromright':
        return PaywallPresentationStyle.slideLeft;
      case 'slideup':
      case 'bottomup':
      case 'bottomtotop':
      case 'frombottom':
      case 'upfrombottom':
        return PaywallPresentationStyle.slideUp;
      case 'slidedown':
      case 'topdown':
      case 'toptobottom':
      case 'fromtop':
      case 'downfromtop':
        return PaywallPresentationStyle.slideDown;
      case 'none':
        return PaywallPresentationStyle.none;
      case 'system':
      default:
        return PaywallPresentationStyle.system;
    }
  }

  static String _normalizeToken(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return '';
    }

    final withWordBoundaries = trimmed.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match.group(1)}_${match.group(2)}',
    );

    return withWordBoundaries
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '')
        .toLowerCase();
  }
}
