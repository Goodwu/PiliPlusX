import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' show HdrMode;
import 'package:piliplus/plugin/pl_player/route_options.dart';
import 'package:piliplus/plugin/pl_player/source_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  const target = VideoOutputTarget.applicationView();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final options = AppVideoRouteRequest.fromPreferences(
    hdrMode: HdrMode.auto,
    enableHA: true,
    hardwareDecoding: 'mediacodec',
    android: true,
  ).resolve();
  final item = VideoItem(
    id: 126,
    quality: VideoQuality.fromCode(126),
    codecs: 'dvhe.08.07',
    width: 3840,
    height: 2160,
    frameRate: '30',
    bandWidth: 15000000,
  );
  final specification = DashRouteSelection.specification(item)!;

  void install({
    required String extensionId,
    required bool rgb,
    required bool yuv,
    String support = 'supported',
    bool includeChannels = true,
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'VideoRouteCapabilities.Get');
      final request = call.arguments as Map;
      expect(request['target'], target.toMap());
      expect(request.containsKey('player'), isFalse);
      return {
        'schema': 1,
        'platform': 'android',
        'display': {
          'status': 'resolved',
          'platform': 'android',
          'displayId': 7,
          'modeId': 2,
          'revision': 'pq-channel-fixture',
          'hdrTypes': [2],
        },
        'hdr': {
          'sdkInt': 24,
          'p5Pipeline': true,
          'dataSpaceBridgeLoaded': true,
          'dataSpaceExt': {
            'id': extensionId,
            'isApplicable': true,
            if (includeChannels)
              'pqPresentation': {'rgbSurface': rgb, 'yuvWindow': yuv},
          },
          'hevcDecoders': <Object>[],
          'dolbyVisionDecoders': <Object>[],
        },
        'sources': [
          for (final Map spec in request['sources'] as List)
            {
              'key': spec['key'],
              'censusComplete': true,
              'reason': 'exact source fixture',
              'decoders': [
                {
                  'name': 'fixture.hevc',
                  'mime': 'video/hevc',
                  'kind': 'hardware',
                  'support': support,
                  'reason': 'decoder fixture',
                  'path': 'codec',
                },
              ],
            },
        ],
      };
    });
  }

  Future<DashRouteSelection> select() => DashRouteSelection.query(
    tracks: [item],
    target: target,
    options: options,
    allowUnknown: false,
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('PQ channel declaration survives query and exact-source binding', () async {
    install(extensionId: 'lg-pq', rgb: false, yuv: true);
    final caps = await HdrOutputSelector.queryCapabilities(
      target: target,
      sources: [specification],
    );
    expect(caps, isNotNull);
    expect(caps!.hdr.pqPresentation.rgbSurface, isFalse);
    expect(caps.hdr.pqPresentation.yuvWindow, isTrue);
    final bound = caps.forHdrSource(specification);
    expect(bound.dataSpaceExt, same(caps.hdr.dataSpaceExt));
    expect(bound.sourceSupport!.source, specification);
    expect(bound.pqPresentation.yuvWindow, isTrue);
  });

  for (final extensionId in ['lg-pq', 'fixture-yuv-adapter']) {
    test('YUV declaration selects C4 without App device routing: $extensionId', () async {
      install(extensionId: extensionId, rgb: false, yuv: true);
      final selection = await select();
      final prediction = selection.prediction(item)!;
      expect(selection.options, same(options));
      expect(options.importPreference, VideoImportPreference.preferDirect);
      expect(selection.allows(item), isTrue);
      expect(prediction.selected.stage, HdrRouteStage.c4);
      expect(prediction.selected.route!.strategy, HdrStrategy.baseLayerConvert);
      expect(prediction.selected.route!.hwdec, 'surfacetexture');
      expect(prediction.selected.route!.outputTransfer, HdrOutputTransfer.pq);
      expect(prediction.selected.route!.offscreenTransfer, isNotNull);
      expect(prediction.candidates.any((candidate) =>
          candidate.stage == HdrRouteStage.c2 &&
          candidate.skipReason == HdrDegradeReason.pqRgbPresentationUnavailable), isTrue);
      final source = NetworkSource(
        videoSource: 'https://example.invalid/p84.mp4',
        audioSource: null,
        videoSpec: specification,
        routeOptions: selection.options,
      );
      expect(source.routeOptions, same(options));
      expect(source.videoSpec, specification);
      // This is prediction, not an actual output or production owner grant.
      expect(HdrOutputSelector.routeLabel(HdrOutputReport(
        source: prediction.source,
        prediction: prediction,
      )), isNull);
    });
  }

  test('RGB declaration keeps the existing Dolby Vision C2 route', () async {
    install(extensionId: 'lya-pq', rgb: true, yuv: false);
    final prediction = (await select()).prediction(item)!;
    expect(prediction.playable, isTrue);
    expect(prediction.selected.stage, HdrRouteStage.c2);
    expect(prediction.selected.route!.strategy, HdrStrategy.metadataReshape);
    expect(prediction.selected.route!.hwdec, 'mediacodec');
    expect(prediction.selected.route!.offscreenTransfer, isNull);
  });

  test('Legacy applicable adapter preserves RGB migration semantics', () async {
    install(extensionId: 'legacy-adapter', rgb: false, yuv: false,
        includeChannels: false);
    final prediction = (await select()).prediction(item)!;
    expect(prediction.selected.strategy, HdrStrategy.metadataReshape);
    expect(prediction.selected.stage, HdrRouteStage.c2);
  });

  test('Vivid HLG query predicts static C4 without claiming dynamic output', () async {
    install(extensionId: 'lg-pq', rgb: false, yuv: true);
    final caps = await HdrOutputSelector.queryCapabilities(
      target: target,
      sources: [specification],
    );
    const source = HdrSourceDescriptor(
      codec: 'hevc',
      transfer: 'hlg',
      primaries: 'bt.2020',
      dynamicMetadata: HdrDynamicMetadata.hdrVivid,
    );
    final prediction = HdrOutputSelector.predict(
      descriptor: source,
      specification: specification,
      capabilities: caps,
      options: options,
    )!;
    expect(prediction.playable, isTrue);
    expect(prediction.selected.stage, HdrRouteStage.c4);
    final actual = prediction.selected.route!;
    expect(actual.hwdec, 'surfacetexture');
    expect(actual.metadataHandling, HdrMetadataHandling.baselineOnly);
    expect(actual.appliesDynamicMetadata, isFalse);
    final report = HdrOutputReport(source: source,
        prediction: prediction, actual: actual, verified: false);
    expect(HdrOutputSelector.routeLabel(report),
        'HDR Vivid · HLG→PQ 静态兼容转换');
    expect(HdrOutputSelector.candidateFailureSummary(report),
        contains('c1:nativeHdrVivid:routeNotImplemented'));
    expect(HdrOutputSelector.candidateFailureSummary(report),
        contains('c2:metadataReshape:routeNotImplemented'));
    // A DASH tier by itself still cannot invent this fixture's HLG transfer.
    expect(HdrOutputSelector.descriptorFromDash(quality: 129)?.transfer, isNull);
  });

  test('YUV declaration cannot authorize an unsupported encoded source', () async {
    install(extensionId: 'lg-pq', rgb: false, yuv: true,
        support: 'unsupported');
    final selection = await select();
    expect(selection.allows(item), isFalse);
    expect(selection.prediction(item)!.playable, isFalse);
    expect(selection.prediction(item)!.selected.route, isNull);
  });

  test('Missing production owner stays an explicit error without success label', () {
    const report = HdrOutputReport(
      degradeReason: HdrDegradeReason.yuvWindowArmUnavailable,
    );
    expect(HdrOutputSelector.routeLabel(report), isNull);
    expect(HdrOutputSelector.blockedNotice(const HdrErrorEvent(
      1, reason: HdrDegradeReason.yuvWindowArmUnavailable,
    )), 'HDR 路由失败（yuvWindowArmUnavailable）');
  });
}
