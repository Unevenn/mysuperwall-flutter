import 'dart:io';

import 'package:flutter/material.dart';

class EdgeSwipeDismissOverlay extends StatefulWidget {
  const EdgeSwipeDismissOverlay({
    super.key,
    required this.onDismiss,
    required this.onDragChanged,
    required this.onDragEnded,
    this.width = 24,
    this.dismissDistance = 72,
    this.dismissVelocity = 700,
  });

  final VoidCallback onDismiss;
  final ValueChanged<double> onDragChanged;
  final VoidCallback onDragEnded;
  final double width;
  final double dismissDistance;
  final double dismissVelocity;

  @override
  State<EdgeSwipeDismissOverlay> createState() =>
      _EdgeSwipeDismissOverlayState();
}

class _EdgeSwipeDismissOverlayState extends State<EdgeSwipeDismissOverlay> {
  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: widget.width,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) {
            _dragDistance = 0;
            widget.onDragChanged(0);
          },
          onHorizontalDragUpdate: (details) {
            if (details.delta.dx > 0) {
              _dragDistance += details.delta.dx;
              widget.onDragChanged(_dragDistance);
            }
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (_dragDistance >= widget.dismissDistance ||
                velocity >= widget.dismissVelocity) {
              widget.onDismiss();
            } else {
              widget.onDragEnded();
            }
            _dragDistance = 0;
          },
          onHorizontalDragCancel: () {
            _dragDistance = 0;
            widget.onDragEnded();
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
