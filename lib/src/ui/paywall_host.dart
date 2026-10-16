import '../services/sdk_logging.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../mysuperwall_client.dart';
import '../models/paywall_presentation.dart';
import 'android_paywall_back_bridge.dart';
import 'edge_swipe_dismiss_overlay.dart';
import 'paywall_session.dart';

class MySuperWallHost extends StatefulWidget {
  final Widget child;

  const MySuperWallHost({super.key, required this.child});

  @override
  State<MySuperWallHost> createState() => _MySuperWallHostState();
}

class _HostLoadingOverlay extends StatelessWidget {
  const _HostLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: false,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.54),
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Offset preparedPaywallBeginFractionalOffset(
  PaywallPresentationConfig presentation,
) {
  switch (presentation.style) {
    case PaywallPresentationStyle.slideLeft:
      return const Offset(0.12, 0);
    case PaywallPresentationStyle.system:
    case PaywallPresentationStyle.slideUp:
      return const Offset(0, 1);
    case PaywallPresentationStyle.slideDown:
      return const Offset(0, -0.12);
    case PaywallPresentationStyle.none:
      return Offset.zero;
  }
}

class _MySuperWallHostState extends State<MySuperWallHost>
    with WidgetsBindingObserver {
  static bool _hasLoggedMounted = false;
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

  MapEntry<String, PreparedPaywallController>? _activePreparedEntry() {
    if (!MySuperWallClient.isInitialized) {
      return null;
    }

    final activeTriggerKey = MySuperWallClient.activePreparedTriggerKey;
    if (activeTriggerKey == null) {
      return null;
    }

    return MySuperWallClient.instance.preparedPaywallControllers.entries
        .cast<MapEntry<String, PreparedPaywallController>?>()
        .firstWhere(
          (entry) => entry?.key == activeTriggerKey,
          orElse: () => null,
        );
  }

  bool _dismissActivePreparedPaywallIfAllowed() {
    final activeEntry = _activePreparedEntry();
    if (activeEntry == null) {
      return false;
    }

    if (!activeEntry.value.paywall.presentation.allowsSystemBack) {
      return false;
    }

    _logger.i(
      '[MySuperWall] System back dismissed prepared paywall "${activeEntry.key}".',
    );
    activeEntry.value.dismiss();
    return true;
  }

  Future<void> _handleNativeDismissRequest() async {
    if (!MySuperWallClient.isInitialized) {
      return;
    }

    MySuperWallClient.instance.dismiss();
  }

  Future<void> _syncAndroidPaywallVisibility() async {
    final activeEntry = _activePreparedEntry();
    await AndroidPaywallBackBridge.setPaywallVisible(activeEntry != null);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        MySuperWallClient.preparedPoolListenable,
        MySuperWallClient.activePreparedTriggerKeyListenable,
        MySuperWallClient.hostLoadingOverlayListenable,
      ]),
      builder: (context, _) {
        if (!MySuperWallClient.isInitialized) {
          return widget.child;
        }

        final showLoadingOverlay =
            MySuperWallClient.hostLoadingOverlayListenable.value;
        final activeEntry = _activePreparedEntry();

        return Stack(
          fit: StackFit.expand,
          children: [
            // Keep native WebViews mounted before their first presentation.
            // Offstage or zero opacity would prevent useful pre-painting.
            for (final entry
                in MySuperWallClient
                    .instance
                    .preparedPaywallControllers
                    .entries)
              if (entry.key != activeEntry?.key)
                _PreparedLayer(
                  key: ObjectKey(entry.value),
                  controller: entry.value,
                  isActive: false,
                ),
            KeyedSubtree(
              key: const ValueKey('mysuperwall_host_content'),
              child: widget.child,
            ),
            if (activeEntry != null)
              _PreparedLayer(
                key: ObjectKey(activeEntry.value),
                controller: activeEntry.value,
                isActive: true,
              ),
            if (showLoadingOverlay) const _HostLoadingOverlay(),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    MySuperWallClient.activePreparedTriggerKeyListenable.removeListener(
      _handlePreparedPaywallVisibilityChanged,
    );
    MySuperWallClient.hostLoadingOverlayListenable.removeListener(
      _handlePreparedPaywallVisibilityChanged,
    );
    unawaited(AndroidPaywallBackBridge.setPaywallVisible(false));
    WidgetsBinding.instance.removeObserver(this);
    MySuperWallClient.registerHostMounted(false);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    AndroidPaywallBackBridge.configure(
      onDismissRequested: _handleNativeDismissRequest,
    );
    WidgetsBinding.instance.addObserver(this);
    MySuperWallClient.registerHostMounted(true);
    MySuperWallClient.activePreparedTriggerKeyListenable.addListener(
      _handlePreparedPaywallVisibilityChanged,
    );
    MySuperWallClient.hostLoadingOverlayListenable.addListener(
      _handlePreparedPaywallVisibilityChanged,
    );
    unawaited(_syncAndroidPaywallVisibility());
    if (!_hasLoggedMounted) {
      _hasLoggedMounted = true;
      _logger.i('[MySuperWall] Host mounted and ready for prepared paywalls.');
    }
  }

  void _handlePreparedPaywallVisibilityChanged() {
    unawaited(_syncAndroidPaywallVisibility());
  }

  @override
  Future<bool> didPopRoute() async {
    if (_dismissActivePreparedPaywallIfAllowed()) {
      return true;
    }
    return false;
  }
}

class _PreparedLayer extends StatefulWidget {
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

  final PreparedPaywallController controller;
  final bool isActive;
  const _PreparedLayer({
    super.key,
    required this.controller,
    required this.isActive,
  });

  @override
  State<_PreparedLayer> createState() => _PreparedLayerState();
}

class _PreparedLayerState extends State<_PreparedLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transitionController;
  double _dragOffset = 0;
  bool _isPreparingPresentation = false;
  int _animationRequest = 0;
  int _lastPresentationSession = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _PreparedLayer._logger.i(
          '[MySuperWall] Prepared paywall layer active for trigger "${widget.controller.paywall.triggerKey}".',
        );
      });
    }

    final presentation = widget.controller.paywall.presentation;

    final paywallContent = Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(
          color: PreparedPaywallController.fallbackBackgroundColor,
          child: SizedBox.expand(),
        ),
        WebViewWidget(controller: widget.controller.controller),
        IgnorePointer(
          child: ColoredBox(
            color: PreparedPaywallController.defaultBackgroundColor.withValues(
              alpha: 0.001,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (widget.isActive &&
            widget.controller.paywall.presentation.allowsEdgeSwipe)
          EdgeSwipeDismissOverlay(
            onDismiss: widget.controller.dismiss,
            onDragChanged: (distance) {
              if (!mounted) return;
              setState(() {
                _dragOffset = distance;
              });
            },
            onDragEnded: () {
              if (!mounted) return;
              setState(() {
                _dragOffset = 0;
              });
            },
          ),
      ],
    );

    return ExcludeSemantics(
      excluding: !widget.isActive || _isPreparingPresentation,
      child: IgnorePointer(
        ignoring: !widget.isActive || _isPreparingPresentation,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return AnimatedBuilder(
              animation: _transitionController,
              child: paywallContent,
              builder: (context, child) {
                final curve = _dragOffset > 0
                    ? Curves.linear
                    : _buildCurve(presentation);
                final value = curve.transform(_transitionController.value);
                final fractionalOffset = Offset.lerp(
                  _buildFractionalBeginOffset(presentation),
                  Offset.zero,
                  value,
                )!;
                final translatedOffset = Offset(
                  (fractionalOffset.dx * constraints.maxWidth) + _dragOffset,
                  fractionalOffset.dy * constraints.maxHeight,
                );

                return Opacity(
                  opacity: !widget.isActive || _isPreparingPresentation
                      ? 0.001
                      : _buildOpacity(presentation, value),
                  child: Transform.translate(
                    offset: !widget.isActive || _isPreparingPresentation
                        ? Offset.zero
                        : translatedOffset,
                    child: child,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _PreparedLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    final nextPresentationSession = widget.controller.presentationSession;
    final shouldStartPresentation =
        widget.isActive &&
        (!oldWidget.isActive ||
            nextPresentationSession != _lastPresentationSession);

    if (shouldStartPresentation) {
      _startPresentationAnimation(waitForMount: false);
      return;
    }

    if (!widget.isActive && oldWidget.isActive) {
      _animationRequest++;
      _isPreparingPresentation = false;
      _transitionController.stop();
      _transitionController.value = 0;
      _dragOffset = 0;
    }
  }

  @override
  void dispose() {
    _animationRequest++;
    _transitionController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _lastPresentationSession = widget.controller.presentationSession;
    _transitionController = AnimationController(
      vsync: this,
      value: widget.isActive ? 0 : 1,
      duration: _buildDuration(widget.controller.paywall.presentation),
    );
    _transitionController.addStatusListener(_handleAnimationStatus);
    if (widget.isActive) {
      _startPresentationAnimation();
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        widget.isActive &&
        !_isPreparingPresentation) {
      widget.controller.presentationCompleted(
        isVisible: () =>
            mounted && widget.isActive && !_isPreparingPresentation,
      );
    }
  }

  void _startPresentationAnimation({bool waitForMount = true}) {
    final request = ++_animationRequest;
    final presentation = widget.controller.paywall.presentation;
    final duration = _buildDuration(presentation);
    _lastPresentationSession = widget.controller.presentationSession;
    _transitionController.duration = duration;
    _dragOffset = 0;

    if (duration == Duration.zero) {
      _isPreparingPresentation = false;
      _transitionController.value = 1;
      widget.controller.presentationCompleted(
        isVisible: () =>
            mounted && widget.isActive && !_isPreparingPresentation,
      );
      return;
    }

    if (!waitForMount) {
      _isPreparingPresentation = false;
      _transitionController.forward(from: 0);
      return;
    }

    _isPreparingPresentation = true;
    _transitionController.value = 0;
    unawaited(_animateAfterMount(request));
  }

  Future<void> _animateAfterMount(int request) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || request != _animationRequest || !widget.isActive) {
      return;
    }
    setState(() {
      _isPreparingPresentation = false;
    });
    _transitionController.forward(from: 0);
  }

  Offset _buildFractionalBeginOffset(PaywallPresentationConfig presentation) {
    return preparedPaywallBeginFractionalOffset(presentation);
  }

  double _buildOpacity(
    PaywallPresentationConfig presentation,
    double progress,
  ) {
    switch (presentation.style) {
      case PaywallPresentationStyle.slideLeft:
      case PaywallPresentationStyle.system:
      case PaywallPresentationStyle.slideUp:
      case PaywallPresentationStyle.slideDown:
        return (0.92 + (0.08 * progress)).clamp(0, 1);
      case PaywallPresentationStyle.none:
        return 1;
    }
  }

  Curve _buildCurve(PaywallPresentationConfig presentation) {
    if (!widget.isActive) {
      return Curves.easeInCubic;
    }

    switch (presentation.style) {
      case PaywallPresentationStyle.none:
        return Curves.linear;
      case PaywallPresentationStyle.system:
      case PaywallPresentationStyle.slideLeft:
      case PaywallPresentationStyle.slideUp:
      case PaywallPresentationStyle.slideDown:
        return presentation.curve;
    }
  }

  Duration _buildDuration(PaywallPresentationConfig presentation) {
    if (!widget.isActive) {
      return const Duration(milliseconds: 140);
    }

    switch (presentation.style) {
      case PaywallPresentationStyle.none:
        return Duration.zero;
      case PaywallPresentationStyle.system:
      case PaywallPresentationStyle.slideLeft:
      case PaywallPresentationStyle.slideUp:
      case PaywallPresentationStyle.slideDown:
        return presentation.duration;
    }
  }
}
