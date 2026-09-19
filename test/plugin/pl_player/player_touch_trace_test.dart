import 'package:PiliPlus/plugin/pl_player/utils/player_touch_trace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    while (PlayerTouchTrace.globalPointerRouteUsers > 0) {
      PlayerTouchTrace.unregisterGlobalPointerRoute();
    }
  });

  test('formats the startup diagnostic marker', () {
    expect(
      PlayerTouchTrace.formatStartup(
        build: 'debug',
        os: 'ohos',
        traceEnabled: true,
      ),
      '[PlayerTouchTrace] startup build=debug os=ohos traceEnabled=true '
      'configurationProbe=false',
    );
  });

  test('preserves the fullscreen trace parser prefix', () {
    expect(
      PlayerTouchTrace.formatFullscreen('trigger status=true'),
      '[FullscreenTrace] trigger status=true',
    );
  });

  test('global pointer route has one registration for multiple users', () {
    PlayerTouchTrace.registerGlobalPointerRoute();
    PlayerTouchTrace.registerGlobalPointerRoute();
    expect(PlayerTouchTrace.globalPointerRouteUsers, 2);

    PlayerTouchTrace.unregisterGlobalPointerRoute();
    expect(PlayerTouchTrace.globalPointerRouteUsers, 1);
    PlayerTouchTrace.unregisterGlobalPointerRoute();
    expect(PlayerTouchTrace.globalPointerRouteUsers, 0);
  });

  testWidgets('tracks the active pointer sequence for lifecycle probes', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.expand());
    PlayerTouchTrace.registerGlobalPointerRoute();
    expect(PlayerTouchTrace.hasActivePointer, isFalse);

    final gesture = await tester.startGesture(const Offset(10, 10));
    await tester.pump();
    expect(PlayerTouchTrace.hasActivePointer, isTrue);

    await gesture.up();
    await tester.pump();
    expect(PlayerTouchTrace.hasActivePointer, isFalse);
  });

  test('formats a stable touch trace contract', () {
    final line = PlayerTouchTrace.format(
      stage: 'test',
      pointer: 7,
      viewId: 3,
      device: 42,
      position: const Offset(2.34, 6.78),
      globalPosition: const Offset(12.34, 56.78),
      kind: PointerDeviceKind.touch,
    );

    expect(line, startsWith('[PlayerTouchTrace] '));
    expect(line, contains('stage=test'));
    expect(line, contains('pointer=7'));
    expect(line, contains('viewId=3'));
    expect(line, contains('device=42'));
    expect(line, contains('position=(2.3,6.8)'));
    expect(line, contains('global=(12.3,56.8)'));
    expect(line, contains('kind=touch'));
  });

  test(
    'formats zero and negative bounds without losing precision contract',
    () {
      expect(
        PlayerTouchTrace.formatBounds(
          stage: 'viewport',
          size: const Size(0, 24.56),
          globalBounds: const Rect.fromLTRB(-3.21, 4.32, -3.21, 28.88),
        ),
        '[PlayerTouchTrace] bounds stage=viewport size=(0.0,24.6) '
        'globalBounds=(-3.2,4.3,-3.2,28.9)',
      );
    },
  );

  testWidgets('bounds helper skips an unavailable render box', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(key: key, width: 10, height: 20),
      ),
    );
    final renderBox = key.currentContext!.findRenderObject()! as RenderBox;
    expect(renderBox.hasSize, isTrue);
    expect(renderBox.attached, isTrue);
    expect(
      PlayerTouchTrace.renderBoxBounds(stage: 'box', renderBox: renderBox),
      '[PlayerTouchTrace] bounds stage=box size=(10.0,20.0) '
      'globalBounds=(0.0,0.0,10.0,20.0)',
    );

    expect(
      PlayerTouchTrace.renderBoxBounds(stage: 'missing', renderBox: null),
      isNull,
    );
  });
}
