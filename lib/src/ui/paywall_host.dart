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
import 'paywall_motion.dart';

class MySuperWallHost extends StatefulWidget {
  final Widget child;

  /// Disable automatic presentation until the app is ready (for example after onboarding).
  final bool lifecycleReady;

  const MySuperWallHost({
    super.key,
    required this.child,
    this.lifecycleReady = true,
  });

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
  return PaywallMotion.beginFraction(presentation.style);
}

class _MySuperWallHostState extends State<MySuperWallHost>
    with WidgetsBindingObserver {
  static bool _hasLoggedMounted = false;
  static _MySuperWallHostState? _lifecycleOwner;
  Timer? _lifecycleTimer;
  bool _lifecycleRunning = false;

  BuildContext? _navigatorContext() {
    BuildContext? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        // Navigator.of must receive a descendant, not the Navigator element itself.
        found = (element.state as NavigatorState).overlay?.context;
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found ?? Navigator.maybeOf(context)?.overlay?.context;
  }

  Future<void> _runLifecycle({bool refreshSignals = true}) async {
    if (!mounted ||
        !MySuperWallClient.isInitialized ||
        _lifecycleRunning ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _lifecycleOwner ??= this;
    if (!identical(_lifecycleOwner, this)) return;
    _lifecycleRunning = true;
    try {
      if (refreshSignals) {
        await MySuperWallClient.instance.updateLifecycleSignals();
      }
      if (!mounted) return;
      final client = MySuperWallClient.instance;
      if (!widget.lifecycleReady ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        client.reportLifecycleWaiting(
          !widget.lifecycleReady
              ? 'app_not_ready'
              : !client.hasPresentationHandlers
              ? 'billing_handlers_unavailable'
              : 'app_backgrounded',
        );
        return;
      }
      final navigatorContext = _navigatorContext();
      if (navigatorContext == null || !navigatorContext.mounted) return;
      bool ready() =>
          mounted &&
          widget.lifecycleReady &&
          MySuperWallClient.isInitialized &&
          identical(MySuperWallClient.instance, client) &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (await client.handlePendingFollowUps(
        navigatorContext,
        canPresent: ready,
      )) {
        return;
      }
      if (!client.hasPresentationHandlers) {
        client.reportLifecycleWaiting('billing_handlers_unavailable');
        return;
      }
      await client.handleLifecycleTriggers(
        navigatorContext,
        canPresent: () =>
            mounted &&
            widget.lifecycleReady &&
            MySuperWallClient.isInitialized &&
            identical(MySuperWallClient.instance, client) &&
            client.hasPresentationHandlers &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
    } catch (error) {
      _logger.w('[MySuperWall] Lifecycle processing failed: $error');
    } finally {
      _lifecycleRunning = false;
    }
  }

  @override
  void didUpdateWidget(covariant MySuperWallHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lifecycleReady && !oldWidget.lifecycleReady) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_runLifecycle()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_updateLifecycleState(state));
  }

  Future<void> _updateLifecycleState(AppLifecycleState state) async {
    if (!mounted || !MySuperWallClient.isInitialized) return;
    _lifecycleOwner ??= this;
    if (!identical(_lifecycleOwner, this)) return;
    final client = MySuperWallClient.instance;
    try {
      if (state == AppLifecycleState.resumed) {
        await client.updateLifecycleSignals(foreground: true);
        if (mounted) await _runLifecycle(refreshSignals: false);
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        await client.updateLifecycleSignals(background: true);
      }
    } catch (error) {
      _logger.w('[MySuperWall] Lifecycle state update failed: $error');
    }
  }

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
            // Pre-paint once, then detach hidden native views to stop GPU work.
            for (final entry
                in MySuperWallClient
                    .instance
                    .preparedPaywallControllers
                    .entries)
              if (entry.key != activeEntry?.key)
                ValueListenableBuilder<bool>(
                  key: ObjectKey(entry.value),
                  valueListenable: entry.value.isLoading,
                  builder: (context, loading, _) => !loading
                      ? const SizedBox.shrink()
                      : _PreparedLayer(
                          controller: entry.value,
                          isActive: false,
                        ),
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
    _lifecycleTimer?.cancel();
    MySuperWallClient.registerHostContextProvider(this, null);
    if (identical(_lifecycleOwner, this) && MySuperWallClient.isInitialized) {
      unawaited(
        MySuperWallClient.instance
            .updateLifecycleSignals(background: true)
            .catchError((Object error) {
              _logger.w(
                '[MySuperWall] Could not close lifecycle interval: $error',
              );
            }),
      );
    }
    if (identical(_lifecycleOwner, this)) _lifecycleOwner = null;
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
    MySuperWallClient.registerHostContextProvider(
      this,
      () => mounted && widget.lifecycleReady ? _navigatorContext() : null,
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_runLifecycle()),
    );
    _lifecycleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_runLifecycle());
      }
    });
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
  bool _isDismissing = false;

  Future<void> _animateDismiss() async {
    if (!mounted || !widget.isActive || _isDismissing) return;
    setState(() {
      _isDismissing = true;
    });
    try {
      if (widget.controller.paywall.presentation.style ==
              PaywallPresentationStyle.none ||
          WidgetsBinding
              .instance
              .platformDispatcher
              .accessibilityFeatures
              .disableAnimations) {
        _transitionController.value = 0;
      } else {
        await _transitionController.reverse().orCancel;
      }
    } on TickerCanceled {
      // Host removal/replacement cancels its transition safely.
    }
  }

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
      excluding: !widget.isActive || _isPreparingPresentation || _isDismissing,
      child: IgnorePointer(
        ignoring: !widget.isActive || _isPreparingPresentation || _isDismissing,
        child: PaywallMotion(
          presentation: presentation,
          animation: _transitionController,
          dragOffset: _dragOffset,
          hidden: !widget.isActive || _isPreparingPresentation,
          child: paywallContent,
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
    widget.controller.animateDismiss = null;
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
    widget.controller.animateDismiss = _animateDismiss;
    _transitionController.addStatusListener(_handleAnimationStatus);
    if (widget.isActive) {
      _startPresentationAnimation();
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        widget.isActive &&
        !_isPreparingPresentation &&
        !_isDismissing) {
      widget.controller.presentationCompleted(
        isVisible: () =>
            mounted &&
            widget.isActive &&
            !_isPreparingPresentation &&
            !_isDismissing,
      );
    }
  }

  void _startPresentationAnimation({bool waitForMount = true}) {
    final request = ++_animationRequest;
    _isDismissing = false;
    final presentation = widget.controller.paywall.presentation;
    final duration =
        WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations
        ? Duration.zero
        : _buildDuration(presentation);
    _lastPresentationSession = widget.controller.presentationSession;
    _transitionController.duration = duration;
    _dragOffset = 0;

    if (duration == Duration.zero) {
      _isPreparingPresentation = false;
      _transitionController.value = 1;
      widget.controller.presentationCompleted(
        isVisible: () =>
            mounted &&
            widget.isActive &&
            !_isPreparingPresentation &&
            !_isDismissing,
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

  Duration _buildDuration(PaywallPresentationConfig presentation) {
    if (presentation.style == PaywallPresentationStyle.none) {
      return Duration.zero;
    }
    if (presentation.style == PaywallPresentationStyle.system) {
      return PaywallPresentationConfig.defaults.duration;
    }
    return presentation.duration;
  }
}
