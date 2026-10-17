// DV003: real production chain for sniffed DOVI facts — fake sniff at the
// controller seam, real _resolveDoviFacts caching/keys, real
// DashRouteSelection.query, then judgment through the published selection.
// The 126 fixture mirrors the BV11f4y1K7Wx capture: DV tier delivered as a
// plain hvc1 HEVC codec string, so the container record is the only profile
// source and the rendition key (revision/cid/baseUrl) is the only safe
// cache token.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/pages/video/controller.dart';
import 'package:piliplus/plugin/pl_player/controller.dart';
import 'package:piliplus/plugin/pl_player/dovi_sniff.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' as app_hdr;
import 'package:piliplus/plugin/pl_player/models/player_lifecycle_ports.dart';
import 'package:piliplus/plugin/pl_player/source_selection.dart';
import 'package:piliplus/utils/path_utils.dart' as app_paths;
import 'package:piliplus/utils/storage.dart';
import 'package:get/get.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart';

const kP8Compat4 = DoviFacts(
  profile: 8,
  level: 7,
  rpuPresent: true,
  elPresent: false,
  blPresent: true,
  compatibilityId: 4,
  mdCompression: 0,
);

VideoItem dv126({
  String baseUrl = 'https://cdn.example/dv1-1-30126.m4s',
  String codec = 'hvc1.2.4.L150.90',
}) => VideoItem(
  id: 126,
  quality: VideoQuality.fromCode(126),
  codecs: codec,
  baseUrl: baseUrl,
  segmentBase: {'initialization': '0-816'},
  width: 3840,
  height: 2160,
  frameRate: '29.970',
  bandWidth: 9612522,
);

VideoItem sdr1080({int bandWidth = 4021000}) => VideoItem(
  id: 80,
  quality: VideoQuality.high1080,
  codecs: 'avc1.640028',
  baseUrl: 'https://cdn.example/sdr1-1-30112.m4s',
  width: 1920,
  height: 1080,
  frameRate: '29.970',
  bandWidth: bandWidth,
);

PlayUrlModel playUrlOf(List<VideoItem> tracks) =>
    PlayUrlModel(dash: Dash(video: tracks));

class _Harness {
  _Harness(this.owner, this.page);

  final PlPlayerController owner;
  final VideoDetailController page;
}

class _RouteBackend {
  /// VideoRouteCapabilities.Get results per call; the last entry repeats.
  /// A null entry makes the capability query fail (unknown branch).
  List<Object?> results;

  /// Codec-path decode verdict reported for every requested source.
  String codecSupport;

  _RouteBackend(this.results, {this.codecSupport = 'supported'});
  int calls = 0;

  Object? next() {
    if (calls >= results.length) return results.last;
    return results[calls++];
  }

  Object? handle(MethodCall call) {
    if (call.method != 'VideoRouteCapabilities.Get') return null;
    final result = next();
    if (result == null) return null;
    final args = call.arguments as Map;
    return {
      'schema': 1,
      'platform': 'android',
      'display': {
        'status': 'resolved',
        'platform': 'android',
        'displayId': 0,
        'modeId': 0,
        'revision': result,
        'hdrTypes': const [1, 2, 3, 4],
      },
      'hdr': {
        'sdkInt': 34,
        'p5Pipeline': true,
        'dataSpaceBridgeLoaded': true,
        'nativeDvBridgeApi': 1,
        'dolbyVisionDecoders': [
          {
            'name': 'vendor.dv',
            'mimeType': 'video/dolby-vision',
            'hardwareAcceleration': true,
            'profiles': [32, 256],
          },
        ],
        'hevcDecoders': [
          {
            'name': 'vendor.hevc',
            'mimeType': 'video/hevc',
            'hardwareAcceleration': true,
            'profiles': [1, 2],
          },
        ],
      },
      'sources': [
        for (final Map spec in args['sources'] as List)
          {
            'key': spec['key'],
            'censusComplete': true,
            'reason': 'test',
            'decoders': [
              {
                'name': 'vendor.hevc',
                'mime': 'video/hevc',
                'kind': 'hardware',
                'support': codecSupport,
                'reason': 'test',
                'path': 'codec',
              },
              {
                'name': 'vendor.dv',
                'mime': 'video/dolby-vision',
                'kind': 'hardware',
                'support': 'supported',
                'reason': 'test',
                'path': 'nativeDv',
              },
            ],
          },
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dovi-facts-routing-');
    app_paths.appSupportDirPath = directory.path;
    app_paths.tmpDirPath = directory.path;
    await GStorage.init();
    messenger
      ..setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
          WakelockPlusApi.pigeonChannelCodec,
        ),
        (message) async => <Object?>[null],
      )
      ..setMockMethodCallHandler(const MethodChannel('window_manager'), (
        call,
      ) async {
        if (call.method == 'isFullScreen') return false;
        return null;
      });
  });

  tearDownAll(() async {
    await GStorage.close();
    await directory.delete(recursive: true);
  });

  Future<_Harness> openHarness({int cid = 452419749}) async {
    final owner = PlPlayerController.getInstance(
      lifecyclePorts: PlayerLifecyclePorts(
        androidSessionOverride: true,
        createPlayer: (_) async =>
            throw StateError('routing must not create Player'),
        probeHdr: () async =>
            const app_hdr.HdrCapabilities(unsupportedReason: 'unused'),
        createOutput: (_, _) async =>
            throw StateError('routing must not create output'),
        displayChanges: () => const Stream<void>.empty(),
        disposeOutput: (_) async {},
        disposePlayer: (_) async {},
      ),
    );
    // cid is late final: one explicit initialization per page.
    final page = VideoDetailController()
      ..cid = RxInt(cid)
      ..isFileSource = false;
    return _Harness(owner, page);
  }

  void installBackend(_Harness harness, _RouteBackend backend) {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => backend.handle(call),
    );
  }

  Future<void> closeHarness(_Harness harness) async {
    messenger.setMockMethodCallHandler(channel, null);
    harness.page.releaseRoutingForTesting();
    expect(harness.owner.onRouteOptionsInvalidated, isNull);
    expect(harness.owner.onRouteOptionsChanged, isNull);
    harness.owner.dispose();
    await harness.owner.teardownDrain;
    expect(PlPlayerController.instance, isNull);
  }

  test('production chain: sniffed P8.4 admits the 126 tier with a DV P8.4 prediction', () async {
    final harness = await openHarness();
    final item = dv126();
    harness.page
      ..firstVideo = item
      ..setDoviSniffForTesting((item) async => kP8Compat4);
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      expect(
        await harness.page.probeRoutingForTesting(
          playUrlOf([sdr1080(), item]),
          1,
        ),
        isTrue,
      );
      final selection = harness.page.routingSelectionForTesting!;
      // DV003 acceptance: the tier is no longer gray.
      expect(selection.allows(item), isTrue);
      final prediction = selection.prediction(item)!;
      expect(prediction.playable, isTrue);
      expect(prediction.source.dvProfile, 8);
      expect(prediction.source.dvCompatibilityId, 4);
      expect(
        prediction.presentation,
        anyOf(HdrPresentation.nativeDolbyVision, HdrPresentation.nativeHdr),
      );
    } finally {
      await closeHarness(harness);
    }
  });

  test(
    'same revision reuses the cache: second probe issues no second sniff',
    () async {
      final harness = await openHarness();
      final item = dv126();
      var sniffCalls = 0;
      harness.page
        ..firstVideo = item
        ..setDoviSniffForTesting((item) async {
          sniffCalls++;
          return kP8Compat4;
        });
      installBackend(harness, _RouteBackend(['1:0']));
      try {
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        expect(sniffCalls, 1);
        expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test('same spec key, different baseUrl: A success cannot admit B', () async {
    final harness = await openHarness();
    final itemA = dv126(baseUrl: 'https://cdn.example/dv-nodeA.m4s');
    final itemB = dv126(baseUrl: 'https://cdn.example/dv-nodeB.m4s');
    // Identical codec/geometry means identical VideoSourceSpec.key — the
    // collision that made the spec-key map unsafe.
    expect(
      DashRouteSelection.specification(itemA)!.key,
      DashRouteSelection.specification(itemB)!.key,
    );
    var sniffCalls = 0;
    harness.page.setDoviSniffForTesting((item) async {
      sniffCalls++;
      return identical(item, itemA) ? kP8Compat4 : null;
    });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([itemA, itemB]), 1),
        isTrue,
      );
      final selection = harness.page.routingSelectionForTesting!;
      expect(selection.allows(itemA), isTrue);
      expect(selection.allows(itemB), isFalse);
      expect(sniffCalls, 2);
    } finally {
      await closeHarness(harness);
    }
  });

  test('new revision, same URL and spec: old facts are not reused', () async {
    final harness = await openHarness();
    final item = dv126();
    var sniffCalls = 0;
    harness.page
      ..firstVideo = item
      ..setDoviSniffForTesting((item) async {
        sniffCalls++;
        return sniffCalls == 1 ? kP8Compat4 : null;
      });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
      expect(harness.page.initialDoviFactsForTesting!.compatibilityId, 4);
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 2),
        isTrue,
      );
      expect(sniffCalls, 2);
      expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
      expect(harness.page.initialDoviFactsForTesting, isNull);
    } finally {
      await closeHarness(harness);
    }
  });

  test(
    'cid change on one controller, same URL/spec/revision: re-sniff, no inheritance, no late cross-cid write',
    () async {
      final harness = await openHarness(cid: 111);
      final item = dv126();
      harness.page.firstVideo = item;
      final gateOldCid = Completer<DoviFacts?>();
      var sniffCalls = 0;
      harness.page.setDoviSniffForTesting((item) {
        sniffCalls++;
        return sniffCalls == 1
            ? gateOldCid.future
            : Future<DoviFacts?>.value(null);
      });
      installBackend(harness, _RouteBackend(['1:0']));
      try {
        // cid 111: the sniff is gated, so this rendition's facts stay in
        // flight.
        final pendingOldCid = harness.page.probeRoutingForTesting(
          playUrlOf([item]),
          1,
        );
        // Same controller, same URL/spec/revision, only cid.value moves —
        // the RxInt the key derivation reads is the existing P-switch path.
        harness.page.cid.value = 222;
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        expect(sniffCalls, 2);
        expect(harness.page.initialDoviFactsForTesting, isNull);
        final selectionNewCid = harness.page.routingSelectionForTesting!;
        expect(selectionNewCid.allows(item), isFalse);
        // Release the stale cid-111 sniff after the cid-222 rendition
        // published: its late result must not authorize the new rendition.
        gateOldCid.complete(kP8Compat4);
        expect(await pendingOldCid, isFalse);
        expect(harness.page.routingSelectionForTesting, same(selectionNewCid));
        expect(selectionNewCid.allows(item), isFalse);
        expect(harness.page.initialDoviFactsForTesting, isNull);
        // The cid-222 cache entry is still empty: a fresh probe has to sniff
        // again instead of hitting the late cid-111 result.
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        expect(sniffCalls, 3);
        expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test('late revision-A result after revision-B completed: no cache write, selection unchanged', () async {
    final harness = await openHarness();
    final item = dv126();
    harness.page.firstVideo = item;
    final gateA = Completer<DoviFacts?>();
    var sniffCalls = 0;
    harness.page.setDoviSniffForTesting((item) {
      sniffCalls++;
      return sniffCalls == 1 ? gateA.future : Future<DoviFacts?>.value(null);
    });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      final pendingA = harness.page.probeRoutingForTesting(
        playUrlOf([item]),
        1,
      );
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 2),
        isTrue,
      );
      final selectionB = harness.page.routingSelectionForTesting!;
      expect(selectionB.allows(item), isFalse);
      // Release the stale revision-A sniff after B already published.
      gateA.complete(kP8Compat4);
      expect(await pendingA, isFalse);
      expect(harness.page.routingSelectionForTesting, same(selectionB));
      expect(selectionB.allows(item), isFalse);
      // A late revision-A result never reached the revision-1 cache entry:
      // a fresh revision-1 probe has to sniff again.
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      expect(sniffCalls, 3);
      expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
      expect(harness.page.initialDoviFactsForTesting, isNull);
    } finally {
      await closeHarness(harness);
    }
  });

  test(
    'same-key concurrency: two probes, one sniff, latest serial publishes',
    () async {
      final harness = await openHarness();
      final item = dv126();
      harness.page.firstVideo = item;
      final gate = Completer<DoviFacts?>();
      var sniffCalls = 0;
      harness.page.setDoviSniffForTesting((item) {
        sniffCalls++;
        return gate.future;
      });
      installBackend(harness, _RouteBackend(['1:0']));
      try {
        final first = harness.page.probeRoutingForTesting(playUrlOf([item]), 1);
        final second = harness.page.probeRoutingForTesting(
          playUrlOf([item]),
          1,
        );
        gate.complete(kP8Compat4);
        expect(await first, isFalse);
        expect(await second, isTrue);
        expect(sniffCalls, 1);
        expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
        expect(harness.page.initialDoviFactsForTesting!.compatibilityId, 4);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test('stalled sniff: bounded wait ends the waiter, no facts, no permanent in-flight, no late backfill', () async {
    final harness = await openHarness();
    final item = dv126();
    harness.page.firstVideo = item;
    // Non-nullable element type on purpose: the sniff future reifies to
    // Future<DoviFacts>, exercising the bounded wait's type normalization.
    final stalled = Completer<DoviFacts>();
    var sniffCalls = 0;
    harness.page.setDoviSniffForTesting((item) {
      sniffCalls++;
      return sniffCalls == 1 ? stalled.future : Future<DoviFacts?>.value(null);
    });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      // The probe ends through the production bounded wait (sniff budget),
      // not through the gate.
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
      // A late success after the timeout must not backfill the cache.
      stalled.complete(kP8Compat4);
      await Future<void>.delayed(Duration.zero);
      expect(harness.page.initialDoviFactsForTesting, isNull);
      // The in-flight entry was cleaned: this probe issues a fresh sniff
      // instead of waiting on a leaked task.
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      expect(sniffCalls, 2);
      expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
    } finally {
      await closeHarness(harness);
    }
  });

  test('selection snapshot is stable while the active cache changes', () async {
    final harness = await openHarness();
    final item = dv126();
    var sniffCalls = 0;
    harness.page
      ..firstVideo = item
      ..setDoviSniffForTesting((item) async {
        sniffCalls++;
        return sniffCalls == 1 ? null : kP8Compat4;
      });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      final failedSelection = harness.page.routingSelectionForTesting!;
      expect(failedSelection.allows(item), isFalse);
      // Same revision again: the fresh sniff succeeds and the active cache
      // gains the rendition's facts.
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      expect(sniffCalls, 2);
      expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
      expect(harness.page.initialDoviFactsForTesting, isNotNull);
      // The earlier selection keeps judging from its frozen snapshot.
      expect(failedSelection.allows(item), isFalse);
    } finally {
      await closeHarness(harness);
    }
  });

  test('fail-closed: unknown profile, keyless compat, null, throwing sniff stay gray', () async {
    final harness = await openHarness();
    final item = dv126();
    harness.page.firstVideo = item;
    Future<DoviFacts?> Function(VideoItem) sniff = (item) async => null;
    harness.page.setDoviSniffForTesting((item) => sniff(item));
    installBackend(harness, _RouteBackend(['1:0']));
    final cases = <String, DoviFacts?>{
      'unknown profile': const DoviFacts(
        profile: 9,
        level: 1,
        rpuPresent: true,
        elPresent: false,
        blPresent: true,
        compatibilityId: 0,
        mdCompression: 0,
      ),
      'profile 8 without a compatibility id': const DoviFacts(
        profile: 8,
        level: 7,
        rpuPresent: true,
        elPresent: false,
        blPresent: true,
        compatibilityId: 0,
        mdCompression: 0,
      ),
      'no facts': null,
    };
    try {
      var revision = 0;
      for (final entry in cases.entries) {
        revision++;
        sniff = (item) async => entry.value;
        expect(
          await harness.page.probeRoutingForTesting(
            playUrlOf([item]),
            revision,
          ),
          isTrue,
          reason: entry.key,
        );
        expect(
          harness.page.routingSelectionForTesting!.allows(item),
          isFalse,
          reason: entry.key,
        );
      }
      revision++;
      var transportCalls = 0;
      sniff = (item) {
        transportCalls++;
        throw Exception('sniff transport failure');
      };
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), revision),
        isTrue,
        reason: 'throwing sniff',
      );
      expect(
        harness.page.routingSelectionForTesting!.allows(item),
        isFalse,
        reason: 'throwing sniff',
      );
      // The exception path released its in-flight slot: a succeeding retry
      // under the same revision issues a fresh sniff and is admitted.
      sniff = (item) async {
        transportCalls++;
        return kP8Compat4;
      };
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), revision),
        isTrue,
        reason: 'retry after throwing sniff',
      );
      expect(transportCalls, 2, reason: 'retry after throwing sniff');
      expect(
        harness.page.routingSelectionForTesting!.allows(item),
        isTrue,
        reason: 'retry after throwing sniff',
      );
    } finally {
      await closeHarness(harness);
    }
  });

  test(
    'dvh1.07: native DV structural admission refuses P7 and the base-layer route fails on decode, so this mock stays closed',
    () async {
      final harness = await openHarness();
      final p7 = dv126(codec: 'dvh1.07.09');
      harness.page.setDoviSniffForTesting((item) async => kP8Compat4);
      // P7 itself keeps a structurally applicable PQ base-layer route; the
      // native DV candidate is refused structurally (only qualified P5/P8.4
      // sources are admitted), not by a maturity gate. This mock reports no
      // usable codec-path decoder, so the base-layer route is unavailable
      // too and every route is infeasible — a capability verdict for this
      // mock, not an unconditional P7 verdict.
      installBackend(
        harness,
        _RouteBackend(['1:0'], codecSupport: 'unsupported'),
      );
      try {
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([p7]), 1),
          isTrue,
        );
        final selection = harness.page.routingSelectionForTesting!;
        final prediction = selection.prediction(p7)!;
        final nativeCandidate = prediction.candidates.first;
        expect(nativeCandidate.strategy, HdrStrategy.nativeDolbyVision);
        expect(
          nativeCandidate.skipReason,
          HdrDegradeReason.unsupportedStrategy,
        );
        expect(nativeCandidate.feasible, isFalse);
        final baseLayerCandidate = prediction.candidates.firstWhere(
          (c) => c.strategy == HdrStrategy.baseLayerDirect,
        );
        expect(
          baseLayerCandidate.skipReason,
          HdrDegradeReason.sourceDecodeUnsupported,
        );
        expect(prediction.playable, isFalse);
        expect(selection.allows(p7), isFalse);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test(
    'capability failure keeps the HDR tier unadmitted even with valid facts',
    () async {
      final harness = await openHarness();
      final item = dv126();
      harness.page.firstVideo = item;
      harness.page.setDoviSniffForTesting((item) async => kP8Compat4);
      installBackend(harness, _RouteBackend(['1:0', null]));
      try {
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        expect(harness.page.routingSelectionForTesting!.allows(item), isTrue);
        // Capability query fails for the new revision: unknown branch wins
        // even though this revision's facts were just sniffed successfully.
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf([item]), 2),
          isTrue,
        );
        expect(harness.page.routingSelectionForTesting!.allows(item), isFalse);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test(
    'batch display-revision mismatch keeps the HDR tier unadmitted',
    () async {
      final harness = await openHarness();
      // 130 distinct specs force two bounded batches.
      final tracks = [
        for (var i = 0; i < 129; i++) sdr1080(bandWidth: 1000000 + i),
        dv126(),
      ];
      harness.page.setDoviSniffForTesting((item) async => kP8Compat4);
      installBackend(harness, _RouteBackend(['r1', 'r2']));
      try {
        expect(
          await harness.page.probeRoutingForTesting(playUrlOf(tracks), 1),
          isTrue,
        );
        final selection = harness.page.routingSelectionForTesting!;
        expect(selection.displayHdr, isNull);
        expect(selection.allows(tracks.last), isFalse);
      } finally {
        await closeHarness(harness);
      }
    },
  );

  test('DV005 hint: current rendition facts are readable, a new revision does not inherit them', () async {
    final harness = await openHarness();
    final item = dv126();
    var sniffCalls = 0;
    harness.page
      ..firstVideo = item
      ..setDoviSniffForTesting((item) async {
        sniffCalls++;
        return sniffCalls == 1 ? kP8Compat4 : null;
      });
    installBackend(harness, _RouteBackend(['1:0']));
    try {
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      final hint = harness.page.initialDoviFactsForTesting;
      expect(hint, isNotNull);
      expect(hint!.profile, 8);
      expect(hint.compatibilityId, 4);
      expect(
        await harness.page.probeRoutingForTesting(playUrlOf([item]), 2),
        isTrue,
      );
      expect(harness.page.initialDoviFactsForTesting, isNull);
    } finally {
      await closeHarness(harness);
    }
  });
}
