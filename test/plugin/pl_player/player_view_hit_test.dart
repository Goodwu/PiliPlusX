import 'package:PiliPlus/common/widgets/gesture/immediate_tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/gesture/mouse_interactive_viewer.dart';
import 'package:PiliPlus/common/widgets/gesture/player_gesture_recognizer.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('viewport interaction layer receives center and edge taps', (
    tester,
  ) async {
    final stateKey = GlobalKey<_PlayerHitTestHarnessState>();
    final harness = _PlayerHitTestHarness(key: stateKey);
    await tester.pumpWidget(harness);

    await tester.tapAt(const Offset(400, 300));
    await tester.tapAt(const Offset(799, 300));
    expect(stateKey.currentState!.backgroundTaps, 2);
  });

  testWidgets('hidden overlay does not block the viewport', (tester) async {
    final stateKey = GlobalKey<_PlayerHitTestHarnessState>();
    final harness = _PlayerHitTestHarness(key: stateKey, hiddenOverlay: true);
    await tester.pumpWidget(harness);

    await tester.tapAt(const Offset(150, 100));
    expect(stateKey.currentState!.backgroundTaps, 1);
    expect(stateKey.currentState!.overlayTaps, 0);
  });

  testWidgets('button and progress bar consume their own taps', (tester) async {
    final stateKey = GlobalKey<_PlayerHitTestHarnessState>();
    final harness = _PlayerHitTestHarness(key: stateKey);
    await tester.pumpWidget(harness);

    await tester.tap(find.byKey(const ValueKey('button')));
    await tester.tap(find.byKey(const ValueKey('progress')));
    expect(stateKey.currentState!.overlayTaps, 2);
    expect(stateKey.currentState!.backgroundTaps, 0);
  });

  testWidgets('player boundary leaves the recommendation list scrollable', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      _PlayerWithRecommendationList(scrollController: scrollController),
    );

    expect(scrollController.offset, 0);
    await tester.dragFrom(const Offset(150, 170), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
  });

  testWidgets(
    'nested player and recommendation list keep pointer ownership separate',
    (
      tester,
    ) async {
      final outerController = ScrollController();
      addTearDown(outerController.dispose);
      var outerFilterCalls = 0;
      final filterResults = <bool>[];
      final playerKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: ExtendedNestedScrollView(
            controller: outerController,
            pointerDownFilter: (event) {
              outerFilterCalls++;
              final box =
                  playerKey.currentContext!.findRenderObject()! as RenderBox;
              final allowed = !box.size.contains(
                box.globalToLocal(event.position),
              );
              filterResults.add(allowed);
              return allowed;
            },
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 220,
                  child: _NestedPlayerBoundary(
                    key: playerKey,
                    onPlayerMove: () {},
                  ),
                ),
              ),
            ],
            body: ListView.builder(
              itemCount: 20,
              itemBuilder: (context, index) => SizedBox(
                height: 80,
                child: Text('recommendation-$index'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final playerCenter = tester.getCenter(find.byType(_NestedPlayerBoundary));
      await tester.dragFrom(playerCenter, const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(outerFilterCalls, greaterThan(0));
      expect(filterResults.last, isFalse);
      expect(outerController.offset, 0);

      final filterCallsAfterPlayer = outerFilterCalls;
      await tester.dragFrom(const Offset(150, 500), const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(150, 500), const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(outerFilterCalls, greaterThan(filterCallsAfterPlayer));
      expect(filterResults.last, isTrue);
      expect(outerController.offset, greaterThan(0));
    },
  );
}

class _PlayerWithRecommendationList extends StatelessWidget {
  const _PlayerWithRecommendationList({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Column(
        children: [
          const SizedBox(
            height: 120,
            width: double.infinity,
            child: ColoredBox(color: Colors.black),
          ),
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              itemCount: 20,
              itemBuilder: (context, index) => SizedBox(
                height: 60,
                child: Text('推荐视频 $index'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NestedPlayerBoundary extends StatelessWidget {
  const _NestedPlayerBoundary({super.key, required this.onPlayerMove});

  final VoidCallback onPlayerMove;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        PlayerScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PlayerScaleGestureRecognizer>(
              PlayerScaleGestureRecognizer.new,
              (recognizer) {
                recognizer.singlePointerMoveFilter =
                    (startPosition, delta, kind) {
                      onPlayerMove();
                      return const PlayerSinglePointerGestureDecision(
                        startPosition: Offset.zero,
                        action: PlayerSinglePointerGestureAction.fullScreen,
                      );
                    };
              },
            ),
      },
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerMove: (_) => onPlayerMove(),
        child: const ColoredBox(color: Colors.black),
      ),
    );
  }
}

class _PlayerHitTestHarness extends StatefulWidget {
  const _PlayerHitTestHarness({super.key, this.hiddenOverlay = false});

  final bool hiddenOverlay;

  @override
  State<_PlayerHitTestHarness> createState() => _PlayerHitTestHarnessState();
}

class _PlayerHitTestHarnessState extends State<_PlayerHitTestHarness> {
  int backgroundTaps = 0;
  int overlayTaps = 0;

  late final TransformationController transformationController;
  late final GlobalKey viewportKey;
  late final ImmediateTapGestureRecognizer tapRecognizer;
  late final ScaleGestureRecognizer scaleRecognizer;

  @override
  void initState() {
    super.initState();
    transformationController = TransformationController();
    viewportKey = GlobalKey();
    tapRecognizer = ImmediateTapGestureRecognizer(
      onTapUp: (_) => backgroundTaps++,
    );
    scaleRecognizer = ScaleGestureRecognizer();
  }

  @override
  void dispose() {
    tapRecognizer.dispose();
    scaleRecognizer.dispose();
    transformationController.dispose();
    super.dispose();
  }

  void onPointerDown(PointerDownEvent event) {
    tapRecognizer.addPointer(event);
  }

  Widget overlay({required Key key}) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    onTap: () => overlayTaps++,
    child: const SizedBox(width: 80, height: 40),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 300,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            MouseInteractiveViewer(
              pointerSignalFallback: (_) {},
              onPointerDown: onPointerDown,
              onPanStart: (_) {},
              onPanUpdate: (_) {},
              onPanEnd: (_) {},
              onScaleUpdate: (_) {},
              transformationController: transformationController,
              childKey: viewportKey,
              scaleGestureRecognizer: scaleRecognizer,
              child: SizedBox(
                key: viewportKey,
                width: 300,
                height: 200,
              ),
            ),
            if (widget.hiddenOverlay)
              Offstage(
                offstage: true,
                child: overlay(key: const ValueKey('hidden-overlay')),
              )
            else ...[
              Align(
                alignment: Alignment.topLeft,
                child: overlay(key: const ValueKey('button')),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: overlay(key: const ValueKey('progress')),
              ),
            ],
            const Align(
              alignment: Alignment.center,
              child: SizedBox(
                key: ValueKey('center'),
                width: 1,
                height: 1,
              ),
            ),
            const Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                key: ValueKey('edge'),
                width: 1,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
