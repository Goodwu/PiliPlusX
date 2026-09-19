import 'package:PiliPlus/common/widgets/gesture/player_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/gesture/player_gesture_constants.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestScaleGestureRecognizer extends PlayerScaleGestureRecognizer {
  bool isAllowed(PointerDownEvent event) => isPointerAllowed(event);
}

class _TestVerticalDragGestureRecognizer
    extends PlayerVerticalDragGestureRecognizer {
  bool isAllowed(PointerEvent event) => isPointerAllowed(event);
}

PointerDownEvent _down(
  int pointer, [
  Offset position = Offset.zero,
  PointerDeviceKind kind = PointerDeviceKind.touch,
]) => PointerDownEvent(
  pointer: pointer,
  position: position,
  buttons: kPrimaryButton,
  kind: kind,
);

PointerMoveEvent _move(
  int pointer,
  Offset position, [
  PointerDeviceKind kind = PointerDeviceKind.touch,
]) => PointerMoveEvent(
  pointer: pointer,
  position: position,
  delta: position,
  buttons: kPrimaryButton,
  kind: kind,
);

PointerUpEvent _up(int pointer, Offset position) => PointerUpEvent(
  pointer: pointer,
  position: position,
);

PointerCancelEvent _cancel(int pointer, Offset position) =>
    PointerCancelEvent(pointer: pointer, position: position);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('horizontal seek requires clear horizontal dominance', () {
    expect(
      isPlayerHorizontalSeekDelta(const Offset(30, 9)),
      isTrue,
    );
    expect(
      isPlayerHorizontalSeekDelta(const Offset(30, 10)),
      isFalse,
    );
    expect(
      isPlayerHorizontalSeekDelta(const Offset(30, 15)),
      isFalse,
    );
    expect(
      isPlayerHorizontalSeekDelta(const Offset(8, 0)),
      isTrue,
    );
  });

  test('pointer-down filter rejects before arena admission', () {
    var filterCalls = 0;
    final recognizer = _TestScaleGestureRecognizer()
      ..pointerDownFilter = (_) {
        filterCalls++;
        return false;
      };

    expect(recognizer.isAllowed(_down(1)), isFalse);
    expect(filterCalls, 1);

    recognizer.dispose();
  });

  test('pointer-down qualification is evaluated per pointer', () {
    final recognizer = _TestVerticalDragGestureRecognizer()
      ..onStart = (_) {}
      ..pointerDownFilter = (event) => event.pointer.isEven;

    expect(recognizer.isAllowed(_down(1)), isFalse);
    expect(recognizer.isAllowed(_down(2)), isTrue);

    recognizer.dispose();
  });

  testWidgets('single-pointer direction qualification is evaluated only once', (
    tester,
  ) async {
    var filterCalls = 0;
    PlayerSinglePointerGestureDecision? decision;
    final recognizer = _TestScaleGestureRecognizer()
      ..singlePointerMoveFilter = (startPosition, __, ___) {
        filterCalls++;
        return decision = PlayerSinglePointerGestureDecision(
          startPosition: startPosition,
          action: .horizontal,
        );
      };
    final down = _down(1);

    recognizer.addPointer(down);
    recognizer.handleEvent(down);
    recognizer.handleEvent(_move(1, const Offset(20, 0)));
    recognizer.handleEvent(_move(1, const Offset(40, 0)));
    expect(decision?.startPosition, Offset.zero);
    expect(recognizer.singlePointerDecision, same(decision));
    recognizer.handleEvent(_up(1, const Offset(40, 0)));

    expect(filterCalls, 1);
    recognizer.dispose();
  });

  testWidgets('mouse sub-threshold moves do not reach scale recognizer', (
    tester,
  ) async {
    var filterCalls = 0;
    final recognizer = _TestScaleGestureRecognizer()
      ..singlePointerMoveFilter = (_, __, ___) {
        filterCalls++;
        return const PlayerSinglePointerGestureDecision(
          startPosition: Offset.zero,
          action: PlayerSinglePointerGestureAction.horizontal,
        );
      };
    final down = _down(1, Offset.zero, PointerDeviceKind.mouse);

    recognizer.addPointer(down);
    recognizer.handleEvent(down);
    recognizer.handleEvent(
      _move(1, const Offset(3, 0), PointerDeviceKind.mouse),
    );
    expect(filterCalls, 0);
    recognizer.handleEvent(
      _move(1, const Offset(19, 0), PointerDeviceKind.mouse),
    );
    expect(filterCalls, 1);
    recognizer.handleEvent(
      _up(1, const Offset(19, 0)),
    );
    recognizer.dispose();
  });

  testWidgets(
    'single-pointer arena claim waits for direction qualification slop',
    (
      tester,
    ) async {
      var filterCalls = 0;
      final recognizer = _TestScaleGestureRecognizer()
        ..singlePointerMoveFilter = (_, __, ___) {
          filterCalls++;
          return const PlayerSinglePointerGestureDecision(
            startPosition: Offset.zero,
            action: .horizontal,
          );
        };
      final down = _down(1);

      recognizer.addPointer(down);
      recognizer.handleEvent(down);
      recognizer.handleEvent(_move(1, const Offset(1.5, 0)));
      expect(filterCalls, 0);
      recognizer.handleEvent(_move(1, const Offset(2.1, 0)));
      expect(filterCalls, 0);
      recognizer.handleEvent(_move(1, const Offset(18.1, 0)));
      expect(filterCalls, 1);

      recognizer.dispose();
    },
  );

  testWidgets('direction qualification uses the full displacement', (
    tester,
  ) async {
    PlayerSinglePointerGestureDecision? decision;
    final recognizer = _TestScaleGestureRecognizer()
      ..singlePointerMoveFilter = (startPosition, delta, _) =>
          decision = PlayerSinglePointerGestureDecision(
            startPosition: startPosition,
            action: isPlayerHorizontalSeekDelta(delta)
                ? .horizontal
                : .fullScreen,
          );
    final down = _down(1);

    recognizer.addPointer(down);
    recognizer.handleEvent(down);
    recognizer.handleEvent(_move(1, const Offset(3, 0)));
    expect(decision, isNull);
    recognizer.handleEvent(_move(1, const Offset(3, 20)));
    expect(decision?.action, PlayerSinglePointerGestureAction.fullScreen);

    recognizer.handleEvent(_up(1, const Offset(3, 20)));
    recognizer.dispose();
  });

  testWidgets('rejected single-pointer direction safely leaves the arena', (
    tester,
  ) async {
    final recognizer = _TestScaleGestureRecognizer()
      ..singlePointerMoveFilter = (_, __, ___) => null;
    final down = _down(1);

    recognizer.addPointer(down);
    recognizer.handleEvent(down);
    recognizer.handleEvent(_move(1, const Offset(0, 20)));

    recognizer.dispose();
  });

  testWidgets('a multi-pointer gesture is not re-filtered after acceptance', (
    tester,
  ) async {
    var filterCalls = 0;
    final recognizer = _TestScaleGestureRecognizer()
      ..singlePointerMoveFilter = (_, __, ___) {
        filterCalls++;
        return null;
      };
    final firstDown = _down(1);
    final secondDown = _down(2);

    recognizer.addPointer(firstDown);
    recognizer.handleEvent(firstDown);
    recognizer.addPointer(secondDown);
    recognizer.handleEvent(secondDown);
    recognizer.handleEvent(_move(1, const Offset(20, 0)));
    recognizer.handleEvent(_move(2, const Offset(30, 0)));
    recognizer.handleEvent(_up(2, const Offset(30, 0)));
    recognizer.handleEvent(_move(1, const Offset(0, 30)));
    recognizer.handleEvent(_up(1, const Offset(0, 30)));

    expect(filterCalls, 0);
    recognizer.dispose();
  });

  testWidgets('cancel and multi-pointer takeover mark the gesture aborted', (
    tester,
  ) async {
    final recognizer = _TestScaleGestureRecognizer();
    final firstDown = _down(1);
    recognizer.addPointer(firstDown);
    recognizer.handleEvent(firstDown);
    expect(recognizer.shouldCancelCurrentGesture, isFalse);

    recognizer.handleEvent(_cancel(1, Offset.zero));
    expect(recognizer.shouldCancelCurrentGesture, isTrue);
    recognizer.dispose();

    final multiRecognizer = _TestScaleGestureRecognizer();
    final secondDown = _down(2, const Offset(10, 10));
    multiRecognizer.addPointer(firstDown);
    multiRecognizer.handleEvent(firstDown);
    multiRecognizer.addPointer(secondDown);
    expect(multiRecognizer.shouldCancelCurrentGesture, isTrue);
    multiRecognizer.dispose();
  });
}
