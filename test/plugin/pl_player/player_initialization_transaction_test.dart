import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/models/player_initialization_transaction.dart';
import 'package:PiliPlus/plugin/pl_player/models/player_resource_lease.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final transaction = PlayerInitializationTransaction<String, String, int>();

  test('late probe is discarded and disposes only its player', () async {
    final lease = PlayerResourceLease<String>();
    final probeStarted = Completer<void>();
    final releaseProbe = Completer<void>();
    final events = <String>[];
    var current = true;

    final pending = transaction.run(
      player: 'player-a',
      lease: lease,
      isCurrent: () => current,
      probe: () async {
        events.add('probe-a');
        probeStarted.complete();
        await releaseProbe.future;
        return 7;
      },
      createOutput: (_) async {
        events.add('output-a');
        return 'output-a';
      },
      disposePair: (output) async => events.add('dispose-a:$output'),
    );

    await probeStarted.future;
    current = false;
    releaseProbe.complete();
    expect(await pending, isNull);
    expect(events, ['probe-a', 'dispose-a:null']);
    expect(lease.released, isTrue);
  });

  test(
    'late output is disposed before its player after source replacement',
    () async {
      final lease = PlayerResourceLease<String>();
      final outputStarted = Completer<void>();
      final releaseOutput = Completer<void>();
      final events = <String>[];
      var current = true;

      final pending = transaction.run(
        player: 'player-a',
        lease: lease,
        isCurrent: () => current,
        probe: () async => 1,
        createOutput: (_) async {
          outputStarted.complete();
          await releaseOutput.future;
          return 'output-a';
        },
        disposePair: (output) async {
          events.add('dispose-output:$output');
          events.add('dispose-player-a');
        },
      );

      await outputStarted.future;
      current = false;
      releaseOutput.complete();
      expect(await pending, isNull);
      expect(events, ['dispose-output:output-a', 'dispose-player-a']);
      expect(lease.released, isTrue);
    },
  );

  test(
    'candidate rechecks current source at publication after await gap',
    () async {
      final lease = PlayerResourceLease<String>();
      final events = <String>[];
      var current = true;
      final candidate = await transaction.run(
        player: 'player-a',
        lease: lease,
        isCurrent: () => current,
        probe: () async {
          events.add('probe');
          return 42;
        },
        createOutput: (capabilities) async {
          events.add('output:$capabilities');
          return 'output-a';
        },
        disposePair: (output) async => events.add('dispose:$output'),
      );

      expect(candidate?.player, 'player-a');
      expect(candidate?.output, 'output-a');
      expect(candidate?.capabilities, 42);
      expect(lease.transferred, isFalse);
      current = false;
      expect(candidate!.lease, same(lease));
      final published = await lease.publishIfCurrent(
        isCurrent: () => current,
        publish: () => events.add('publish-stale'),
        rollback: () => events.add('rollback-stale'),
        disposePair: (output) async => events.add('dispose:$output'),
      );
      expect(published, isFalse);
      expect(lease.released, isTrue);
      expect(lease.transferred, isFalse);
      expect(events, ['probe', 'output:42', 'dispose:output-a']);
    },
  );

  test('partial publication rolls back before releasing the pair', () async {
    final lease = PlayerResourceLease<String>()..attachOutput('output');
    final events = <String>[];
    Object? owner;
    var listenerInstalled = false;
    final candidateOwner = Object();

    await expectLater(
      lease.publishIfCurrent(
        isCurrent: () => true,
        publish: () {
          owner = candidateOwner;
          listenerInstalled = true;
          events.add('pair-and-listener-published');
          throw StateError('listener binding failed');
        },
        rollback: () {
          if (identical(owner, candidateOwner)) owner = null;
          if (identical(owner, null) && listenerInstalled) {
            listenerInstalled = false;
          }
          events.add('rollback');
        },
        disposePair: (output) async {
          events.add(
            'dispose:$output:owner=$owner:listener=$listenerInstalled',
          );
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(events, [
      'pair-and-listener-published',
      'rollback',
      'dispose:output:owner=null:listener=false',
    ]);
  });

  test('rollback preserves a newer owner and its listener handles', () async {
    final lease = PlayerResourceLease<String>()..attachOutput('old-output');
    final events = <String>[];
    final oldOwner = Object();
    final newOwner = Object();
    Object? owner;
    Object? listenerOwner;

    await expectLater(
      lease.publishIfCurrent(
        isCurrent: () => true,
        publish: () {
          owner = oldOwner;
          listenerOwner = oldOwner;
          owner = newOwner;
          listenerOwner = newOwner;
          throw StateError('late publish failure');
        },
        rollback: () {
          if (identical(owner, oldOwner)) owner = null;
          if (identical(listenerOwner, oldOwner)) listenerOwner = null;
        },
        disposePair: (output) async => events.add('dispose:$output'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(owner, same(newOwner));
    expect(listenerOwner, same(newOwner));
    expect(events, ['dispose:old-output']);
  });

  test(
    'probe and output exceptions clean up the unpublished player/pair',
    () async {
      final probeLease = PlayerResourceLease<String>();
      final probeEvents = <String>[];
      await expectLater(
        transaction.run(
          player: 'player-probe',
          lease: probeLease,
          isCurrent: () => true,
          probe: () async => throw StateError('probe failed'),
          createOutput: (_) async => 'never',
          disposePair: (output) async => probeEvents.add('dispose:$output'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(probeEvents, ['dispose:null']);

      final outputLease = PlayerResourceLease<String>();
      final outputEvents = <String>[];
      await expectLater(
        transaction.run(
          player: 'player-output',
          lease: outputLease,
          isCurrent: () => true,
          probe: () async => 1,
          createOutput: (_) async => throw StateError('output failed'),
          disposePair: (output) async => outputEvents.add('dispose:$output'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(outputEvents, ['dispose:null']);
    },
  );
}
