import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr_output_rebuild_queue.dart';

void main() {
  test('one completed request does not schedule a second rebuild', () {
    final queue = HdrOutputRebuildQueue();
    final runs = <bool>[];

    final first = queue.request(true);
    expect(first, isTrue);
    runs.add(first!);
    final next = queue.complete(mayReplay: () => true);
    if (next != null) runs.add(next);

    expect(runs, [true]);
    expect(next, isNull);
    expect(queue.inFlight, isFalse);
  });

  test('a queued false request is replayed exactly once', () {
    final queue = HdrOutputRebuildQueue();

    final first = queue.request(true);
    expect(queue.request(false), isNull);
    final queued = queue.complete(mayReplay: () => true);
    expect(queued, isFalse);

    expect(queue.complete(mayReplay: () => true), isNull);
    expect([first, queued], [true, false]);
    expect(queue.inFlight, isFalse);
  });

  test('latest queued request wins, including a final false', () {
    final queue = HdrOutputRebuildQueue();

    expect(queue.request(true), isTrue);
    expect(queue.request(false), isNull);
    expect(queue.request(true), isNull);
    expect(queue.request(false), isNull);

    final next = queue.complete(mayReplay: () => true);
    expect(next, isFalse);
    expect(queue.inFlight, isTrue);
    expect(queue.complete(mayReplay: () => true), isNull);
    expect(queue.inFlight, isFalse);
  });

  test('dispose invalidation prevents queued replay', () {
    final queue = HdrOutputRebuildQueue();
    var disposed = false;
    expect(queue.request(true), isTrue);
    expect(queue.request(false), isNull);
    disposed = true;

    final next = queue.complete(mayReplay: () => !disposed);

    expect(next, isNull);
    expect(queue.inFlight, isFalse);
  });

  test('source or Player replacement invalidates queued replay', () {
    void verifyInvalidated(void Function(List<Object>) invalidate) {
      final queue = HdrOutputRebuildQueue();
      final state = <Object>[1, true];
      expect(queue.request(true), isTrue);
      expect(queue.request(false), isNull);
      invalidate(state);

      final next = queue.complete(
        mayReplay: () => state[0] == 1 && state[1] == true,
      );

      expect(next, isNull);
      expect(queue.inFlight, isFalse);
    }

    verifyInvalidated((state) => state[0] = 2);
    verifyInvalidated((state) => state[1] = false);
  });

  test('controller gates requests and replays against current ownership', () {
    final source = File('lib/plugin/pl_player/controller.dart')
        .readAsStringSync();
    final request = source.substring(
      source.indexOf('void _requestHdrOutputRebuild('),
      source.indexOf('\n  String _hdrOutputSignature('),
    );

    expect(
      request,
      contains(
        'if (_fsDisposed || _playerCount <= 0 || player == null) return;',
      ),
    );
    expect(request, contains('_hdrOutputRebuildQueue.complete('));
    expect(request, contains('sourceGeneration == _hdrSourceGeneration'));
    expect(request, contains('identical(player, _videoPlayerController)'));
    expect(request, contains('if (queuedNativeSurface != null)'));
    expect(
      request,
      isNot(contains('_queuedHdrOutputRebuildNativeSurface ?? false')),
    );
  });
}
