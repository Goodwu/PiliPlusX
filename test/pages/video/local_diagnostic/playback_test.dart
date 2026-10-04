import 'dart:io';

import 'package:PiliPlus/pages/video/local_diagnostic/playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostic page wires player initialization through the mount gate',
    () {
      // This source contract verifies the page uses the tested coordinator; the
      // coordinator behavior itself is exercised below as a runtime unit test.
      final pageSource = File(
        'lib/pages/video/local_diagnostic/local_video_diagnostic.dart',
      ).readAsStringSync();

      expect(
        pageSource,
        contains(
          'final result = await initializeAndStartLocalDiagnosticPlayback(',
        ),
      );
      expect(pageSource, contains('initialize: detail.playerInit,'));
      expect(
        pageSource,
        contains('waitForPlayerViewMount: _waitForPlayerViewMount,'),
      );
      expect(pageSource, isNot(contains('playerInit(autoplay: true)')));
    },
  );

  test(
    'initialization disables autoplay and invokes guarded play after mount',
    () async {
      var mounted = false;
      final events = <String>[];

      final result = await initializeAndStartLocalDiagnosticPlayback(
        initialize: ({required autoplay}) async {
          events.add('initialize:$autoplay');
        },
        markPlayerReady: () => events.add('player-ready'),
        waitForPlayerViewMount: () async {
          events.add('wait-for-mount');
          mounted = true;
          return true;
        },
        startPlayback: () => startLocalDiagnosticPlayback(
          isCurrent: () => true,
          isPlayerViewMounted: () => mounted,
          play: () async => events.add('play'),
          refreshTrackMetadata: () async => events.add('metadata'),
        ),
      );

      expect(result, LocalDiagnosticStartupResult.started);
      expect(events, [
        'initialize:false',
        'player-ready',
        'wait-for-mount',
        'play',
        'metadata',
      ]);
    },
  );

  test('failed mount gate never invokes diagnostic play', () async {
    var playCalls = 0;
    final result = await initializeAndStartLocalDiagnosticPlayback(
      initialize: ({required autoplay}) async {
        expect(autoplay, isFalse);
      },
      markPlayerReady: () {},
      waitForPlayerViewMount: () async => false,
      startPlayback: () async {
        playCalls++;
        return true;
      },
    );

    expect(result, LocalDiagnosticStartupResult.playerViewNotMounted);
    expect(playCalls, 0);
  });

  test(
    'plays after mount and refreshes metadata only after play completes',
    () async {
      var mounted = false;
      final events = <String>[];

      final beforeMount = await startLocalDiagnosticPlayback(
        isCurrent: () => true,
        isPlayerViewMounted: () => mounted,
        play: () async {
          events.add('play');
        },
        refreshTrackMetadata: () async {
          events.add('metadata');
        },
      );
      expect(beforeMount, isFalse);
      expect(events, isEmpty);
      mounted = true;
      expect(
        await startLocalDiagnosticPlayback(
          isCurrent: () => true,
          isPlayerViewMounted: () => mounted,
          play: () async {
            events.add('play');
          },
          refreshTrackMetadata: () async {
            events.add('metadata');
          },
        ),
        isTrue,
      );
      expect(events, ['play', 'metadata']);
    },
  );

  test(
    'source replacement during play prevents stale metadata refresh',
    () async {
      var current = true;
      final events = <String>[];
      final started = await startLocalDiagnosticPlayback(
        isCurrent: () => current,
        isPlayerViewMounted: () => true,
        play: () async {
          events.add('play');
          current = false;
        },
        refreshTrackMetadata: () async => events.add('metadata'),
      );

      expect(started, isFalse);
      expect(events, ['play']);
    },
  );

  test('closing or an unmounted view prevents native playback', () async {
    var current = true;
    var mounted = false;
    var playCalls = 0;
    final started = await startLocalDiagnosticPlayback(
      isCurrent: () => current,
      isPlayerViewMounted: () => mounted,
      play: () async {
        playCalls++;
      },
      refreshTrackMetadata: () async {},
    );
    expect(started, isFalse);
    expect(playCalls, 0);

    current = false;
    mounted = true;
    final closing = await startLocalDiagnosticPlayback(
      isCurrent: () => current,
      isPlayerViewMounted: () => mounted,
      play: () async {
        playCalls++;
      },
      refreshTrackMetadata: () async {},
    );
    expect(closing, isFalse);
    expect(playCalls, 0);
  });
}
