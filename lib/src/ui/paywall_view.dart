import '../services/sdk_logging.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/paywall_data.dart';
import '../models/paywall_presentation.dart';
import '../mysuperwall_client.dart';
import 'android_paywall_back_bridge.dart';
import 'edge_swipe_dismiss_overlay.dart';
import 'paywall_session.dart';

class PaywallView extends StatefulWidget {
  static VoidCallback? _currentDismiss;

  static bool get isShowing => _currentDismiss != null;
  final PaywallData paywall;
  final Function(String productId)? onPurchase;
  final VoidCallback? onDismiss;
  final VoidCallback? onRestore;
  final VoidCallback? onShown;
  final ValueChanged<String>? onOpenUrl;
  final ValueChanged<String?>? onOpenTerms;
  final ValueChanged<String?>? onOpenPrivacy;
  final PreparedPaywallController? preparedController;

  final bool disposeProvidedPreparedController;

  const PaywallView({
    super.key,
    required this.paywall,
    this.onPurchase,
    this.onDismiss,
    this.onRestore,
    this.onShown,
    this.onOpenUrl,
    this.onOpenTerms,
    this.onOpenPrivacy,
    this.preparedController,
    this.disposeProvidedPreparedController = false,
  });

  @override
  State<PaywallView> createState() => _PaywallViewState();

  static void dismissCurrent() {
    _currentDismiss?.call();
    _currentDismiss = null;
  }

  static Future<void> show(
    BuildContext context, {
    required PaywallData paywall,
    Function(String productId)? onPurchase,
    VoidCallback? onDismiss,
    VoidCallback? onRestore,
    VoidCallback? onShown,
    ValueChanged<String>? onOpenUrl,
    ValueChanged<String?>? onOpenTerms,
    ValueChanged<String?>? onOpenPrivacy,
    PreparedPaywallController? preparedController,
    bool disposeProvidedPreparedController = false,
  }) async {
    dismissCurrent();

    PaywallView routeBuilder(BuildContext context) => PaywallView(
      paywall: paywall,
      onPurchase: onPurchase,
      onDismiss: onDismiss,
      onRestore: onRestore,
      onShown: onShown,
      onOpenUrl: onOpenUrl,
      onOpenTerms: onOpenTerms,
      onOpenPrivacy: onOpenPrivacy,
      preparedController: preparedController,
      disposeProvidedPreparedController: disposeProvidedPreparedController,
    );

    final route = _buildRoute(paywall.presentation, routeBuilder);

    void dismissRoute() {
      if (route.isActive && context.mounted) {
        Navigator.of(context).removeRoute(route);
      }
    }

    _currentDismiss = dismissRoute;

    route.popped.then((_) {
      if (identical(_currentDismiss, dismissRoute)) {
        _currentDismiss = null;
      }
    });

    await Navigator.of(context).push(route);
  }

  static Route<void> _buildRoute(
    PaywallPresentationConfig presentation,
    WidgetBuilder routeBuilder,
  ) {
    if (presentation.style == PaywallPresentationStyle.system) {
      return Platform.isIOS
          ? CupertinoPageRoute<void>(builder: routeBuilder)
          : MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: routeBuilder,
            );
    }

    final transitionDuration =
        presentation.style == PaywallPresentationStyle.none
        ? Duration.zero
        : presentation.duration;

    return PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: transitionDuration,
      reverseTransitionDuration: transitionDuration,
      pageBuilder: (context, animation, secondaryAnimation) =>
          routeBuilder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        switch (presentation.style) {
          case PaywallPresentationStyle.slideUp:
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: presentation.curve,
                    ),
                  ),
              child: child,
            );
          case PaywallPresentationStyle.slideDown:
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, -0.12),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: presentation.curve,
                    ),
                  ),
              child: child,
            );
          case PaywallPresentationStyle.slideLeft:
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0.12, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: presentation.curve,
                    ),
                  ),
              child: child,
            );
          case PaywallPresentationStyle.none:
            return child;
          case PaywallPresentationStyle.system:
            return child;
        }
      },
    );
  }
}

class _PaywallViewState extends State<PaywallView> {
  late final PreparedPaywallController _preparedController;
  late final bool _ownsPreparedController;
  bool _didHandleDismiss = false;

  bool get _allowsSystemBackDismiss =>
      widget.paywall.presentation.allowsSystemBack;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowsSystemBackDismiss,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _handleDismiss(popRoute: false);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<bool>(
          valueListenable: _preparedController.isLoading,
          builder: (context, isLoading, _) {
            return Stack(
              children: [
                Positioned.fill(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(
                        color:
                            PreparedPaywallController.fallbackBackgroundColor,
                        child: SizedBox.expand(),
                      ),
                      WebViewWidget(controller: _preparedController.controller),
                      IgnorePointer(
                        child: ColoredBox(
                          color: PreparedPaywallController
                              .defaultBackgroundColor
                              .withValues(alpha: 0.001),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLoading)
                  Positioned.fill(
                    child: Container(
                      color: const Color(0xFF121212),
                      child: Shimmer.fromColors(
                        baseColor: Colors.grey[900]!,
                        highlightColor: Colors.grey[800]!,
                        child: Column(
                          children: [
                            Container(
                              height: 300,
                              width: double.infinity,
                              color: Colors.white,
                            ),
                            const SizedBox(height: 40),
                            Container(
                              height: 30,
                              width: 250,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Container(
                              height: 15,
                              width: 200,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const Spacer(),
                            Container(
                              margin: const EdgeInsets.all(24),
                              height: 55,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (widget.paywall.presentation.allowsEdgeSwipe)
                  EdgeSwipeDismissOverlay(
                    onDismiss: () => _handleDismiss(popRoute: true),
                    onDragChanged: (_) {},
                    onDragEnded: () {},
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Animation<double>? _routeAnimation;

  void _handleRouteAnimation(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      _preparedController.presentationCompleted(
        isVisible: () =>
            mounted &&
            !_didHandleDismiss &&
            ModalRoute.of(context)?.isCurrent == true,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleRouteAnimation);
      _routeAnimation = animation;
      animation?.addStatusListener(_handleRouteAnimation);
    }
    if (animation == null || animation.status == AnimationStatus.completed) {
      _handleRouteAnimation(AnimationStatus.completed);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimation);
    unawaited(AndroidPaywallBackBridge.setPaywallVisible(false));
    _preparedController.deactivate();
    if (_ownsPreparedController || widget.disposeProvidedPreparedController) {
      _preparedController.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(AndroidPaywallBackBridge.setPaywallVisible(true));
    _ownsPreparedController = widget.preparedController == null;
    _preparedController =
        widget.preparedController ??
        PreparedPaywallController(paywall: widget.paywall);
    _preparedController.activate(
      PaywallCallbacks(
        onShown: widget.onShown,
        onPurchase: widget.onPurchase,
        onRestore: widget.onRestore,
        onOpenUrl: widget.onOpenUrl,
        onOpenTerms: widget.onOpenTerms,
        onOpenPrivacy: widget.onOpenPrivacy,
        onDismiss: (durationInSeconds) => _handleDismiss(
          durationInSeconds: durationInSeconds,
          popRoute: true,
        ),
      ),
    );

    _preparedController.warm().catchError((Object error) {
      MySuperWallLogging.logger.w(
        '[MySuperWall] Failed to warm paywall view: $error',
      );
    });
  }

  void _handleDismiss({int? durationInSeconds, required bool popRoute}) {
    if (_didHandleDismiss) {
      return;
    }

    _didHandleDismiss = true;
    final visibleDuration =
        durationInSeconds ?? _preparedController.activeDurationInSeconds;
    _preparedController.deactivate();
    if (MySuperWallClient.isInitialized)
      MySuperWallClient.instance.trackDismiss(
        paywallId: widget.paywall.id,
        triggerKey: widget.paywall.triggerKey,
        duration: visibleDuration,
        abVariant: widget.paywall.abVariant,
      );

    if (popRoute && mounted) {
      Navigator.of(context).pop();
    }
    widget.onDismiss?.call();
  }
}
