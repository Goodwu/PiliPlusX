import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final spec = VideoSourceSpec(codec: 'hevc', width: 1920, height: 1080);
  const sources = {
    'HLG': HdrSourceDescriptor(codec: 'hevc', transfer: 'hlg'),
    'P8.4': HdrSourceDescriptor(
      codec: 'hevc', transfer: 'hlg',
      dynamicMetadata: HdrDynamicMetadata.dolbyVision,
      dvProfile: 8, dvCompatibilityId: 4, enhancementLayer: false,
    ),
    'Vivid HLG': HdrSourceDescriptor(
      codec: 'hevc', transfer: 'hlg',
      dynamicMetadata: HdrDynamicMetadata.hdrVivid,
    ),
  };

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async => {
      'schema': 1,
      'platform': 'android',
      'display': {
        'status': 'resolved', 'platform': 'android',
        'revision': 'no-pq-carrier', 'hdrTypes': [2],
      },
      'hdr': {
        'sdkInt': 28, 'p5Pipeline': true, 'dataSpaceBridgeLoaded': true,
        'dataSpaceExt': {
          'id': 'fixture-no-pq-carrier', 'isApplicable': true,
          'pqPresentation': {'rgbSurface': false, 'yuvWindow': false},
        },
      },
      'sources': [{
        'key': spec.key, 'censusComplete': true, 'reason': 'fixture',
        'decoders': [{
          'name': 'fixture.hevc', 'mime': 'video/hevc', 'kind': 'hardware',
          'support': 'supported', 'reason': 'fixture', 'path': 'codec',
        }],
      }],
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<HdrRoutePrediction> predict(HdrSourceDescriptor source, {
    EffectiveVideoRouteOptions? options,
  }) async {
    final caps = await HdrOutputSelector.queryCapabilities(
      target: const VideoOutputTarget.applicationView(), sources: [spec],
    );
    expect(caps, isNotNull);
    return HdrOutputSelector.predict(descriptor: source, specification: spec,
        capabilities: caps, options: options)!;
  }

  for (final entry in sources.entries) {
    test('${entry.key} cannot invent a C4 RGB carrier or implicit SDR', () async {
      final value = await predict(entry.value);
      expect(value.playable, isFalse);
      expect(HdrOutputSelector.isHdrPresentable(value), isFalse);
      expect(value.candidates.where((candidate) =>
          candidate.stage == HdrRouteStage.c4).any((candidate) =>
          candidate.skipReason == HdrDegradeReason.pqRgbPresentationUnavailable), isTrue);
      expect(value.candidates.any((candidate) => candidate.feasible), isFalse);
    });
  }

  test('Explicit HDR off still permits its independent SDR route', () async {
    final value = await predict(sources['HLG']!, options:
        EffectiveVideoRouteOptions.resolve(application: const VideoRouteOptions(
          output: VideoRouteSelection.require(VideoOutputIntent.sdr),
        )));
    expect(value.playable, isTrue);
    expect(value.selected.route!.outputTransfer, HdrOutputTransfer.sdr);
  });
}
