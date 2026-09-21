import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/video/video_quality_eligibility.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

VideoItem track({
  required String codec,
  required int width,
  required int height,
  int quality = 127,
}) => VideoItem(
  id: quality,
  codecs: codec,
  width: width,
  height: height,
  quality: VideoQuality.fromCode(quality),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('video quality eligibility', () {
    test(
      'a same-qn part replacement drops old tracks and exposes new ones',
      () {
        final formats = [
          FormatItem(quality: 127, newDesc: '8K'),
          FormatItem(quality: 126, newDesc: '杜比视界'),
          FormatItem(quality: 120, newDesc: '4K'),
        ];
        final p1 = formatsForCurrentDash(
          formats: formats,
          tracks: [
            track(codec: 'av01.0.17M.08', width: 7680, height: 4320),
            track(quality: 120, codec: 'avc1', width: 3840, height: 2160),
          ],
        );
        final p2 = formatsForCurrentDash(
          formats: formats,
          tracks: [
            track(quality: 126, codec: 'hev1', width: 3840, height: 2160),
            track(quality: 120, codec: 'avc1', width: 3840, height: 2160),
          ],
        );

        expect(p1.map((format) => format.quality), [127, 120]);
        expect(p2.map((format) => format.quality), [126, 120]);
      },
    );

    test('8K fails closed while its codec probe is pending', () {
      final item = track(codec: 'av01.0.17M.08', width: 7680, height: 4320);

      final result = videoQualityEligibility(
        quality: 127,
        tracks: [item],
        displaySupportsHdr: true,
        gateEightKWithHardware: true,
        decodeCapabilities: const {},
      );

      expect(result.reason, VideoQualityIneligibility.eightKProbePending);
    });

    test('a failed 8K probe gives an explicit fail-closed reason', () {
      final item = track(codec: 'av01.0.17M.08', width: 7680, height: 4320);
      final failed = VideoDecodeCapability.fromTrack(item).copyWith(
        reason: 'probe-failed:PlatformException',
      );

      final result = videoQualityEligibility(
        quality: 127,
        tracks: [item],
        displaySupportsHdr: true,
        gateEightKWithHardware: true,
        decodeCapabilities: {failed.key: failed},
      );

      expect(result.reason, VideoQualityIneligibility.eightKProbeFailed);
      expect(result.message, '无法确认当前设备的 8K 解码能力');
    });

    test('native decode result preserves codec and dimensions', () async {
      const channel = MethodChannel('piliplusx/hdr_capabilities');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // ignore: cascade_invocations
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'probeVideoDecode');
        expect(call.arguments, {
          'codec': 'hev1.2.4.L183.B0',
          'width': 7680,
          'height': 4320,
        });
        return {'supported': true, 'reason': 'hardware-decode-supported'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final result = await probeMacosVideoDecode(
        const VideoDecodeCapability(
          codec: 'hev1.2.4.L183.B0',
          width: 7680,
          height: 4320,
          hardwareSupported: null,
        ),
      );

      expect(result.hardwareSupported, isTrue);
      expect(result.reason, 'hardware-decode-supported');
      expect(result.key, 'hev1.2.4.L183.B0/7680/4320');
    });

    test('unsupported AV1 8K does not disable 4K software decoding', () {
      final eightK = track(
        codec: 'av01.0.17M.08',
        width: 7680,
        height: 4320,
      );
      final capability = VideoDecodeCapability.fromTrack(eightK).copyWith(
        hardwareSupported: false,
        reason: 'hardware-decode-unavailable',
      );

      expect(
        videoQualityEligibility(
          quality: 127,
          tracks: [eightK],
          displaySupportsHdr: true,
          gateEightKWithHardware: true,
          decodeCapabilities: {capability.key: capability},
        ).reason,
        VideoQualityIneligibility.eightKHardwareUnsupported,
      );
      expect(
        videoQualityEligibility(
          quality: 120,
          tracks: [
            track(
              quality: 120,
              codec: 'av01.0.08M.08',
              width: 3840,
              height: 2160,
            ),
          ],
          displaySupportsHdr: true,
          gateEightKWithHardware: true,
          decodeCapabilities: const {},
        ).enabled,
        isTrue,
      );
    });

    test('one hardware-decodable 8K codec enables the quality', () {
      final av1 = track(codec: 'av01.0.17M.08', width: 7680, height: 4320);
      final hevc = track(codec: 'hev1.2.4.L183.B0', width: 7680, height: 4320);
      final av1Capability = VideoDecodeCapability.fromTrack(av1).copyWith(
        hardwareSupported: false,
      );
      final hevcCapability = VideoDecodeCapability.fromTrack(hevc).copyWith(
        hardwareSupported: true,
      );

      expect(
        videoQualityEligibility(
          quality: 127,
          tracks: [av1, hevc],
          displaySupportsHdr: true,
          gateEightKWithHardware: true,
          decodeCapabilities: {
            av1Capability.key: av1Capability,
            hevcCapability.key: hevcCapability,
          },
        ).enabled,
        isTrue,
      );
    });

    test('8K playback selection retains only the confirmed codec track', () {
      final av1 = track(codec: 'av01.0.17M.08', width: 7680, height: 4320);
      final hevc = track(codec: 'hev1.2.4.L183.B0', width: 7680, height: 4320);
      final av1Capability = VideoDecodeCapability.fromTrack(av1).copyWith(
        hardwareSupported: false,
      );
      final hevcCapability = VideoDecodeCapability.fromTrack(hevc).copyWith(
        hardwareSupported: true,
      );

      expect(
        tracksEligibleForPlayback(
          tracks: [av1, hevc],
          gateEightKWithHardware: true,
          decodeCapabilities: {
            av1Capability.key: av1Capability,
            hevcCapability.key: hevcCapability,
          },
        ).map((item) => item.codecs),
        ['hev1.2.4.L183.B0'],
      );
    });

    test('rejected 8K preference falls back to the highest non-8K track', () {
      final eightK = track(
        codec: 'av01.0.17M.08',
        width: 7680,
        height: 4320,
      );
      final capability = VideoDecodeCapability.fromTrack(eightK).copyWith(
        hardwareSupported: false,
        reason: 'bundled-videotoolbox-decoder-unavailable',
      );
      final fallback = highestEligibleNonEightKTrack(
        tracks: [
          eightK,
          track(
            quality: 120,
            codec: 'av01.0.12M.08',
            width: 3840,
            height: 2160,
          ),
          track(
            quality: 80,
            codec: 'avc1.640028',
            width: 1920,
            height: 1080,
          ),
        ],
        displaySupportsHdr: true,
        gateEightKWithHardware: true,
        decodeCapabilities: {capability.key: capability},
      );

      expect(fallback?.quality.code, 120);
      expect(fallback?.codecs, 'av01.0.12M.08');
    });

    test('HDR display gate remains independent from 8K decode gate', () {
      expect(
        videoQualityEligibility(
          quality: 126,
          tracks: [
            track(quality: 126, codec: 'hev1', width: 3840, height: 2160),
          ],
          displaySupportsHdr: false,
          gateEightKWithHardware: true,
          decodeCapabilities: const {},
        ).reason,
        VideoQualityIneligibility.displayHdrUnsupported,
      );
    });
  });
}
