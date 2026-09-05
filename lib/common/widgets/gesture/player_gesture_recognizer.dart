import 'package:flutter/gestures.dart'
    show
        kTouchSlop,
        GestureRecognizer,
        PointerDeviceKind,
        RecognizerCallback,
        ScaleGestureRecognizer,
        VerticalDragGestureRecognizer;

mixin PlayerGestureMixin on GestureRecognizer {
  bool isPosAllowed = true;

  @override
  T? invokeCallback<T>(
    String name,
    RecognizerCallback<T> callback, {
    String Function()? debugReport,
  }) {
    if (!isPosAllowed) return null;
    return super.invokeCallback(name, callback, debugReport: debugReport);
  }
}

class PlayerScaleGestureRecognizer extends ScaleGestureRecognizer
    with PlayerGestureMixin {
  PlayerScaleGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
    super.dragStartBehavior,
    super.trackpadScrollCausesScale,
    super.trackpadScrollToScaleFactor,
  });
}

class PlayerVerticalDragGestureRecognizer
    extends VerticalDragGestureRecognizer {
  PlayerVerticalDragGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved.abs() > (deviceTouchSlop ?? kTouchSlop);
}
