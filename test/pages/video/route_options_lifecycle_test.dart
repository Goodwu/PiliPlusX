import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/pages/video/controller.dart';
import 'package:piliplus/plugin/pl_player/controller.dart';
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' as app_hdr;
import 'package:piliplus/plugin/pl_player/models/player_lifecycle_ports.dart';
import 'package:piliplus/utils/path_utils.dart' as app_paths;
import 'package:piliplus/utils/storage.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('app-config-query-');
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

  test('late query A cannot replace selected source B after configuration revision changes', () async {
    final owner = PlPlayerController.getInstance(
      lifecyclePorts: PlayerLifecyclePorts(
        androidSessionOverride: true,
        createPlayer: (_) async =>
            throw StateError('query must not create Player'),
        probeHdr: () async =>
            const app_hdr.HdrCapabilities(unsupportedReason: 'unused'),
        createOutput: (_, _) async =>
            throw StateError('query must not create output'),
        displayChanges: () => const Stream<void>.empty(),
        disposeOutput: (_) async {},
        disposePlayer: (_) async {},
      ),
    );
    final page = VideoDetailController();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<Map<String, Object?>>();
    Map<String, Object?>? firstResult;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'VideoRouteCapabilities.Get') return null;
      final args = call.arguments as Map;
      final result = <String, Object?>{
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
          for (final Map spec in args['sources'] as List)
            {
              'key': spec['key'],
              'censusComplete': true,
              'reason': 'test',
              'decoders': [
                {
                  'name': 'vendor.avc',
                  'mime': 'video/avc',
                  'kind': 'hardware',
                  'support': 'supported',
                  'reason': 'test',
                  'path': 'codec',
                },
              ],
            },
        ],
      };
      if (++calls == 1) {
        firstResult = result;
        firstStarted.complete();
        return releaseFirst.future;
      }
      return result;
    });
    final source = PlayUrlModel(
      dash: Dash(
        video: [
          VideoItem(
            id: 80,
            quality: VideoQuality.high1080,
            codecs: 'avc1.640028',
            width: 1920,
            height: 1080,
          ),
        ],
      ),
    );
    final a = EffectiveVideoRouteOptions.resolve();
    final b = EffectiveVideoRouteOptions.resolve(
      application: const VideoRouteOptions(
        output: VideoRouteSelection.require(VideoOutputIntent.sdr),
      ),
    );
    try {
      page.invalidateRouteOptionsForTesting(a);
      final pendingA = page.probeRoutingForTesting(source, 1);
      await firstStarted.future;
      page.invalidateRouteOptionsForTesting(b);
      expect(await page.probeRoutingForTesting(source, 2), true);
      final selectionB = page.routingSelectionForTesting!;
      expect(selectionB.options, same(b));
      releaseFirst.complete(firstResult!);
      expect(await pendingA, false);
      expect(page.routingSelectionForTesting, same(selectionB));
      final selectedSource = NetworkSource(
        videoSource: 'https://example.invalid/b.mp4',
        audioSource: null,
        routeOptions: page.routingSelectionForTesting!.options,
      );
      expect(selectedSource.routeOptions, same(b));
      expect(selectedSource.routeOptions, isNot(same(a)));
    } finally {
      if (!releaseFirst.isCompleted && firstResult != null) {
        releaseFirst.complete(firstResult!);
      }
      page.releaseRoutingForTesting();
      expect(owner.onRouteOptionsInvalidated, isNull);
      expect(owner.onRouteOptionsChanged, isNull);
      owner.dispose();
      await owner.teardownDrain;
    }
    expect(PlPlayerController.instance, isNull);
  });
}
