import 'package:flutter/material.dart';
import '../models/paywall_presentation.dart';

/// Shared entry/exit motion for route and prepared WebViews. The native view
/// stays as AnimatedBuilder.child; no blur, screenshot or per-frame HTML work.
class PaywallMotion extends StatelessWidget {
  const PaywallMotion({
    super.key,
    required this.presentation,
    required this.animation,
    required this.child,
    this.dragOffset = 0,
    this.hidden = false,
  });

  final PaywallPresentationConfig presentation;
  final Animation<double> animation;
  final Widget child;
  final double dragOffset;
  final bool hidden;

  static Offset beginFraction(PaywallPresentationStyle style) =>
      switch (style) {
        PaywallPresentationStyle.system ||
        PaywallPresentationStyle.slideUp => const Offset(0, 1),
        PaywallPresentationStyle.slideDown => const Offset(0, -.12),
        PaywallPresentationStyle.slideLeft => const Offset(.12, 0),
        PaywallPresentationStyle.slideFromLeft => const Offset(-.12, 0),
        _ => Offset.zero,
      };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: RepaintBoundary(child: child),
    builder: (context, content) {
      final style = presentation.style;
      final curve = style == PaywallPresentationStyle.system
          ? PaywallPresentationConfig.defaults.curve
          : presentation.curve;
      final raw = animation.value.clamp(0.0, 1.0);
      final progress = style == PaywallPresentationStyle.none
          ? 1.0
          : curve.transform(raw);
      final remaining = 1 - progress;
      final fraction = beginFraction(style) * remaining;
      final opacity = switch (style) {
        PaywallPresentationStyle.fade ||
        PaywallPresentationStyle.scaleUp ||
        PaywallPresentationStyle.scaleDown ||
        PaywallPresentationStyle.fadeSlideUp => progress.clamp(0.0, 1.0),
        _ => 1.0,
      };
      final scale = switch (style) {
        PaywallPresentationStyle.scaleUp => 1 - .04 * remaining,
        PaywallPresentationStyle.scaleDown => 1 + .035 * remaining,
        _ => 1.0,
      };
      return Opacity(
        opacity: hidden ? .001 : opacity,
        child: FractionalTranslation(
          translation: hidden ? Offset.zero : fraction,
          child: Transform.translate(
            offset: hidden
                ? Offset.zero
                : Offset(
                    dragOffset,
                    style == PaywallPresentationStyle.fadeSlideUp
                        ? 24 * remaining
                        : 0,
                  ),
            child: Transform.scale(scale: hidden ? 1 : scale, child: content),
          ),
        ),
      );
    },
  );
}
