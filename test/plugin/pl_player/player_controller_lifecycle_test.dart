import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:PiliPlus/plugin/pl_player/models/player_lifecycle_ports.dart';
import 'package:PiliPlus/utils/path_utils.dart' as app_paths;
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide HdrCapabilities;
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late _LifecycleHarness harness;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'piliplusx-player-lifecycle-',
    );
    app_paths.appSupportDirPath = supportDirectory.path;
    app_paths.tmpDirPath = supportDirectory.path;
    await GStorage.init();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          if (call.method == 'isFullScreen') return false;
          if (call.method == 'getBounds') {
            return <String, Object?>{
              'x': 0.0,
              'y': 0.0,
              'width': 1280.0,
              'height': 720.0,
            };
          }
          return null;
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        (call) async => null,
      )
      ..setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
          WakelockPlusApi.pigeonChannelCodec,
        ),
        (message) async => <Object?>[null],
      );
  });

  setUp(() {
    harness = _LifecycleHarness();
  });

  tearDown(() async {
    final controller = harness.controller;
    if (controller != null) {
      controller.dispose();
      await controller.teardownDrain;
    }
    await harness.closePlayers();
  });

  tearDownAll(() async {
    await GStorage.close();
    await Hive.close();
    await supportDirectory.delete(recursive: true);
  });

  test(
    'public setDataSource creates, probes, opens, and tears down its pair',
    () async {
      final controller = harness.createController();
      final initialized = Completer<void>();

      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/first.m3u8',
          audioSource: null,
        ),
        autoplay: false,
        onInit: initialized.complete,
      );

      expect(initialized.isCompleted, isTrue);
      expect(harness.createdPlayers, hasLength(1));
      expect(harness.probeCalls, 1);
      expect(harness.outputs, hasLength(1));
      expect(harness.players.single.opened, hasLength(1));
      expect(harness.outputs.single.player, same(harness.players.single));
      harness.players.single.playing.add(true);
      expect(controller.playerStatus.value.isPlaying, isTrue);

      controller.dispose();
      harness.controller = null;
      await controller.teardownDrain;

      expect(harness.disposeEvents, [
        'output:${identityHashCode(harness.outputs.single)}',
        'player:${identityHashCode(harness.players.single)}',
      ]);
      expect(controller.hasBlockedTeardowns, isFalse);
    },
  );

  for (final boundary in ['probe', 'output creation', 'texture fallback']) {
    test(
      'disposing during $boundary await releases unpublished resources',
      () async {
        final controller = harness.createController();
        final started = Completer<void>();
        final resume = Completer<void>();
        if (boundary == 'probe') {
          harness.onProbe = (_) async {
            started.complete();
            await resume.future;
            return const HdrCapabilities(unsupportedReason: 'test-probe');
          };
        } else if (boundary == 'output creation') {
          harness.onBeforeOutputCreation = (attempt) async {
            if (attempt == 1) {
              started.complete();
              await resume.future;
            }
          };
        } else {
          harness
            ..failOutputAttempts.add(1)
            ..onBeforeOutputCreation = (attempt) async {
              if (attempt == 2) {
                started.complete();
                await resume.future;
              }
            }
            ..onProbe = (_) async => const HdrCapabilities(
              platform: 'macos',
              displayHdr: true,
              nativeOutputCapable: true,
            );
        }

        final source = controller.setDataSource(
          NetworkSource(
            videoSource: 'https://example.invalid/disposed-$boundary.m3u8',
            audioSource: null,
          ),
          autoplay: false,
          initialVideoQuality: boundary == 'texture fallback' ? 125 : null,
        );
        await started.future;

        controller.dispose();
        harness.controller = null;
        resume.complete();
        await source;
        await controller.teardownDrain;

        expect(controller.videoPlayerController, isNull);
        expect(controller.videoController, isNull);
        expect(harness.players.single.disposed, isTrue);
        if (boundary == 'probe') {
          expect(harness.outputs, isEmpty);
          expect(harness.disposeEvents, [
            'player:${identityHashCode(harness.players.single)}',
          ]);
        } else {
          expect(harness.outputs, hasLength(1));
          expect(harness.disposeEvents, [
            'output:${identityHashCode(harness.outputs.single)}',
            'player:${identityHashCode(harness.players.single)}',
          ]);
        }
      },
    );
  }

  test(
    'a replacement source waits for an old open on the reused Player',
    () async {
      final controller = harness.createController();
      final oldOpenStarted = Completer<void>();
      final finishOldOpen = Completer<void>();
      var oldInitCalled = false;
      var replacementInitCalled = false;
      harness.onPlayerCreated = (player) {
        player.openHandler = (playable, _) async {
          if (player.opened.length == 1) {
            oldOpenStarted.complete();
            await finishOldOpen.future;
          }
        };
      };

      final oldSource = controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/old.m3u8',
          audioSource: null,
        ),
        autoplay: false,
        onInit: () => oldInitCalled = true,
      );
      await oldOpenStarted.future;

      final newSource = controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/new.m3u8',
          audioSource: null,
        ),
        autoplay: false,
        onInit: () => replacementInitCalled = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(harness.players, hasLength(1));
      expect(harness.probeCalls, 1);
      expect(harness.players.single.opened, hasLength(1));

      finishOldOpen.complete();
      await Future.wait([oldSource, newSource]);

      expect(harness.players, hasLength(1));
      expect(harness.players.single.opened, hasLength(2));
      expect(harness.players.single.current.single.uri, contains('/new.m3u8'));
      expect(oldInitCalled, isFalse);
      expect(replacementInitCalled, isTrue);
    },
  );

  test(
    'disposing a non-final page reference keeps the shared Player alive',
    () async {
      final controller = harness.createController();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/shared.m3u8',
          audioSource: null,
        ),
        autoplay: false,
      );
      final secondReference = PlPlayerController.getInstance(
        lifecyclePorts: harness.ports,
      );
      expect(secondReference, same(controller));
      expect(harness.players.single.buffer.hasListener, isTrue);

      controller.dispose();
      expect(harness.disposeEvents, isEmpty);
      expect(harness.players.single.disposed, isFalse);
      expect(controller.videoPlayerController, same(harness.players.single));
      harness.players.single.buffer.add(const Duration(seconds: 17));
      expect(controller.buffered.value, 17);
      expect(harness.players.single.buffer.hasListener, isTrue);

      secondReference.dispose();
      harness.controller = null;
      await secondReference.teardownDrain;
      await Future<void>.delayed(Duration.zero);
      expect(harness.players.single.buffer.hasListener, isFalse);
      expect(harness.disposeEvents, [
        'output:${identityHashCode(harness.outputs.single)}',
        'player:${identityHashCode(harness.players.single)}',
      ]);
    },
  );

  test('a stale delayed probe cannot replace a newer published pair', () async {
    final controller = harness.createController();
    final firstProbeStarted = Completer<void>();
    final finishFirstProbe = Completer<void>();
    harness.onProbe = (call) async {
      if (call == 1) {
        firstProbeStarted.complete();
        await finishFirstProbe.future;
      }
      return const HdrCapabilities(unsupportedReason: 'test-probe');
    };

    var staleInitCalled = false;
    final staleSource = controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/stale.m3u8',
        audioSource: null,
      ),
      autoplay: false,
      onInit: () => staleInitCalled = true,
    );
    await firstProbeStarted.future;

    final currentSource = controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/current.m3u8',
        audioSource: null,
      ),
      autoplay: false,
    );
    await currentSource;

    expect(harness.players, hasLength(2));
    expect(harness.outputs, hasLength(1));
    expect(controller.videoPlayerController, same(harness.players[1]));
    expect(controller.videoController, same(harness.outputs.single));
    expect(harness.players[1].current.single.uri, contains('/current.m3u8'));

    finishFirstProbe.complete();
    await staleSource;

    expect(staleInitCalled, isFalse);
    expect(controller.videoPlayerController, same(harness.players[1]));
    expect(controller.videoController, same(harness.outputs.single));
    expect(harness.disposeEvents, [
      'player:${identityHashCode(harness.players[0])}',
    ]);
  });

  test(
    'listener installation throw rolls back the newly published pair',
    () async {
      final controller = harness.createController();
      harness.throwOnDurationListen = true;

      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/listener-throw.m3u8',
          audioSource: null,
        ),
        autoplay: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.videoPlayerController, isNull);
      expect(controller.videoController, isNull);
      expect(harness.players.single.disposed, isTrue);
      expect(harness.players.single.playing.hasListener, isFalse);
      expect(harness.disposeEvents, [
        'output:${identityHashCode(harness.outputs.single)}',
        'player:${identityHashCode(harness.players.single)}',
      ]);
    },
  );

  test(
    'a late output from an old source is released without replacing current',
    () async {
      final controller = harness.createController();
      final firstOutputStarted = Completer<void>();
      final finishFirstOutput = Completer<void>();
      harness.onBeforeOutputCreation = (attempt) async {
        if (attempt == 1) {
          firstOutputStarted.complete();
          await finishFirstOutput.future;
        }
      };

      final staleSource = controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/late-old.m3u8',
          audioSource: null,
        ),
        autoplay: false,
      );
      await firstOutputStarted.future;

      final currentSource = controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/late-current.m3u8',
          audioSource: null,
        ),
        autoplay: false,
      );
      await currentSource;
      final currentPlayer = harness.players[1];
      final currentOutput = harness.outputs.single;
      expect(currentOutput.player, same(currentPlayer));
      expect(controller.videoPlayerController, same(currentPlayer));

      finishFirstOutput.complete();
      await staleSource;

      final lateOldOutput = harness.outputs[1];
      expect(lateOldOutput.player, same(harness.players[0]));
      expect(controller.videoPlayerController, same(currentPlayer));
      expect(controller.videoController, same(currentOutput));
      expect(harness.disposeEvents, [
        'output:${identityHashCode(lateOldOutput)}',
        'player:${identityHashCode(harness.players[0])}',
      ]);

      controller.dispose();
      harness.controller = null;
      await controller.teardownDrain;
      expect(harness.disposeEvents, [
        'output:${identityHashCode(lateOldOutput)}',
        'player:${identityHashCode(harness.players[0])}',
        'output:${identityHashCode(currentOutput)}',
        'player:${identityHashCode(currentPlayer)}',
      ]);
    },
  );

  test(
    'videoParams drives the controller output rebuild and pair handoff',
    () async {
      final controller = harness.createController();
      harness.onProbe = (_) async => const HdrCapabilities(
        platform: 'macos',
        displayHdr: true,
        nativeOutputCapable: true,
      );

      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/hdr.m3u8',
          audioSource: null,
        ),
        autoplay: false,
        initialVideoQuality: 125,
      );
      final oldOutput = harness.outputs.single;
      expect(oldOutput.configuration.vo, 'libmpv');

      harness.players.single.videoParams.add(
        const VideoParams(
          primaries: 'bt.709',
          gamma: 'bt.1886',
          colormatrix: 'bt.709',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final rebuild = controller.outputRebuildDrain;
      if (rebuild != null) await rebuild;

      expect(harness.outputs, hasLength(2));
      expect(harness.outputs.last.player, same(harness.players.single));
      expect(harness.outputs.last.configuration.vo, isNull);
      expect(controller.videoPlayerController, same(harness.players.single));
      expect(controller.videoController, same(harness.outputs.last));
      expect(
        harness.disposeEvents,
        ['output:${identityHashCode(oldOutput)}'],
      );

      controller.dispose();
      harness.controller = null;
      await controller.teardownDrain;
      expect(harness.disposeEvents, [
        'output:${identityHashCode(oldOutput)}',
        'output:${identityHashCode(harness.outputs.last)}',
        'player:${identityHashCode(harness.players.single)}',
      ]);
    },
  );

  test('dispose during output rebuild prevents late publication', () async {
    final controller = harness.createController();
    harness.onProbe = (_) async => const HdrCapabilities(
      platform: 'macos',
      displayHdr: true,
      nativeOutputCapable: true,
    );
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/dispose-rebuild.m3u8',
        audioSource: null,
      ),
      autoplay: false,
      initialVideoQuality: 125,
    );
    final player = harness.players.single;
    final firstOutput = harness.outputs.single;
    final rebuildOutputStarted = Completer<void>();
    final finishRebuildOutput = Completer<void>();
    harness.onBeforeOutputCreation = (attempt) async {
      if (attempt == 2) {
        rebuildOutputStarted.complete();
        await finishRebuildOutput.future;
      }
    };

    player.videoParams.add(
      const VideoParams(
        primaries: 'bt.709',
        gamma: 'bt.1886',
        colormatrix: 'bt.709',
      ),
    );
    await rebuildOutputStarted.future;
    final rebuildSnapshot = controller.outputRebuildDrain!;
    controller.dispose();
    harness.controller = null;
    await controller.teardownDrain;
    expect(player.disposed, isTrue);

    finishRebuildOutput.complete();
    await rebuildSnapshot;

    expect(controller.videoPlayerController, isNull);
    expect(controller.videoController, isNull);
    expect(harness.outputs, hasLength(2));
    expect(
      harness.disposeEvents,
      contains('output:${identityHashCode(harness.outputs.last)}'),
    );
    expect(
      harness.disposeEvents,
      contains('output:${identityHashCode(firstOutput)}'),
    );
    expect(player.disposed, isTrue);
  });

  test('queued public retries coalesce to latest output topology', () async {
    final controller = harness.createController();
    harness.onProbe = (_) async => const HdrCapabilities(
      platform: 'macos',
      displayHdr: true,
      nativeOutputCapable: true,
    );
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/queued-rebuild.m3u8',
        audioSource: null,
      ),
      autoplay: false,
      initialVideoQuality: 125,
    );

    final player = harness.players.single;
    final firstRebuildStarted = Completer<void>();
    final finishFirstRebuild = Completer<void>();
    final replayStarted = Completer<void>();
    harness
      ..onBeforeOutputCreation = (attempt) async {
        if (attempt == 2) {
          firstRebuildStarted.complete();
          await finishFirstRebuild.future;
        }
      }
      ..onOutputAttempt = (attempt) {
        if (attempt == 3) replayStarted.complete();
      };

    player.videoParams.add(
      const VideoParams(
        primaries: 'bt.709',
        gamma: 'bt.1886',
        colormatrix: 'bt.709',
      ),
    );
    await firstRebuildStarted.future;
    final firstDrainSnapshot = controller.outputRebuildDrain!;

    // Queue a native candidate, then replace it with the latest texture
    // request while the first rebuild is still creating its output.
    player.videoParams.add(
      const VideoParams(
        primaries: 'bt.2020',
        gamma: 'pq',
        colormatrix: 'bt.2020',
      ),
    );
    expect(controller.hdrDecision.useNativeSurface, isTrue);
    controller.retryVideoOutput();
    player.videoParams.add(
      const VideoParams(
        primaries: 'bt.709',
        gamma: 'bt.1886',
        colormatrix: 'bt.709',
      ),
    );
    expect(controller.hdrDecision.useNativeSurface, isFalse);
    controller.retryVideoOutput();
    expect(harness.outputAttempts, 2);

    finishFirstRebuild.complete();
    await firstDrainSnapshot;
    final replayDrainSnapshot = controller.outputRebuildDrain;
    expect(replayDrainSnapshot, isNotNull);
    expect(replayDrainSnapshot, isNot(same(firstDrainSnapshot)));
    await replayStarted.future;
    await replayDrainSnapshot;

    expect(harness.outputAttempts, 3);
    expect(harness.outputs, hasLength(3));
    expect(harness.outputs[1].configuration.vo, isNull);
    expect(harness.outputs[2].configuration.vo, isNull);
    expect(controller.videoPlayerController, same(player));
    expect(controller.videoController, same(harness.outputs.last));

    controller.dispose();
    harness.controller = null;
    await controller.teardownDrain;
    expect(harness.disposeEvents, [
      'output:${identityHashCode(harness.outputs[0])}',
      'output:${identityHashCode(harness.outputs[1])}',
      'output:${identityHashCode(harness.outputs[2])}',
      'player:${identityHashCode(player)}',
    ]);
  });

  test(
    'failed rebuild retains Player and public retry republishes output',
    () async {
      final controller = harness.createController();
      harness.onProbe = (_) async => const HdrCapabilities(
        platform: 'macos',
        displayHdr: true,
        nativeOutputCapable: true,
      );
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/hdr-retry.m3u8',
          audioSource: null,
        ),
        autoplay: false,
        initialVideoQuality: 125,
      );
      final player = harness.players.single;
      final oldOutput = harness.outputs.single;
      final fallbackAttempted = Completer<void>();
      harness.failOutputAttempts.addAll([2, 3]);
      harness.onOutputAttempt = (attempt) {
        if (attempt == 3) fallbackAttempted.complete();
      };

      player.videoParams.add(
        const VideoParams(
          primaries: 'bt.709',
          gamma: 'bt.1886',
          colormatrix: 'bt.709',
        ),
      );
      await fallbackAttempted.future;
      final failedRebuild = controller.outputRebuildDrain;
      if (failedRebuild != null) await failedRebuild;

      expect(harness.disposeEvents, ['output:${identityHashCode(oldOutput)}']);
      expect(controller.videoPlayerController, same(player));
      expect(controller.videoController, isNull);
      expect(player.disposed, isFalse);
      expect(controller.hdrOutputError.value, 'video-output-rebuild-failed');

      harness.failOutputAttempts.clear();
      controller.retryVideoOutput();
      await Future<void>.delayed(Duration.zero);
      final retriedRebuild = controller.outputRebuildDrain;
      if (retriedRebuild != null) await retriedRebuild;

      expect(harness.outputs, hasLength(2));
      expect(harness.outputs.last.player, same(player));
      expect(controller.videoPlayerController, same(player));
      expect(controller.videoController, same(harness.outputs.last));
      expect(controller.hdrOutputError.value, isNull);

      controller.dispose();
      harness.controller = null;
      await controller.teardownDrain;
      expect(harness.disposeEvents, [
        'output:${identityHashCode(oldOutput)}',
        'output:${identityHashCode(harness.outputs.last)}',
        'player:${identityHashCode(player)}',
      ]);
    },
  );

  test('initial native output failure publishes texture fallback', () async {
    final controller = harness.createController();
    harness.onProbe = (_) async => const HdrCapabilities(
      platform: 'macos',
      displayHdr: true,
      nativeOutputCapable: true,
    );
    harness.failOutputAttempts.add(1);

    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/hdr-fallback.m3u8',
        audioSource: null,
      ),
      autoplay: false,
      initialVideoQuality: 125,
    );

    expect(harness.outputAttempts, 2);
    expect(harness.outputs, hasLength(1));
    expect(harness.outputs.single.configuration.vo, isNull);
    expect(harness.outputs.single.player, same(harness.players.single));
    expect(controller.videoPlayerController, same(harness.players.single));
    expect(controller.videoController, same(harness.outputs.single));
    expect(harness.players.single.opened, hasLength(1));

    controller.dispose();
    harness.controller = null;
    await controller.teardownDrain;
    expect(harness.disposeEvents, [
      'output:${identityHashCode(harness.outputs.single)}',
      'player:${identityHashCode(harness.players.single)}',
    ]);
  });

  test(
    'final dispose retains blocked Player until output retry succeeds',
    () async {
      final controller = harness.createController();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/teardown-retry.m3u8',
          audioSource: null,
        ),
        autoplay: false,
      );
      final player = harness.players.single;
      final output = harness.outputs.single;
      final thirdDisposeAttempt = Completer<void>();
      harness.failDisposeOutputAttempts.addAll([1, 2, 3]);
      harness.onDisposeOutputAttempt = (attempt) {
        if (attempt == 3) thirdDisposeAttempt.complete();
      };

      controller.dispose();
      harness.controller = null;
      await thirdDisposeAttempt.future;
      for (
        var attempt = 0;
        attempt < 10 && !controller.hasBlockedTeardowns;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.hasBlockedTeardowns, isTrue);
      expect(player.disposed, isFalse);
      expect(harness.disposeEvents, hasLength(3));
      expect(
        harness.disposeEvents,
        everyElement('output:${identityHashCode(output)}'),
      );

      await controller.teardownDrain;

      expect(harness.disposeEvents, [
        'output:${identityHashCode(output)}',
        'output:${identityHashCode(output)}',
        'output:${identityHashCode(output)}',
        'output:${identityHashCode(output)}',
        'player:${identityHashCode(player)}',
      ]);
      expect(player.disposed, isTrue);
      expect(controller.hasBlockedTeardowns, isFalse);
    },
  );
}

class _LifecycleHarness {
  final players = <_FakePlayer>[];
  final createdPlayers = <PlayerConfiguration>[];
  final outputs = <_FakeVideoController>[];
  final outputConfigurations = <VideoControllerConfiguration>[];
  final disposeEvents = <String>[];
  final failOutputAttempts = <int>{};
  final failDisposeOutputAttempts = <int>{};
  int outputAttempts = 0;
  int disposeOutputAttempts = 0;
  int probeCalls = 0;
  PlPlayerController? controller;
  PlayerLifecyclePorts? ports;
  void Function(_FakePlayer player)? onPlayerCreated;
  Future<HdrCapabilities> Function(int call)? onProbe;
  bool throwOnDurationListen = false;
  void Function(int attempt)? onOutputAttempt;
  Future<void> Function(int attempt)? onBeforeOutputCreation;
  void Function(int attempt)? onDisposeOutputAttempt;

  PlPlayerController createController() {
    final ports = this.ports = PlayerLifecyclePorts(
      createPlayer: (configuration) async {
        createdPlayers.add(configuration);
        final player = _FakePlayer(
          throwOnDurationListen: throwOnDurationListen,
        );
        players.add(player);
        onPlayerCreated?.call(player);
        return player;
      },
      probeHdr: () async {
        probeCalls++;
        final override = onProbe;
        if (override != null) return override(probeCalls);
        return const HdrCapabilities(unsupportedReason: 'test-probe');
      },
      createOutput: (player, configuration) async {
        final attempt = ++outputAttempts;
        onOutputAttempt?.call(attempt);
        await onBeforeOutputCreation?.call(attempt);
        if (failOutputAttempts.contains(attempt)) {
          throw StateError('injected output creation failure $attempt');
        }
        outputConfigurations.add(configuration);
        final output = _FakeVideoController(
          player,
          configuration,
        );
        outputs.add(output);
        return output;
      },
      displayChanges: () => const Stream<void>.empty(),
      disposeOutput: (output) async {
        final attempt = ++disposeOutputAttempts;
        onDisposeOutputAttempt?.call(attempt);
        disposeEvents.add('output:${identityHashCode(output)}');
        if (failDisposeOutputAttempts.contains(attempt)) {
          throw StateError('injected output disposal failure $attempt');
        }
      },
      disposePlayer: (player) async {
        disposeEvents.add('player:${identityHashCode(player)}');
        (player as _FakePlayer).disposed = true;
      },
    );
    controller = PlPlayerController.getInstance(lifecyclePorts: ports);
    return controller!;
  }

  Future<void> closePlayers() async {
    for (final player in players) {
      await player.closeStreams();
    }
  }
}

class _FakePlayer implements Player {
  _FakePlayer({bool throwOnDurationListen = false}) {
    final durationStream = throwOnDurationListen
        ? _ThrowingStream<Duration>()
        : _empty<Duration>();
    stream = PlayerStream(
      _empty<Playlist>(),
      playing.stream,
      _empty<bool>(),
      _empty<Duration>(),
      durationStream,
      _empty<double>(),
      _empty<double>(),
      _empty<double>(),
      _empty<bool>(),
      _empty<double>(),
      buffer.stream,
      _empty<PlaylistMode>(),
      _empty<bool>(),
      _empty<AudioParams>(),
      videoParams.stream,
      _empty<double?>(),
      _empty<double?>(),
      _empty<AudioDevice>(),
      _empty<List<AudioDevice>>(),
      _empty<Track>(),
      _empty<Tracks>(),
      _empty<int?>(),
      _empty<int?>(),
      _empty<List<String>>(),
      _empty<PlayerLog>(),
      _empty<String>(),
    );
  }

  final videoParams = StreamController<VideoParams>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final buffer = StreamController<Duration>.broadcast(sync: true);
  @override
  late final PlayerStream stream;
  @override
  PlayerState state = const PlayerState(
    duration: Duration(minutes: 2),
    rate: 1,
  );
  @override
  List<Media> current = [];
  final opened = <Playable>[];
  Future<void> Function(Playable playable, bool play)? openHandler;
  @override
  bool disposed = false;

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) {
    opened.add(playable);
    if (playable is Media) current = [playable];
    return openHandler?.call(playable, play) ?? Future<void>.value();
  }

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {
    state = state.copyWith(rate: rate);
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {}

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => '';

  @override
  Future<void> dispose({bool synchronized = true}) async {
    disposed = true;
  }

  Future<void> closeStreams() async {
    await videoParams.close();
    await playing.close();
    await buffer.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingStream<T> extends Stream<T> {
  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw StateError('injected stream subscription failure');
}

class _FakeVideoController implements VideoController {
  _FakeVideoController(this.player, this.configuration) {
    final platformController = _FakePlatformVideoController(
      player,
      configuration,
    );
    platform.complete(platformController);
    notifier.value = platformController;
  }

  @override
  final Player player;

  final VideoControllerConfiguration configuration;

  @override
  final Completer<PlatformVideoController> platform = Completer();

  @override
  final ValueNotifier<PlatformVideoController?> notifier = ValueNotifier(null);

  @override
  final ValueNotifier<int?> id = ValueNotifier(null);

  @override
  final ValueNotifier<Rect?> rect = ValueNotifier(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlatformVideoController implements PlatformVideoController {
  _FakePlatformVideoController(this.player, this.configuration);

  @override
  final Player player;

  @override
  final VideoControllerConfiguration configuration;

  @override
  final ValueNotifier<bool> nativeSurfaceActiveNotifier = ValueNotifier(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Stream<T> _empty<T>() => Stream<T>.empty();
