import 'dart:async';
import 'dart:io';

import 'package:piliplus/plugin/pl_player/controller.dart';
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart';
import 'package:piliplus/plugin/pl_player/models/player_lifecycle_ports.dart';
import 'package:piliplus/utils/path_utils.dart' as app_paths;
import 'package:piliplus/utils/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
// Test-only ports into the real Session coordinator and decode review.
// ignore: implementation_imports
import 'package:media_kit_video/src/hdr/hdr_open_coordinator.dart';
// ignore: implementation_imports
import 'package:media_kit_video/src/hdr/hdr_decoder_review.dart';
import 'package:piliplus/plugin/pl_player/route_options.dart';
import 'package:piliplus/utils/storage_key.dart';
import 'package:piliplus/pages/setting/models/play_settings.dart';
import 'package:piliplus/pages/setting/models/video_settings.dart';
import 'package:material_ui/material_ui.dart';
import 'package:piliplus/pages/setting/models/model.dart';
import 'package:piliplus/pages/video/controller.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/common/video/video_type.dart';
import 'package:piliplus/models/common/sponsor_block/skip_type.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide HdrCapabilities;
import 'package:media_kit_video/media_kit_video.dart'
    as routing
    show HdrCapabilities;
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

  for (final scenario in [
    'file-page',
    'file-entry',
    'no-page',
    'latest',
    'replacement',
    'dispose',
    'output-debt',
    'backend-debt',
    'coordinator-debt',
  ]) {
    test(
      'V2 local first-open $scenario settings retain a runnable source',
      () async {
        await GStorage.setting.put(SettingBoxKey.enableHA, true);
        await GStorage.setting.put(
          SettingBoxKey.hardwareDecoding,
          'mediacodec',
        );
        final backend = _RouteBackend();
        final controller = harness.createController(routeBackend: backend)
          ..onVideoViewMounted();
        VideoDetailController? page;
        if (scenario != 'no-page' && scenario != 'dispose') {
          page = VideoDetailController()..isFileSource = true;
          await page.probeRoutingForTesting(PlayUrlModel(), 1);
        }
        final started = Completer<void>();
        final release = Completer<void>();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('com.alexmercerind/media_kit_video');
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'VideoRouteCapabilities.Get' &&
              !started.isCompleted) {
            started.complete();
            await release.future;
          }
          return {
            'schema': 1,
            'platform': 'android',
            'display': {
              'status': 'resolved',
              'platform': 'android',
              'revision': 'v2',
              'displayId': 7,
              'modeId': 2,
              'hdrTypes': <int>[],
            },
            'hdr': {
              'sdkInt': 34,
              'p5Pipeline': true,
              'dataSpaceBridgeLoaded': false,
            },
            'sources': <Object>[],
          };
        });
        try {
          var source = scenario == 'file-entry'
              ? FileSource(
                  dir: '/tmp/download',
                  typeTag: 'video',
                  isMp4: true,
                  hasDashAudio: false,
                )
              : DirectFileSource('/tmp/diagnostic.mp4');
          final opening = controller.setDataSource(
            source,
            autoplay: false,
            seekTo: const Duration(seconds: 3),
          );
          await started.future.timeout(const Duration(seconds: 5));
          await GStorage.setting.put(SettingBoxKey.enableHA, false);
          var applied = false;
          final applying = controller.applyRoutePreferences().then((_) {
            applied = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(
            applied,
            false,
            reason: 'settings await private init and cleanup before reopening',
          );
          Future<void>? second;
          if (scenario == 'latest') {
            await GStorage.setting.put(SettingBoxKey.hdrMode, HdrMode.off.name);
            second = controller.applyRoutePreferences();
          } else if (scenario == 'replacement') {
            source = DirectFileSource(
              '/tmp/replacement.mp4',
              routeOptions: AppVideoRouteRequest.fromPreferences(
                hdrMode: HdrMode.off,
                enableHA: false,
                hardwareDecoding: 'mediacodec',
                android: true,
              ).resolve(),
            );
            second = controller.setDataSource(
              source,
              autoplay: false,
              seekTo: const Duration(seconds: 3),
            );
            await second.timeout(const Duration(seconds: 5));
          }
          final latest = controller.dataSource.routeOptions;
          if (scenario == 'dispose') {
            controller.dispose();
            harness.controller = null;
          } else if (scenario == 'output-debt' || scenario == 'backend-debt') {
            backend.failingCleanupStage = scenario.startsWith('output')
                ? 'output'
                : 'backend';
          }
          release.complete();
          if (scenario == 'output-debt' || scenario == 'backend-debt') {
            expect(
              await backend.teardownRetained.future.timeout(
                const Duration(seconds: 5),
              ),
              same(harness.players.first),
            );
            expect(controller.hasBlockedTeardowns, true);
            expect(applied, false);
            expect(harness.players, hasLength(1));
            expect(harness.players.first.disposed, false);
            expect(backend.plans, isEmpty);
            backend
              ..failStop = false
              ..failingCleanupStage = null;
          }
          await applying.timeout(const Duration(seconds: 5));
          await second?.timeout(const Duration(seconds: 5));
          await opening.timeout(const Duration(seconds: 5));
          if (scenario == 'dispose') {
            await controller.teardownDrain;
            expect(harness.players, hasLength(1));
            expect(harness.players.single.disposed, true);
            expect(harness.players.single.opened, isEmpty);
            expect(backend.plans, isEmpty);
            expect(controller.videoPlayerController, isNull);
            return;
          }
          expect(
            controller.hdrVideoSession.value,
            isNotNull,
            reason: 'persisted valid software setting must not strand the first local source',
          );
          expect(backend.plans.last.route.hwdec, 'no');
          expect(backend.plans, hasLength(1));
          expect(controller.dataSource.runtimeType, source.runtimeType);
          expect(controller.dataSource.videoSource, source.videoSource);
          expect(controller.dataSource.routeOptions, same(latest));
          expect(
            harness.players.last.current.single.start,
            const Duration(seconds: 3),
          );
          if (scenario == 'latest') {
            expect(latest!.output.isRequired, true);
          } else if (scenario == 'replacement') {
            // Carried options prove that enableHA:false from app preferences
            // survives replacement as a software requirement.
            expect(latest!.decode.isRequired, true);
          }
          expect(controller.hasBlockedTeardowns, false);
          expect(
            controller.hdrVideoSession.value!.report.value.options,
            same(controller.dataSource.routeOptions),
          );
          expect(
            controller.hdrVideoSession.value!.report.value.actual?.hwdec,
            'no',
          );
          expect(
            controller
                .hdrVideoSession
                .value!
                .report
                .value
                .optionFulfillment
                ?.decode,
            VideoRouteOptionStatus.fulfilled,
          );
          expect(harness.players, hasLength(2));
          expect(harness.players.first.disposed, true);
          expect(harness.players.first.opened, isEmpty);
          expect(harness.players.last.disposed, false);
          if (scenario == 'coordinator-debt') {
            final activePlayer = harness.players.last;
            final session = controller.hdrVideoSession.value!;
            backend.failStop = true;
            final stopping = controller.stopForRouteOptions(
              'coordinator cleanup',
            );
            expect(
              await backend.teardownRetained.future.timeout(
                const Duration(seconds: 5),
              ),
              same(activePlayer),
            );
            expect(controller.hasBlockedTeardowns, true);
            expect(session.lastDisposeReport!.clean, false);
            expect(activePlayer.disposed, false);
            final recovering = controller.setDataSource(
              DirectFileSource('/tmp/recovered.mp4', routeOptions: latest),
              autoplay: false,
            );
            expect(harness.players, hasLength(2));
            backend.failStop = false;
            await Future.wait([stopping, recovering])
                .timeout(const Duration(seconds: 5));
            expect(session.lastDisposeReport!.clean, true);
            expect(controller.hasBlockedTeardowns, false);
            expect(activePlayer.disposed, true);
            expect(harness.players, hasLength(3));
            expect(
              controller.videoPlayerController,
              same(harness.players.last),
            );
          }
        } finally {
          backend
            ..failStop = false
            ..failingCleanupStage = null;
          if (!release.isCompleted) release.complete();
          messenger.setMockMethodCallHandler(channel, (call) async => null);
          page?.releaseRoutingForTesting();
          await GStorage.setting.delete(SettingBoxKey.hdrMode);
          await GStorage.setting.delete(SettingBoxKey.enableHA);
          await GStorage.setting.delete(SettingBoxKey.hardwareDecoding);
        }
      },
    );
  }

  test('V2 baseline local first-open remains playable', () async {
    await GStorage.setting.put(SettingBoxKey.enableHA, true);
    await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'mediacodec');
    final backend = _RouteBackend();
    final controller = harness.createController(routeBackend: backend)
      ..onVideoViewMounted();
    final page = VideoDetailController()..isFileSource = true;
    await page.probeRoutingForTesting(PlayUrlModel(), 1);
    final started = Completer<void>();
    final release = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'VideoRouteCapabilities.Get' && !started.isCompleted) {
        started.complete();
        await release.future;
      }
      return {
        'schema': 1,
        'platform': 'android',
        'display': {
          'status': 'resolved',
          'platform': 'android',
          'revision': 'v2',
          'displayId': 7,
          'modeId': 2,
          'hdrTypes': <int>[],
        },
        'hdr': {
          'sdkInt': 34,
          'p5Pipeline': true,
          'dataSpaceBridgeLoaded': false,
        },
        'sources': <Object>[],
      };
    });
    try {
      final opening = controller.setDataSource(
        DirectFileSource('/tmp/diagnostic.mp4'),
        autoplay: false,
      );
      await started.future.timeout(const Duration(seconds: 5));
      release.complete();
      await opening.timeout(const Duration(seconds: 5));
      expect(
        controller.hdrVideoSession.value,
        isNotNull,
        reason: 'persisted hardware intent must use the runnable copy route',
      );
      expect(backend.plans.single.route.hwdec, 'mediacodec-copy');
      expect(
        controller.hdrVideoSession.value!.report.value.actual?.hwdec,
        'mediacodec-copy',
      );
    } finally {
      if (!release.isCompleted) release.complete();
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      page.releaseRoutingForTesting();
      await GStorage.setting.delete(SettingBoxKey.enableHA);
      await GStorage.setting.delete(SettingBoxKey.hardwareDecoding);
    }
  });

  test(
    'actual Android controller sends one snapshot through retry and refresh',
    () async {
      final backend = _RouteBackend()..failFirst = true;
      final controller = harness.createController(routeBackend: backend)
        ..onVideoViewMounted();
      final options = AppVideoRouteRequest.fromPreferences(
        hdrMode: HdrMode.off,
        enableHA: true,
        hardwareDecoding: 'mediacodec',
        android: true,
      ).resolve();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/config.mp4',
          audioSource: null,
          videoSpec: VideoSourceSpec(
            codec: 'avc1.640028',
            width: 1920,
            height: 1080,
          ),
          routeOptions: options,
        ),
        autoplay: false,
      );
      expect(options.importPreference, VideoImportPreference.preferCopy);
      expect(backend.plans, hasLength(2));
      for (final plan in backend.plans) {
        expect(plan.options, same(options));
        expect(plan.route.outputTransfer, HdrOutputTransfer.sdr);
      }
      // The fake backend accepts the alternate import after injected failure.
      // This tests retry ordering, not native direct-bridge authorization.
      expect(backend.plans[0].route.hwdec, 'mediacodec-copy');
      expect(backend.plans[1].route.hwdec, 'mediacodec');
      expect(controller.dataSource.routeOptions, same(options));
      expect(
        harness.createdPlayers.single.options.containsKey('target-prim'),
        false,
      );
      expect(
        harness.createdPlayers.single.options.containsKey('target-trc'),
        false,
      );
      expect(
        controller.hdrVideoSession.value!.report.value.options,
        same(options),
      );
      expect(
        controller.hdrVideoSession.value!.report.value.actual?.hwdec,
        backend.plans.last.route.hwdec,
      );
      final configuredBeforeRefresh = backend.plans.length;
      await controller.refreshPlayer(reason: 'config-snapshot-regression');
      expect(backend.plans.length, greaterThan(configuredBeforeRefresh));
      for (final plan in backend.plans.skip(configuredBeforeRefresh)) {
        expect(plan.options, same(options));
        expect(plan.route.outputTransfer, HdrOutputTransfer.sdr);
      }
    },
  );

  test('copy preference reaches actual configure before direct', () async {
    final backend = _RouteBackend();
    final controller = harness.createController(routeBackend: backend)
      ..onVideoViewMounted();
    final options = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.off,
      enableHA: true,
      hardwareDecoding: 'mediacodec-copy,auto-safe',
      android: true,
    ).resolve();
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/copy.mp4',
        audioSource: null,
        routeOptions: options,
      ),
      autoplay: false,
    );
    expect(backend.plans.first.route.hwdec, 'mediacodec-copy');
    expect(backend.plans.first.options, same(options));
  });

  test(
    'unsupported persisted Android mode stops before native creation',
    () async {
      await GStorage.setting.put(SettingBoxKey.enableHA, true);
      await GStorage.setting.put(
        SettingBoxKey.hardwareDecoding,
        'videotoolbox',
      );
      try {
        final controller = harness.createController(
          routeBackend: _RouteBackend(),
        );
        await controller.setDataSource(
          NetworkSource(
            videoSource: 'https://example.invalid/unsupported.mp4',
            audioSource: null,
          ),
          autoplay: false,
        );
        expect(harness.createdPlayers, isEmpty);
        expect(controller.hdrOutputError.value, contains('Android'));
      } finally {
        await GStorage.setting.delete(SettingBoxKey.enableHA);
        await GStorage.setting.delete(SettingBoxKey.hardwareDecoding);
      }
    },
  );

  test('real HDR setting persists then updates Session and report with one snapshot', () async {
    final backend = _RouteBackend();
    final controller = harness.createController(routeBackend: backend)
      ..onVideoViewMounted();
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/settings.mp4',
        audioSource: null,
      ),
      autoplay: false,
    );
    EffectiveVideoRouteOptions? invalidated;
    EffectiveVideoRouteOptions? changed;
    controller
      ..onRouteOptionsInvalidated = (options) {
        expect(GStorage.setting.get(SettingBoxKey.hdrMode), HdrMode.off.name);
        invalidated = options;
      }
      ..onRouteOptionsChanged = (options) async {
        expect(options, same(invalidated));
        expect(
          controller.hdrVideoSession.value!.report.value.options,
          same(options),
        );
        changed = options;
      };
    var setStateCalls = 0;
    try {
      final setting = playSettings.first as PopupModel<HdrMode>;
      final updated = Completer<void>();
      setting.onSelected(HdrMode.off, () {
        setStateCalls++;
        updated.complete();
      });
      await updated.future;
      expect(setStateCalls, 1);
      expect(changed, isNotNull);
      expect(controller.dataSource.routeOptions, same(changed));
      expect(backend.plans.last.options, same(changed));
      expect(backend.plans.last.route.outputTransfer, HdrOutputTransfer.sdr);
      // HDR-off must survive the replacement source's rebuilt options.
      expect(changed!.output.isRequired, true);
    } finally {
      controller
        ..onRouteOptionsInvalidated = null
        ..onRouteOptionsChanged = null;
      await GStorage.setting.delete(SettingBoxKey.hdrMode);
    }
  });

  test('failure stop keeps failed report snapshot and prevents alternate configure', () async {
    final backend = _RouteBackend()..failFirst = true;
    final controller = harness.createController(routeBackend: backend)
      ..onVideoViewMounted();
    final options = EffectiveVideoRouteOptions.resolve(
      application: const VideoRouteOptions(
        failurePolicy: VideoRouteFailurePolicy.stop,
      ),
    );
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/stop.mp4',
        audioSource: null,
        routeOptions: options,
      ),
      autoplay: false,
    );
    expect(backend.plans, hasLength(1));
    expect(
      controller.hdrVideoSession.value!.report.value.options,
      same(options),
    );
    expect(controller.hdrVideoSession.value!.report.value.actual, isNull);
  });

  test('unsupported settings stop old source and a later valid source tears down normally', () async {
    final backend = _RouteBackend();
    final controller = harness.createController(routeBackend: backend)
      ..onVideoViewMounted();
    await controller.setDataSource(
      NetworkSource(
        videoSource: 'https://example.invalid/before.mp4',
        audioSource: null,
      ),
      autoplay: false,
    );
    final first = harness.players.single;
    await GStorage.setting.put(SettingBoxKey.enableHA, true);
    await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'videotoolbox');
    try {
      await controller.applyRoutePreferences();
      expect(first.disposed, true);
      expect(controller.hdrVideoSession.value, isNull);
      expect(controller.videoPlayerController, isNull);
      await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto');
      await controller.applyRoutePreferences();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/after.mp4',
          audioSource: null,
        ),
        autoplay: false,
      );
      expect(harness.players, hasLength(2));
      expect(controller.hdrVideoSession.value!.report.value.actual, isNotNull);
      controller.dispose();
      harness.controller = null;
      await controller.teardownDrain;
      expect(harness.players.last.disposed, true);
    } finally {
      await GStorage.setting.delete(SettingBoxKey.enableHA);
      await GStorage.setting.delete(SettingBoxKey.hardwareDecoding);
    }
  });

  test(
    'failed Session cleanup retains exact Player until actual retry completes',
    () async {
      final backend = _RouteBackend();
      final controller = harness.createController(routeBackend: backend)
        ..onVideoViewMounted();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/cleanup-debt.mp4',
          audioSource: null,
        ),
        autoplay: false,
      );
      final player = harness.players.single;
      backend.failStop = true;
      final stop = controller.stopForRouteOptions(
        'primary-configuration-failure',
      );
      await backend.stopFailed.future;
      for (
        var turn = 0;
        turn < 100 && !controller.hasBlockedTeardowns;
        turn++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.hasBlockedTeardowns, true);
      expect(player.disposed, false);
      expect(harness.disposeEvents, isEmpty);
      expect(controller.hdrOutputError.value, 'primary-configuration-failure');
      backend.failStop = false;
      await stop;
      expect(controller.hasBlockedTeardowns, false);
      expect(player.disposed, true);
      expect(harness.disposeEvents, ['player:${identityHashCode(player)}']);
    },
  );

  for (final stage in ['output', 'backend']) {
    test(
      'actual Session $stage cleanup failure retains Player and blocks recovery until clean',
      () async {
        final backend = _RouteBackend();
        final controller = harness.createController(routeBackend: backend)
          ..onVideoViewMounted();
        await controller.setDataSource(
          NetworkSource(
            videoSource: 'https://example.invalid/$stage-before.mp4',
            audioSource: null,
          ),
          autoplay: false,
        );
        final player = harness.players.single;
        final session = controller.hdrVideoSession.value!;
        backend.failingCleanupStage = stage;
        final stop = controller.stopForRouteOptions('primary-$stage-failure');
        await backend.cleanupFailed.future;
        for (
          var turn = 0;
          turn < 100 && !controller.hasBlockedTeardowns;
          turn++
        ) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(controller.hasBlockedTeardowns, true);
        expect(session.lastDisposeReport!.clean, false);
        if (stage == 'output') {
          expect(session.lastDisposeReport!.slotError, isNotNull);
          expect(backend.cleanupCalls, ['output']);
        } else {
          expect(session.lastDisposeReport!.backendError, isNotNull);
          expect(backend.cleanupCalls, ['output', 'backend']);
        }
        expect(player.disposed, false);
        expect(harness.disposeEvents, isEmpty);
        expect(controller.hdrOutputError.value, 'primary-$stage-failure');
        final recovery = controller.setDataSource(
          NetworkSource(
            videoSource: 'https://example.invalid/$stage-after.mp4',
            audioSource: null,
          ),
          autoplay: false,
        );
        await Future<void>.delayed(Duration.zero);
        expect(harness.players, hasLength(1));
        backend.failingCleanupStage = null;
        await Future.wait([stop, recovery]).timeout(const Duration(seconds: 5));
        expect(session.lastDisposeReport!.clean, true);
        expect(controller.hasBlockedTeardowns, false);
        expect(player.disposed, true);
        expect(harness.players, hasLength(2));
        expect(controller.videoPlayerController, same(harness.players.last));
        expect(
          controller.hdrVideoSession.value!.report.value.actual,
          isNotNull,
        );
        controller.dispose();
        harness.controller = null;
        await controller.teardownDrain;
        expect(harness.players.last.disposed, true);
      },
    );
  }

  for (final rejectWhileHeld in [false, true]) {
    test(
      rejectWhileHeld
          ? 'invalid settings retire a held page source without a second open'
          : 'configuration waits for the real page source transaction',
      () async {
        await GStorage.setting.put(
          SettingBoxKey.pgcSkipType,
          SkipType.disable.index,
        );
        final backend = _RouteBackend();
        final controller = harness.createController(routeBackend: backend)
          ..onVideoViewMounted();
        await controller.setDataSource(
          NetworkSource(
            videoSource: 'https://example.invalid/baseline.mp4',
            audioSource: null,
          ),
          autoplay: false,
        );
        final page = VideoDetailController()
          ..args = const {}
          ..aid = 1
          ..bvid = 'fixture'
          ..cid = RxInt(1)
          ..videoType = VideoType.ugc
          ..isFileSource = false
          ..isVertical = RxBool(false)
          ..defaultST = const Duration(seconds: 1);
        page.vttSubtitlesIndex.value = 0;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('com.alexmercerind/media_kit_video');
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'VideoRouteCapabilities.Get') return null;
          final specs = (call.arguments as Map)['sources'] as List;
          return {
            'schema': 1,
            'platform': 'android',
            'display': {
              'status': 'resolved',
              'platform': 'android',
              'revision': 'current',
              'displayId': 7,
              'modeId': 2,
              'hdrTypes': <int>[],
            },
            'hdr': {
              'sdkInt': 34,
              'p5Pipeline': true,
              'dataSpaceBridgeLoaded': false,
            },
            'sources': [
              for (final Map spec in specs)
                {
                  'key': spec['key'],
                  'censusComplete': true,
                  'reason': 'source fixture',
                  'decoders': [
                    {
                      'name': 'vendor.avc',
                      'mime': 'video/avc',
                      'kind': 'hardware',
                      'support': 'supported',
                      'reason': 'decoder fixture',
                      'path': 'codec',
                    },
                  ],
                },
            ],
          };
        });
        final sourceStarted = Completer<void>();
        final releaseSource = Completer<void>();
        var applied = false;
        backend.beforeOpen = (plan) async {
          if (plan.media.uri == 'https://example.invalid/selected.mp4') {
            sourceStarted.complete();
            await releaseSource.future;
          }
        };
        try {
          expect(
            await page.probeRoutingForTesting(
              PlayUrlModel(
                dash: Dash(
                  video: [
                    VideoItem(
                      id: 80,
                      quality: VideoQuality.high1080,
                      codecs: 'avc1.640028',
                      width: 1920,
                      height: 1080,
                      baseUrl: 'https://example.invalid/selected.mp4',
                    ),
                  ],
                ),
              ),
              1,
            ),
            true,
          );
          expect(page.routingSelectionForTesting!.displayHdr, false);
          page.currentVideoQa.value = VideoQuality.high1080;
          final applying = controller.applyRoutePreferences().then((_) {
            applied = true;
          });
          await sourceStarted.future.timeout(const Duration(seconds: 5));
          expect(applied, false);
          final options = page.routingSelectionForTesting!.options!;
          expect(controller.dataSource.routeOptions, same(options));
          expect(backend.plans.last.options, same(options));
          final configured = backend.plans.length;
          Future<void>? rejecting;
          if (rejectWhileHeld) {
            await GStorage.setting.put(
              SettingBoxKey.hardwareDecoding,
              'videotoolbox',
            );
            rejecting = controller.applyRoutePreferences();
            expect(page.routingSelectionForTesting, isNull);
          }
          releaseSource.complete();
          await applying.timeout(const Duration(seconds: 5));
          expect(applied, true);
          if (rejecting == null) {
            expect(
              controller.hdrVideoSession.value!.report.value.options,
              same(options),
            );
            expect(
              controller.hdrVideoSession.value!.report.value.actual,
              isNotNull,
            );
          } else {
            await rejecting.timeout(const Duration(seconds: 5));
            expect(backend.plans, hasLength(configured));
          }
          final opens = harness.players.single.opened.length;
          if (!rejectWhileHeld) {
            await GStorage.setting.put(
              SettingBoxKey.hardwareDecoding,
              'videotoolbox',
            );
            await controller.applyRoutePreferences();
          }
          expect(controller.videoPlayerController, isNull);
          expect(harness.players.single.opened, hasLength(opens));
          expect(controller.hdrOutputError.value, contains('unavailable'));
        } finally {
          if (!releaseSource.isCompleted) releaseSource.complete();
          backend.beforeOpen = null;
          page.releaseRoutingForTesting();
          await GStorage.setting.delete(SettingBoxKey.pgcSkipType);
          await GStorage.setting.delete(SettingBoxKey.hardwareDecoding);
          messenger.setMockMethodCallHandler(channel, (call) async => null);
        }
      },
    );
  }

  testWidgets('actual HA switch persists and enforces software CPU decode', (
    tester,
  ) async {
    final backend = _RouteBackend();
    late PlPlayerController controller;
    await tester.runAsync(() async {
      controller = harness.createController(routeBackend: backend)
        ..onVideoViewMounted();
      await controller.setDataSource(
        NetworkSource(
          videoSource: 'https://example.invalid/hardware-setting.mp4',
          audioSource: null,
        ),
        autoplay: false,
      );
    });
    try {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: videoSettings.first.widget)),
      );
      final options = await tester.runAsync(() async {
        final changed = Completer<EffectiveVideoRouteOptions>();
        controller.onRouteOptionsChanged = (options) async =>
            changed.complete(options);
        await tester.tap(find.byType(Switch));
        return changed.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(GStorage.setting.get(SettingBoxKey.enableHA), false);
      expect(options!.decode.isRequired, true);
      expect(options.decode.target, VideoDecodeTarget.software);
      expect(backend.plans.last.route.hwdec, 'no');
      expect(backend.plans.last.options, same(options));
      expect(
        controller.hdrVideoSession.value!.report.value.options,
        same(options),
      );
      expect(
        controller.hdrVideoSession.value!.report.value.actual?.hwdec,
        'no',
      );
      expect(
        controller
            .hdrVideoSession
            .value!
            .report
            .value
            .optionFulfillment
            ?.decode,
        VideoRouteOptionStatus.fulfilled,
      );
    } finally {
      controller.onRouteOptionsChanged = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await GStorage.setting.delete(SettingBoxKey.enableHA);
        controller.dispose();
        harness.controller = null;
        await controller.teardownDrain;
      });
    }
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
      // The probe models native HDR intent; the host still chooses its VO.
      // _videoConfiguration pins libmpv only on macOS, not on Linux.
      expect(oldOutput.configuration.vo, Platform.isMacOS ? 'libmpv' : null);
      expect(oldOutput.configuration.darwin.useNativeSurface, isTrue);

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

  PlPlayerController createController({_RouteBackend? routeBackend}) {
    final ports = this.ports = PlayerLifecyclePorts(
      onHdrTeardownRetainedForTesting: (player) {
        final signal = routeBackend?.teardownRetained;
        if (signal != null && !signal.isCompleted) signal.complete(player);
      },
      androidSessionOverride: routeBackend == null ? null : true,
      createHdrSession: routeBackend == null
          ? null
          : (player, target) {
              routeBackend.player = player;
              return HdrVideoSession.forTesting(
                player: player,
                isAndroid: true,
                target: target,
                backend: routeBackend,
                disposeOutputForTesting: routeBackend.disposeOutput,
                disposeBackendForTesting: routeBackend.disposeBackend,
                capabilitiesProvider: () async => const routing.HdrCapabilities(
                  sdkInt: 34,
                  displayHdrTypes: {},
                  hevcDecoders: [],
                  dolbyVisionDecoders: [],
                  p5PipelineAvailable: true,
                  dataSpaceBridgeLoaded: false,
                  dataSpaceExt: null,
                ),
              );
            },
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
  Future<void> pause({bool synchronized = true}) async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {}

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

class _RouteBackend implements HdrOpenBackend<HdrOpenPlan> {
  late Player player;
  final plans = <HdrOpenPlan>[];
  bool failFirst = false;
  Future<void> Function(HdrOpenPlan)? beforeOpen;
  String hwdec = '';
  String? failingCleanupStage;
  final cleanupFailed = Completer<void>();
  final teardownRetained = Completer<Player>();
  final cleanupCalls = <String>[];
  Future<void> disposeOutput() async {
    cleanupCalls.add('output');
    if (failingCleanupStage == 'output') {
      if (!cleanupFailed.isCompleted) cleanupFailed.complete();
      throw StateError('injected output slot cleanup failure');
    }
  }

  Future<void> disposeBackend() async {
    cleanupCalls.add('backend');
    if (failingCleanupStage == 'backend') {
      if (!cleanupFailed.isCompleted) cleanupFailed.complete();
      throw StateError('injected backend cleanup failure');
    }
  }

  bool failStop = false;
  int failedStops = 0;
  final stopFailed = Completer<void>();
  @override
  Future<void> validate(HdrOpenPlan plan) async {}
  @override
  Future<void> stop() async {
    if (failStop) {
      if (++failedStops == 3 && !stopFailed.isCompleted) stopFailed.complete();
      throw StateError('injected coordinator cleanup failure');
    }
  }

  @override
  Future<void> resetOwnedConfiguration() async {}
  @override
  Future<void> prepareOutput(HdrOpenPlan plan) async {}
  @override
  Future<void> configure(HdrOpenPlan plan) async {
    plans.add(plan);
    hwdec = plan.route.hwdec;
    if (failFirst && plans.length == 1) {
      throw StateError('injected first configure failure (${plan.route.hwdec})');
    }
  }

  @override
  Future<void> waitForOutput(HdrOpenPlan plan) async {}
  @override
  Future<void> open(
    HdrOpenPlan plan, {
    Duration? start,
    required bool play,
  }) async {
    await beforeOpen?.call(plan);
    await player.open(plan.media.copyWith(start: start), play: play);
  }

  @override
  Future<HdrReviewFacts> reviewFacts(HdrOpenPlan plan) async => HdrReviewFacts(
    path: plan.media.uri,
    codec: 'h264',
    hwdecCurrent: hwdec,
    videoParams: const VideoParams(primaries: 'bt.709', gamma: 'bt.1886'),
    decoderObservation: HdrDecoderObservation(
      playlistEntryId: 1,
      fileLoadedEpoch: plans.length,
      decoder: hwdec == 'no' ? 'h264' : 'h264_mediacodec',
      decoderDescription: 'test',
      hwdec: hwdec,
      pixelFormat: hwdec == 'mediacodec' ? 'mediacodec' : 'yuv420p',
      hwPixelFormat: hwdec == 'mediacodec' ? 'mediacodec' : '',
    ),
  );
  @override
  HdrBackendObservation observe() => HdrBackendObservation(hwdecCurrent: hwdec);
}
