import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/hdr_output.dart';
import 'package:PiliPlus/plugin/pl_player/source_selection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  VideoItem track(String? codec, {int quality = 126}) => VideoItem(
    id: quality,
    quality: VideoQuality.fromCode(quality),
    codecs: codec,
    width: 1920,
    height: 1080,
    frameRate: '30',
    bandWidth: 5000000,
  );

  for (final codec in <String?>[null, '', 'dolby', 'dvh1', 'dvhe.bad.06', 'dvhe.99.06']) {
    test('DV tier preserves unresolved source facts for $codec', () {
      final source = HdrOutputSelector.descriptorFromDash(quality: 126, codec: codec)!;
      expect(source.dynamicMetadata, HdrDynamicMetadata.dolbyVision);
      expect(source.hasUnresolvedDolbyVision, isTrue);
      expect(source.dvCompatibilityId, isNull);
      expect(source.enhancementLayer, isNull);
      expect(HdrSourceClass.of(source), HdrSourceClass.dvUnknown);
      for (final allowUnknown in <bool>[true, false]) {
        final selection = DashRouteSelection.unknown(allowUnknown: allowUnknown);
        expect(selection.allows(track(codec)), isFalse);
      }
    });
  }

  test('another declared DV profile is not relabeled as P8.4', () {
    final source = HdrOutputSelector.descriptorFromDash(codec: 'dvhe.07.06')!;
    expect(source.dvProfile, 7);
    expect(source.dvCompatibilityId, isNull);
    expect(source.enhancementLayer, isNull);
    expect(source.transfer, isNull);
  });

  test('recognized P5 and the existing provider P8 hint retain their meaning', () {
    final p5 = HdrOutputSelector.descriptorFromDash(codec: ' DVHE.05.06 ')!;
    final p8 = HdrOutputSelector.descriptorFromDash(codec: 'dvh1.08.06')!;
    expect(HdrSourceClass.of(p5), HdrSourceClass.dvP5);
    expect(HdrSourceClass.of(p8), HdrSourceClass.dvP84);
    expect(p5.dvCompatibilityId, 0);
    expect(p8.dvCompatibilityId, 4);
  });

  test('unknown-support preference cannot bypass unresolved color facts', () {
    const selection = DashRouteSelection.unknown(allowUnknown: true);
    expect(selection.allows(track('dvhe.99.06', quality: 80)), isFalse);
    expect(selection.allows(track('hvc1.2.4.L153.B0', quality: 80)), isTrue);
  });

  test('all decoder/display declarations cannot authorize unresolved DV', () async {
    final item = track('dvhe.99.06');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      return {
        'schema': 1,
        'platform': 'android',
        'display': {
          'status': 'resolved',
          'platform': 'android',
          'displayId': 7,
          'modeId': 2,
          'revision': '7:2',
          'hdrTypes': [1, 2, 3],
        },
        'hdr': {
          'sdkInt': 35,
          'p5Pipeline': true,
          'dataSpaceBridgeLoaded': true,
          'nativeDvBridgeApi': 1,
          'hevcDecoders': [],
          'dolbyVisionDecoders': [
            {'name': 'vendor.dv', 'mimeType': 'video/dolby-vision',
             'hardwareAcceleration': true, 'profiles': [32, 256]},
          ],
        },
        'sources': [
          for (final Map spec in args['sources'] as List)
            {
              'key': spec['key'],
              'censusComplete': true,
              'reason': 'test',
              'decoders': [
                for (final path in ['codec', 'nativeDv'])
                  {'name': 'vendor.codec', 'mime': 'video/hevc',
                   'kind': 'hardware', 'support': 'supported',
                   'reason': 'test', 'path': path},
              ],
            },
        ],
      };
    });
    final selection = await DashRouteSelection.query(
      tracks: [item],
      target: const VideoOutputTarget.applicationView(),
    );
    expect(selection.prediction(item)!.selected.skipReason,
        HdrDegradeReason.sourceMetadataUnknown);
    expect(selection.prediction(item)!.selected.route, isNull);
    expect(selection.filter([item]), isEmpty);
    expect(HdrOutputSelector.isHdrPresentable(selection.prediction(item)), isFalse);
  });
}
