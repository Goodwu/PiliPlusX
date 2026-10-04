import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/frame_pacing_diagnostic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics require the exact opt-in environment value', () {
    expect(FramePacingDiagnosticSampler.isEnabled({}, isMacOS: true), isFalse);
    expect(
      FramePacingDiagnosticSampler.isEnabled({
        FramePacingDiagnosticSampler.environmentVariable: '0',
      }, isMacOS: true),
      isFalse,
    );
    expect(
      FramePacingDiagnosticSampler.isEnabled({
        FramePacingDiagnosticSampler.environmentVariable: 'true',
      }, isMacOS: true),
      isFalse,
    );
    expect(
      FramePacingDiagnosticSampler.isEnabled({
        FramePacingDiagnosticSampler.environmentVariable: '1',
      }, isMacOS: true),
      isTrue,
    );
    expect(
      FramePacingDiagnosticSampler.isEnabled({
        FramePacingDiagnosticSampler.environmentVariable: '1',
      }, isMacOS: false),
      isFalse,
    );
  });

  test(
    'property readback timestamps and binds every read to its owner',
    () async {
      var now = DateTime.utc(2026, 10, 3);
      var monotonic = 10;
      final calls = <String>[];
      final properties = await FramePacingPropertyReadback.read(
        getProperty: (property) async {
          calls.add(property);
          return property == 'video-sync' ? 'display-resample' : '1';
        },
        isCurrent: () => true,
        playerHandle: 54,
        sourceGeneration: 8,
        monotonicMilliseconds: () => monotonic++,
        nowUtc: () => now = now.add(const Duration(milliseconds: 2)),
      );

      expect(calls, FramePacingPropertyReadback.properties);
      expect(properties, isNotNull);
      expect(properties!.length, 13);
      final videoSync = properties['video-sync']! as Map<String, Object?>;
      expect(videoSync['value'], 'display-resample');
      expect(videoSync['playerHandle'], 54);
      expect(videoSync['sourceGeneration'], 8);
      expect(videoSync['queryStartedAtUtc'], isA<String>());
      expect(videoSync['queryEndedAtUtc'], isA<String>());
      expect(videoSync['queryEndedMonotonicMilliseconds'], greaterThan(10));
    },
  );

  test(
    'unknown properties and getter failures remain unavailable and continue',
    () async {
      final calls = <String>[];
      final properties = await FramePacingPropertyReadback.read(
        getProperty: (property) async {
          calls.add(property);
          if (property == 'video-sync') throw StateError('unavailable');
          if (property == 'video-timing-offset') return '';
          return '0';
        },
        isCurrent: () => true,
        playerHandle: 5,
        sourceGeneration: 3,
        monotonicMilliseconds: () => 0,
      );

      expect(calls, FramePacingPropertyReadback.properties);
      final unavailable = properties!['video-sync']! as Map<String, Object?>;
      expect(unavailable['status'], 'unavailable');
      expect(unavailable['errorType'], 'StateError');
      expect(unavailable['value'], isNull);
      expect(
        (properties['video-timing-offset']! as Map<String, Object?>)['reason'],
        'empty-or-unknown-property',
      );
      expect(
        (properties['avsync']! as Map<String, Object?>)['value'],
        '0',
      );
    },
  );

  test(
    'stale source discards the batch before another native getter',
    () async {
      var current = true;
      var calls = 0;
      final properties = await FramePacingPropertyReadback.read(
        getProperty: (property) async {
          calls++;
          current = false;
          return 'display-resample';
        },
        isCurrent: () => current,
        playerHandle: 9,
        sourceGeneration: 4,
        monotonicMilliseconds: () => 0,
      );

      expect(properties, isNull);
      expect(calls, 1);
    },
  );

  test(
    'one in-flight query is discarded on dispose without delaying stop',
    () async {
      final query = Completer<Map<String, Object?>?>();
      final stopped = Completer<void>();
      final lines = <String>[];
      var queries = 0;
      final sampler = FramePacingDiagnosticSampler(
        sample: () => const {'playing': true},
        readProperties: () {
          queries++;
          return query.future;
        },
        writeLine: lines.add,
        interval: const Duration(milliseconds: 5),
        maximumDuration: const Duration(milliseconds: 80),
        onStop: () {
          if (!stopped.isCompleted) stopped.complete();
        },
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 24));
      expect(queries, 1);
      expect(sampler.sampleCount, 1);
      sampler.dispose();
      await stopped.future;
      query.complete(const {'video-sync': 'display-resample'});
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(sampler.isRunning, isFalse);
      expect(lines, isEmpty);
      expect(queries, 1);
    },
  );

  test(
    'unexpected property reader failure preserves the state sample',
    () async {
      final lines = <Map<String, dynamic>>[];
      final sampler = FramePacingDiagnosticSampler(
        sample: () => const {'playing': true, 'positionMilliseconds': 321},
        readProperties: () async => throw StateError('diagnostic-only failure'),
        writeLine: (line) =>
            lines.add(jsonDecode(line) as Map<String, dynamic>),
        maximumDuration: const Duration(seconds: 1),
      )..start();
      await Future<void>.delayed(Duration.zero);
      sampler.dispose();

      expect(lines, hasLength(1));
      expect(lines.single['playing'], isTrue);
      expect(lines.single['positionMilliseconds'], 321);
      expect(
        (lines.single['mpvQueryBatch'] as Map<String, dynamic>)['status'],
        'unavailable',
      );
    },
  );

  test(
    'sampling window allows at most 180 one-second samples in 180 seconds',
    () {
      final startedAt = DateTime.utc(2026, 10, 3);
      final window = FramePacingDiagnosticWindow(startedAt: startedAt);

      expect(window.interval, const Duration(seconds: 1));
      expect(window.maximumDuration, const Duration(seconds: 180));
      expect(window.maximumSamples, 180);
      expect(window.takeSampleAt(startedAt), isTrue);
      expect(
        window.takeSampleAt(startedAt.add(const Duration(milliseconds: 999))),
        isFalse,
      );
      for (var second = 1; second < 180; second++) {
        expect(
          window.takeSampleAt(startedAt.add(Duration(seconds: second))),
          isTrue,
          reason: 'sample at second $second',
        );
      }
      expect(window.sampleCount, 180);
      expect(
        window.takeSampleAt(startedAt.add(const Duration(seconds: 180))),
        isFalse,
      );
    },
  );

  test(
    'real deadline stops the timer and does not exceed its sample bound',
    () async {
      final records = <Map<String, dynamic>>[];
      final stopped = Completer<void>();
      final stopwatch = Stopwatch()..start();
      final sampler = FramePacingDiagnosticSampler(
        sample: () => {'positionMilliseconds': 1234, 'playing': true},
        writeLine: (line) =>
            records.add(jsonDecode(line) as Map<String, dynamic>),
        now: () => DateTime.utc(2026, 10, 3).add(stopwatch.elapsed),
        interval: const Duration(milliseconds: 5),
        maximumDuration: const Duration(milliseconds: 25),
        maximumSamples: 100,
        onStop: () {
          if (!stopped.isCompleted) stopped.complete();
        },
      );

      // This starts the timer before awaiting its deadline callback.
      // ignore: cascade_invocations
      sampler.start();
      await stopped.future.timeout(const Duration(seconds: 1));
      final countAtStop = records.length;
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(sampler.isRunning, isFalse);
      expect(countAtStop, inInclusiveRange(1, 6));
      expect(records.length, countAtStop);
      expect(records.length, lessThanOrEqualTo(100));
      expect(records.first['sampleIndex'], 1);
      expect(records.last['elapsedMilliseconds'], lessThan(25));
    },
  );

  test('dispose cancels periodic and deadline timers', () async {
    var writes = 0;
    var closeCount = 0;
    final sampler = FramePacingDiagnosticSampler(
      sample: () => const {'playing': false},
      writeLine: (_) => writes++,
      interval: const Duration(milliseconds: 5),
      maximumDuration: const Duration(milliseconds: 30),
      maximumSamples: 100,
      onStop: () => closeCount++,
    );

    // This starts the timer before the delayed explicit disposal.
    // ignore: cascade_invocations
    sampler.start();
    await Future<void>.delayed(const Duration(milliseconds: 12));
    sampler.dispose();
    final writesAtDispose = writes;
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(sampler.isRunning, isFalse);
    expect(writesAtDispose, greaterThanOrEqualTo(2));
    expect(writes, writesAtDispose);
    expect(closeCount, 1);
  });

  test(
    'controller starts opt-in diagnostics and stops them on source/dispose',
    () {
      final source = File('lib/plugin/pl_player/controller.dart')
          .readAsStringSync();
      expect(
        source,
        contains('isMacOS: Platform.isMacOS'),
      );
      expect(
        source,
        contains('Platform.environment,\n      isMacOS: Platform.isMacOS'),
      );
      expect(source, contains('waitForInitialization: false'));
      expect(source, contains('FramePacingPropertyReadback.read('));
      expect(source, contains('identical(player, _videoPlayerController)'));
      expect(source, contains('diagnostics.isRunning'));
      expect(
        source,
        contains(
          '_startFramePacingDiagnostics(currentPlayer, sourceGeneration);',
        ),
      );
      expect(source, contains('playerHandle = await player.handle;'));
      expect(
        source,
        contains('positionMilliseconds\': state.position.inMilliseconds'),
      );
      expect(source, contains('buffering\': state.buffering'));
      expect(
        source,
        contains('bufferMilliseconds\': state.buffer.inMilliseconds'),
      );
      expect(
        source,
        contains(
          'hdrOutputTransactionGeneration\': _videoOutputTransactionGeneration',
        ),
      );
      expect(source, contains('_stopFramePacingDiagnostics();'));
      expect(source, contains('sourceGeneration != _hdrSourceGeneration'));
      expect(source, isNot(contains("player.getProperty('position'")));
    },
  );
}
