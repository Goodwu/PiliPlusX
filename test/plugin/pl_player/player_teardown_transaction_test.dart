import 'package:PiliPlus/plugin/pl_player/models/player_teardown_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('final teardown awaits output barrier before Player disposal', () async {
    final events = <String>[];
    final result = await PlayerTeardownTransaction<String, String>().run(
      player: 'player',
      output: 'output',
      disposeOutput: (output) async => events.add('dispose-$output'),
      disposePlayer: (player) async => events.add('dispose-$player'),
      retainForRetry: ({required output, required outputReleased}) =>
          events.add('retain:$output:$outputReleased'),
      onError: (_, __) {},
      retryDelay: Duration.zero,
    );
    expect(result, PlayerTeardownResult.disposed);
    expect(events, ['dispose-output', 'dispose-player']);
  });

  test('failed output barrier retains Player and never disposes it', () async {
    final events = <String>[];
    final result = await PlayerTeardownTransaction<String, String>().run(
      player: 'player',
      output: 'output',
      outputAttempts: 2,
      disposeOutput: (output) async {
        events.add('try-$output');
        throw StateError('output barrier failed');
      },
      disposePlayer: (player) async => events.add('dispose-$player'),
      retainForRetry: ({required output, required outputReleased}) =>
          events.add('retain:$output:$outputReleased'),
      onError: (_, __) {},
      retryDelay: Duration.zero,
    );
    expect(result, PlayerTeardownResult.retainedForOutputRetry);
    expect(events, ['try-output', 'try-output', 'retain:output:false']);
  });

  test('Player failure retains pair as output-released for retry', () async {
    final events = <String>[];
    final result = await PlayerTeardownTransaction<String, String>().run(
      player: 'player',
      output: 'output',
      disposeOutput: (output) async => events.add('barrier-$output'),
      disposePlayer: (player) async => throw StateError('dispose failed'),
      retainForRetry: ({required output, required outputReleased}) =>
          events.add('retain:$output:$outputReleased'),
      onError: (_, __) {},
      retryDelay: Duration.zero,
    );
    expect(result, PlayerTeardownResult.retainedForPlayerRetry);
    expect(events, ['barrier-output', 'retain:output:true']);

    final retry = await PlayerTeardownTransaction<String, String>().run(
      player: 'player',
      output: 'output',
      outputAlreadyReleased: true,
      disposeOutput: (output) async => events.add('barrier-again'),
      disposePlayer: (player) async => events.add('dispose-$player'),
      retainForRetry: ({required output, required outputReleased}) =>
          events.add('retain-again:$output:$outputReleased'),
      onError: (_, __) {},
      retryDelay: Duration.zero,
    );
    expect(retry, PlayerTeardownResult.disposed);
    expect(events, ['barrier-output', 'retain:output:true', 'dispose-player']);
  });

  test('invalid zero output attempts fail before destroying Player', () async {
    final events = <String>[];
    await expectLater(
      PlayerTeardownTransaction<String, String>().run(
        player: 'player',
        output: 'output',
        outputAttempts: 0,
        disposeOutput: (output) async => events.add('barrier-$output'),
        disposePlayer: (player) async => events.add('dispose-$player'),
        retainForRetry: ({required output, required outputReleased}) =>
            events.add('retain:$output:$outputReleased'),
        onError: (_, __) {},
      ),
      throwsArgumentError,
    );
    expect(events, isEmpty);
  });
}
