import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/models/player_resource_lease.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'probe failure releases an unpublished player even without output',
    () async {
      final lease = PlayerResourceLease<String>();
      final events = <String>[];

      await expectLater(
        lease.run(
          () async {
            events.add('player-created');
            events.add('probe-started');
            throw StateError('probe failed');
          },
          disposePair: (output) async {
            events.add('dispose-output:${output ?? 'none'}');
            events.add('dispose-player');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(events, [
        'player-created',
        'probe-started',
        'dispose-output:none',
        'dispose-player',
      ]);
      expect(lease.released, isTrue);
    },
  );

  test(
    'output creation failure releases player without a partial output',
    () async {
      final lease = PlayerResourceLease<String>();
      final events = <String>[];

      await expectLater(
        lease.run(
          () async {
            events.add('probe-complete');
            events.add('output-create-started');
            throw StateError('output create failed');
          },
          disposePair: (output) async {
            events.add('dispose-output:${output ?? 'none'}');
            events.add('dispose-player');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(events, [
        'probe-complete',
        'output-create-started',
        'dispose-output:none',
        'dispose-player',
      ]);
    },
  );

  test(
    'stale completed output is disposed before player; publication transfers',
    () async {
      final lease = PlayerResourceLease<String>();
      final events = <String>[];
      lease.attachOutput('output-a');
      await lease.release((output) async {
        events.add('dispose-output:$output');
        events.add('dispose-player');
      });
      // A racing catch/stale path must not double dispose the same pair.
      await lease.release((output) async => events.add('duplicate:$output'));
      expect(events, ['dispose-output:output-a', 'dispose-player']);

      final published = PlayerResourceLease<String>()..attachOutput('output-b');
      published.transfer();
      await published.release(
        (output) async => events.add('wrongly-disposed:$output'),
      );
      expect(events, ['dispose-output:output-a', 'dispose-player']);
      expect(published.transferred, isTrue);
    },
  );

  test('failed disposal retains pair and permits retry', () async {
    final lease = PlayerResourceLease<String>()..attachOutput('output');
    var attempts = 0;
    await expectLater(
      lease.release((output) async {
        attempts++;
        expect(output, 'output');
        throw StateError('barrier failed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(lease.released, isFalse);
    await lease.release((output) async {
      attempts++;
      expect(output, 'output');
    });
    expect(attempts, 2);
    expect(lease.released, isTrue);
  });

  test('concurrent release callers share one disposal attempt', () async {
    final lease = PlayerResourceLease<String>()..attachOutput('output');
    final disposeStarted = Completer<void>();
    final allowDispose = Completer<void>();
    var attempts = 0;
    Future<void> dispose(String? output) async {
      attempts++;
      expect(output, 'output');
      disposeStarted.complete();
      await allowDispose.future;
    }

    final first = lease.release(dispose);
    await disposeStarted.future;
    final second = lease.release(dispose);
    allowDispose.complete();
    await Future.wait([first, second]);
    expect(attempts, 1);
    expect(lease.released, isTrue);
  });
}
