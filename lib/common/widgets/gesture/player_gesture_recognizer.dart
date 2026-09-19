import 'dart:ui' show Offset;

import 'package:flutter/gestures.dart'
    show
        GestureDisposition,
        PointerDownEvent,
        PointerDeviceKind,
        PointerEvent,
        PointerMoveEvent,
        PointerUpEvent,
        PointerCancelEvent,
        ScaleGestureRecognizer,
        VerticalDragGestureRecognizer;
import 'package:PiliPlus/common/widgets/gesture/player_gesture_constants.dart';
import 'package:PiliPlus/plugin/pl_player/utils/player_touch_trace.dart';

typedef PlayerPointerDownFilter = bool Function(PointerDownEvent event);

enum PlayerSinglePointerGestureAction {
  horizontal,
  brightness,
  volume,
  fullScreen,
}

class PlayerSinglePointerGestureDecision {
  const PlayerSinglePointerGestureDecision({
    required this.startPosition,
    required this.action,
  });

  final Offset startPosition;
  final PlayerSinglePointerGestureAction action;
}

typedef PlayerSinglePointerMoveFilter =
    PlayerSinglePointerGestureDecision? Function(
      Offset startPosition,
      Offset delta,
      PointerDeviceKind kind,
    );

mixin PlayerGestureMixin {
  PlayerPointerDownFilter? pointerDownFilter;

  bool isPlayerPointerAllowed(PointerDownEvent event) =>
      pointerDownFilter?.call(event) ?? true;
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

  PlayerSinglePointerMoveFilter? singlePointerMoveFilter;
  final Map<int, Offset> _singlePointerStartPositions = <int, Offset>{};
  final Map<int, Offset> _singlePointerStartGlobalPositions = <int, Offset>{};
  final Map<int, Offset> _singlePointerDownPositions = <int, Offset>{};
  final Map<int, PlayerSinglePointerGestureDecision?> _singlePointerDecisions =
      <int, PlayerSinglePointerGestureDecision?>{};
  final Set<int> _debugMoveLoggedPointers = <int>{};
  final Set<int> _mouseDirectionPending = <int>{};
  bool _gestureAccepted = false;
  bool _multiPointerSeen = false;
  bool _cancelledCurrentGesture = false;
  bool _gestureEndedAborted = false;
  PlayerSinglePointerGestureDecision? _currentSinglePointerDecision;

  bool get shouldCancelCurrentGesture =>
      _cancelledCurrentGesture || _multiPointerSeen || _gestureEndedAborted;

  Offset? get initialPointerDownPosition => _singlePointerDownPositions.isEmpty
      ? null
      : _singlePointerDownPositions.values.first;

  PlayerSinglePointerGestureDecision? get singlePointerDecision {
    if (_currentSinglePointerDecision case final decision?) return decision;
    for (final decision in _singlePointerDecisions.values) {
      if (decision != null) return decision;
    }
    return null;
  }

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      super.isPointerAllowed(event) && isPlayerPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_singlePointerDownPositions.isEmpty) {
      _currentSinglePointerDecision = null;
      _cancelledCurrentGesture = false;
      _gestureEndedAborted = false;
    } else {
      _multiPointerSeen = true;
      _cancelledCurrentGesture = true;
      _gestureEndedAborted = true;
    }
    _singlePointerDownPositions[event.pointer] = event.localPosition;
    if (event.kind == PointerDeviceKind.mouse) {
      // ScaleGestureRecognizer uses the framework's fixed 2px precise-pointer
      // pan slop for mouse events. Keep the recognizer from forwarding those
      // sub-threshold moves until the player direction gate has had the same
      // 18px qualification window as touch input.
      _mouseDirectionPending.add(event.pointer);
    }
    PlayerTouchTrace.message(
      'recognizer add-pointer pointer=${event.pointer} position=${event.localPosition}',
    );
    super.addAllowedPointer(event);
    _singlePointerStartPositions[event.pointer] = event.localPosition;
    _singlePointerStartGlobalPositions[event.pointer] = event.position;
    _singlePointerDecisions.remove(event.pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) {
      _cancelledCurrentGesture = true;
      _gestureEndedAborted = true;
      PlayerTouchTrace.message(
        'recognizer cancel-pointer pointer=${event.pointer}',
      );
    }
    if (event is PointerMoveEvent &&
        _debugMoveLoggedPointers.add(event.pointer)) {
      PlayerTouchTrace.message(
        'recognizer first-move pointer=${event.pointer} pointerCount=$pointerCount '
        'accepted=$_gestureAccepted filter=${singlePointerMoveFilter != null}',
      );
    }
    if (event is PointerMoveEvent &&
        event.kind == PointerDeviceKind.mouse &&
        _mouseDirectionPending.contains(event.pointer)) {
      final start = _singlePointerStartGlobalPositions[event.pointer];
      if (start != null) {
        final displacement = event.position - start;
        if (displacement.distance <= kPlayerDirectionQualificationSlop) {
          return;
        }
        _mouseDirectionPending.remove(event.pointer);
      }
    }
    if (event is PointerMoveEvent &&
        pointerCount == 1 &&
        !_gestureAccepted &&
        !_multiPointerSeen) {
      final startPosition = _singlePointerStartPositions[event.pointer];
      final globalStartPosition =
          _singlePointerStartGlobalPositions[event.pointer];
      if (startPosition != null &&
          globalStartPosition != null &&
          !_singlePointerDecisions.containsKey(event.pointer)) {
        final delta = event.position - globalStartPosition;
        // Do not classify on a tap-sized wobble. Direction must be evident at
        // the effective movement threshold used by player callbacks.
        if (delta.distance > kPlayerDirectionQualificationSlop &&
            singlePointerMoveFilter != null) {
          final decision = singlePointerMoveFilter!(
            startPosition,
            delta,
            event.kind,
          );
          _singlePointerDecisions[event.pointer] = decision;
          _currentSinglePointerDecision = decision;
          _singlePointerStartPositions.remove(event.pointer);
          _singlePointerStartGlobalPositions.remove(event.pointer);
          if (decision == null) {
            resolvePointer(event.pointer, GestureDisposition.rejected);
            return;
          }
          // The player shares the pointer with an ancestor Scrollable. Once
          // the direction filter has classified a single-pointer move as a
          // player gesture, claim the arena immediately; merely forwarding
          // to ScaleGestureRecognizer lets the ancestor win the same move.
          PlayerTouchTrace.message(
            'recognizer accept-single-pointer pointer=${event.pointer} '
            'action=${decision.action}',
          );
          resolvePointer(event.pointer, GestureDisposition.accepted);
        }
      }
    }
    super.handleEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _singlePointerStartPositions.remove(event.pointer);
      _singlePointerStartGlobalPositions.remove(event.pointer);
      _singlePointerDownPositions.remove(event.pointer);
      _singlePointerDecisions.remove(event.pointer);
      _mouseDirectionPending.remove(event.pointer);
      _debugMoveLoggedPointers.remove(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    _gestureAccepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    PlayerTouchTrace.message(
      'recognizer reject pointer=$pointer accepted=$_gestureAccepted',
    );
    _singlePointerStartPositions.remove(pointer);
    _singlePointerStartGlobalPositions.remove(pointer);
    _singlePointerDownPositions.remove(pointer);
    _singlePointerDecisions.remove(pointer);
    _mouseDirectionPending.remove(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    PlayerTouchTrace.message(
      'recognizer stop-last-pointer pointer=$pointer accepted=$_gestureAccepted',
    );
    _gestureAccepted = false;
    _multiPointerSeen = false;
    _cancelledCurrentGesture = false;
    _singlePointerStartPositions.clear();
    _singlePointerStartGlobalPositions.clear();
    _singlePointerDownPositions.clear();
    _singlePointerDecisions.clear();
    _mouseDirectionPending.clear();
    _debugMoveLoggedPointers.clear();
    _currentSinglePointerDecision = null;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void dispose() {
    _singlePointerStartPositions.clear();
    _singlePointerStartGlobalPositions.clear();
    _singlePointerDownPositions.clear();
    _singlePointerDecisions.clear();
    _mouseDirectionPending.clear();
    _debugMoveLoggedPointers.clear();
    _currentSinglePointerDecision = null;
    _multiPointerSeen = false;
    _cancelledCurrentGesture = false;
    _gestureEndedAborted = false;
    super.dispose();
  }
}

class PlayerVerticalDragGestureRecognizer extends VerticalDragGestureRecognizer
    with PlayerGestureMixin {
  PlayerVerticalDragGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  @override
  bool isPointerAllowed(PointerEvent event) {
    return super.isPointerAllowed(event) &&
        event is PointerDownEvent &&
        isPlayerPointerAllowed(event);
  }
}
