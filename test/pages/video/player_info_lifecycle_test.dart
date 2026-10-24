import 'dart:async';

import 'package:piliplus/pages/video/widgets/header_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  testWidgets('player info opens after a mounted property query completes', (
    tester,
  ) async {
    final player = _DelayedPropertyPlayer();
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final opening = HeaderControlState.showPlayerInfo(
      pageContext,
      player: player,
    );
    expect(player.queriedProperty, 'hwdec-current');
    expect(find.byType(AlertDialog), findsNothing);

    player.property.complete('mediacodec');
    await opening;
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('播放信息'), findsOneWidget);
    expect(find.text('mediacodec'), findsOneWidget);
    expect(player.stateReads, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounting during the property query prevents a stale dialog', (
    tester,
  ) async {
    final player = _DelayedPropertyPlayer();
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final opening = HeaderControlState.showPlayerInfo(
      pageContext,
      player: player,
    );
    expect(player.queriedProperty, 'hwdec-current');
    expect(player.property.isCompleted, isFalse);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(pageContext.mounted, isFalse);

    player.property.complete('mediacodec');
    await opening;
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(player.stateReads, 0);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedPropertyPlayer implements NativePlayer {
  final property = Completer<String>();
  String? queriedProperty;
  int stateReads = 0;

  @override
  PlayerState get state {
    stateReads++;
    return const PlayerState();
  }

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) {
    queriedProperty = property;
    return this.property.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
