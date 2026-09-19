import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:PiliPlus/common/widgets/gesture/player_gesture_constants.dart';
import 'package:PiliPlus/plugin/pl_player/utils/player_touch_trace.dart';

class ImmediateTapGestureRecognizer extends OneSequenceGestureRecognizer {
  ImmediateTapGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter = _defaultButtonAcceptBehavior,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onTap,
  });

  static bool _defaultButtonAcceptBehavior(int buttons) =>
      buttons == kPrimaryButton;

  GestureTapDownCallback? onTapDown;

  GestureTapUpCallback? onTapUp;

  GestureTapCancelCallback? onTapCancel;

  GestureTapCallback? onTap;

  PointerUpEvent? _up;
  int? _activePointer;
  bool _sentTapDown = false;
  bool _wonArena = false;
  Offset? _initialPosition;
  PointerDeviceKind? _activeKind;

  int get lastPointer => _activePointer ?? _up?.pointer ?? -1;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _activePointer == null && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _reset(event.pointer);
    _handleTapDown(event);
    _initialPosition = event.position;
    _activeKind = event.kind;
    PlayerTouchTrace.event(
      stage: 'ImmediateTapGestureRecognizer tap down',
      pointer: event.pointer,
      position: event.position,
      kind: event.kind,
    );
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _activePointer) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }

    if (event is PointerMoveEvent) {
      _handlePointerMove(event);
    } else if (event is PointerUpEvent) {
      _up = event;
      _handlePointerUp(event);
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
    }

    stopTrackingIfPointerNoLongerDown(event);
  }

  void _handleTapDown(PointerDownEvent event) {
    if (_sentTapDown) return;
    _sentTapDown = true;

    if (onTapDown != null) {
      final details = TapDownDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapDown', () => onTapDown!(details));
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if ((event.position - _initialPosition!).distanceSquared >
        kPlayerTapSlop * kPlayerTapSlop) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_wonArena) {
      _handleTapUp(event);
    }
  }

  void _handleTapUp(PointerUpEvent event) {
    PlayerTouchTrace.event(
      stage: 'ImmediateTapGestureRecognizer tap成立',
      pointer: event.pointer,
      position: event.position,
      kind: event.kind,
    );
    if (onTapUp != null) {
      final details = TapUpDetails(
        globalPosition: event.position,
        localPosition: event.localPosition,
        kind: event.kind,
      );
      invokeCallback<void>('onTapUp', () => onTapUp!(details));
    }

    if (onTap != null) {
      invokeCallback<void>('onTap', onTap!);
    }

    _reset();
  }

  void _cancelGesture(String reason) {
    final position = _up?.position ?? _initialPosition;
    final kind = _up?.kind ?? _activeKind;
    if (position != null && kind != null) {
      PlayerTouchTrace.event(
        stage: 'ImmediateTapGestureRecognizer tap取消 reason=$reason',
        pointer: lastPointer,
        position: position,
        kind: kind,
      );
    }
    if (_sentTapDown && onTapCancel != null) {
      invokeCallback<void>('onTapCancel: $reason', onTapCancel!);
    }
    _reset();
  }

  void _reset([int? pointer]) {
    _activePointer = pointer;
    _up = null;
    _sentTapDown = false;
    _wonArena = false;
    _activeKind = null;
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);

    if (pointer == _activePointer) {
      _wonArena = true;

      if (_up != null) {
        _handleTapUp(_up!);
      }
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);

    if (pointer == _activePointer) {
      _cancelGesture('gesture rejected by arena');
      stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _initialPosition = null;
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (_wonArena && disposition == GestureDisposition.rejected) {
      _cancelGesture('spontaneous');
    }
    super.resolve(disposition);
  }

  @override
  String get debugDescription => 'immediate tap';

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('activePointer', _activePointer))
      ..add(
        FlagProperty(
          'sentTapDown',
          value: _sentTapDown,
          ifTrue: 'has sentTapDown',
        ),
      )
      ..add(FlagProperty('wonArena', value: _wonArena, ifTrue: 'wonArena'))
      ..add(
        DiagnosticsProperty<PointerUpEvent>(
          'pointerUpEvent',
          _up,
          defaultValue: null,
        ),
      );
  }
}
