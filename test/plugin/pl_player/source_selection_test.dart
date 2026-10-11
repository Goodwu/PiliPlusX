import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';
import 'package:piliplus/plugin/pl_player/route_options.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' show HdrMode;
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/source_selection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const target = VideoOutputTarget.applicationView();
  VideoItem track({
    String? codec = 'hvc1.2.4.L153.B0',
    int quality = 80,
    int width = 3840,
    int height = 2160,
    String? fps = '60',
    int? bitrate = 15000000,
  }) => VideoItem(
    id: quality,
    quality: VideoQuality.fromCode(quality),
    codecs: codec,
    width: width,
    height: height,
    frameRate: fps,
    bandWidth: bitrate,
  );

  Map<String, Object?> result(
    MethodCall call, {
    String Function(Map spec)? verdict,
    List<int> hdr = const [1, 2, 3],
    String nativeSupport = 'unsupported',
    String revision = '7:2',
  }) {
    final request = call.arguments as Map;
    return {
      'schema': 1,
      'platform': 'android',
      'display': {
        'status': 'resolved',
        'platform': 'android',
        'displayId': 7,
        'modeId': 2,
        'revision': revision,
        'hdrTypes': hdr,
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
        'hevcDecoders': [],
      },
      'sources': [
        for (final Map spec in request['sources'] as List)
          {
            'key': spec['key'],
            'censusComplete': true,
            'reason': 'test',
            'decoders': [
              {
                'name': 'vendor.codec',
                'mime': 'video/hevc',
                'kind': 'hardware',
                'support': verdict?.call(spec) ?? 'supported',
                'reason': 'test',
                'path': 'codec',
              },
              {
                'name': 'vendor.dv',
                'mime': 'video/dolby-vision',
                'kind': 'hardware',
                'support': nativeSupport,
                'reason': 'test',
                'path': 'nativeDv',
              },
            ],
          },
      ],
    };
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'HDR off keeps a safe HDR source when its actual route tone-maps SDR',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => result(call, hdr: []),
      );
      final options = AppVideoRouteRequest.fromPreferences(
        hdrMode: HdrMode.off,
        enableHA: true,
        hardwareDecoding: 'mediacodec',
        android: true,
      ).resolve();
      final hdr = track(quality: 125);
      final selection = await DashRouteSelection.query(
        tracks: [hdr],
        target: target,
        options: options,
      );
      expect(selection.options, same(options));
      expect(selection.allows(hdr), true);
      expect(
        selection.prediction(hdr)!.selected.route!.outputTransfer,
        HdrOutputTransfer.sdr,
      );
      final source = NetworkSource(
        videoSource: 'https://example.invalid/hdr.mp4',
        audioSource: null,
        routeOptions: selection.options,
      );
      expect(source.routeOptions, same(options));
      expect(source.withRouteOptions(options).routeOptions, same(options));
    },
  );

  test(
    'unknown query cannot claim explicit output or software requirement',
    () {
      final options = AppVideoRouteRequest.fromPreferences(
        hdrMode: HdrMode.off,
        enableHA: false,
        hardwareDecoding: 'no',
        android: true,
      ).resolve();
      expect(
        DashRouteSelection.unknown(options: options).allows(track(quality: 80)),
        false,
      );
    },
  );

  test(
    'require HDR never authorizes an SDR source on an SDR display',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => result(call, hdr: []),
      );
      final options = EffectiveVideoRouteOptions.resolve(
        application: const VideoRouteOptions(
          output: VideoRouteSelection.require(VideoOutputIntent.hdr),
        ),
      );
      final sdr = track(quality: 80);
      final selection = await DashRouteSelection.query(
        tracks: [sdr],
        target: target,
        options: options,
      );
      expect(selection.allows(sdr), false);
    },
  );

  test('DASH specification carries encoded size, rate and bandwidth without media URL', () {
    final item = track(fps: '30000/1001');
    final spec = DashRouteSelection.specification(item)!;
    expect(spec.width, 3840);
    expect(spec.height, 2160);
    expect(spec.frameRate, closeTo(29.97002997, 0.000001));
    expect(spec.bitrate, 15000000);
    expect(spec.bitDepth, isNull);
    expect(spec.toMap().containsKey('uri'), isFalse);
  });

  test(
    'invalid or missing track facts do not manufacture a support verdict',
    () {
      expect(DashRouteSelection.specification(track(codec: null)), isNull);
      expect(DashRouteSelection.specification(track(width: -1)), isNull);
      final spec = DashRouteSelection.specification(track(fps: 'not-a-rate'))!;
      expect(spec.frameRate, isNull);
    },
  );

  test(
    'same-quality codec alternatives remain individually filtered',
    () async {
      final hevc = track();
      final av1 = track(codec: 'av01.0.13M.10');
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => result(
          call,
          verdict: (s) => (s['codec'] as String).startsWith('av01')
              ? 'unsupported'
              : 'supported',
        ),
      );
      final selection = await DashRouteSelection.query(
        tracks: [av1, hevc],
        target: target,
      );
      // This exact MediaCodec negative does not authorize any hardware route.
      // A separate FFmpeg software path remains unknown until real CPU review.
      expect(selection.prediction(av1)!.selected.route!.hwdec, 'no');
      expect(selection.decodeSupport(av1), VideoSupport.unknown);
      expect(selection.prediction(hevc)!.selected.route!.hwdec, 'mediacodec');
      final strict = await DashRouteSelection.query(
        tracks: [av1, hevc],
        target: target,
        allowUnknown: false,
      );
      expect(strict.filter([av1, hevc]), [hevc]);
      final requireHardware = await DashRouteSelection.query(
        tracks: [av1, hevc],
        target: target,
        options: EffectiveVideoRouteOptions.resolve(
          application: const VideoRouteOptions(
            decode: VideoRouteSelection.require(VideoDecodeTarget.hardware),
          ),
        ),
      );
      expect(requireHardware.filter([av1, hevc]), [hevc]);
    },
  );

  test('4K30 support cannot authorize the 4K60 rendition', () async {
    final low = track(fps: '30');
    final high = track(fps: '60');
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => result(
        call,
        verdict: (s) =>
            (s['frameRate'] as num) > 30 ? 'unsupported' : 'supported',
      ),
    );
    final selection = await DashRouteSelection.query(
      tracks: [high, low],
      target: target,
    );
    expect(selection.prediction(high)!.selected.route!.hwdec, 'no');
    expect(selection.decodeSupport(high), VideoSupport.unknown);
    expect(selection.prediction(low)!.selected.route!.hwdec, 'mediacodec');
    final strict = await DashRouteSelection.query(
      tracks: [high, low],
      target: target,
      allowUnknown: false,
    );
    expect(strict.filter([high, low]), [low]);
  });

  test('query carries explicit target and no Player', () async {
    final item = track();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['target'], {
        'kind': 'nativeDisplay',
        'platform': 'android',
        'displayId': 7,
      });
      expect(args.containsKey('player'), isFalse);
      expect(args['sources'], [
        DashRouteSelection.specification(item)!.toMap(),
      ]);
      return result(call);
    });
    final selection = await DashRouteSelection.query(
      tracks: [item],
      target: VideoOutputTarget.nativeDisplay(
        platform: 'android',
        displayId: 7,
      ),
    );
    expect(selection.allows(item), isTrue);
  });

  test('decoding support alone does not enable an HDR quality', () async {
    final hdr = track(quality: 125);
    final sdr = track();
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => result(call, hdr: []),
    );
    final selection = await DashRouteSelection.query(
      tracks: [hdr, sdr],
      target: target,
    );
    expect(selection.decodeSupport(hdr), VideoSupport.supported);
    expect(selection.allows(hdr), isFalse);
    expect(selection.allows(sdr), isTrue);
  });

  test(
    'native DV may work without the ordinary base decoder, not vice versa',
    () async {
      final dv = track(codec: 'dvh1.08.06', quality: 126);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => result(
          call,
          verdict: (_) => 'unsupported',
          nativeSupport: 'supported',
        ),
      );
      final selection = await DashRouteSelection.query(
        tracks: [dv],
        target: target,
      );
      expect(
        selection.prediction(dv)!.selected.strategy,
        HdrStrategy.nativeDolbyVision,
      );
      expect(selection.allows(dv), isTrue);
    },
  );

  test('unknown is an explicit selectable policy, not supported', () async {
    final item = track();
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => result(call, verdict: (_) => 'unknown'),
    );
    final permissive = await DashRouteSelection.query(
      tracks: [item],
      target: target,
    );
    final strict = await DashRouteSelection.query(
      tracks: [item],
      target: target,
      allowUnknown: false,
    );
    expect(permissive.decodeSupport(item), VideoSupport.unknown);
    expect(permissive.allows(item), isTrue);
    expect(strict.allows(item), isFalse);
  });

  test('query failure cannot reuse earlier HDR support', () async {
    final item = track(quality: 125);
    messenger.setMockMethodCallHandler(channel, (call) async => result(call));
    final good = await DashRouteSelection.query(tracks: [item], target: target);
    expect(good.allows(item), isTrue);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final failed = await DashRouteSelection.query(
      tracks: [item],
      target: target,
    );
    expect(failed.prediction(item), isNull);
    expect(failed.allows(item), isFalse);
    expect(await HdrOutputSelector.queryCapabilities(target: target), isNull);
  });

  test(
    'batches deduplicate equal specs and keep all distinct source results',
    () async {
      final tracks = List.generate(129, (i) => track(width: 1920 + 2 * i));
      final sizes = <int>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        sizes.add(((call.arguments as Map)['sources'] as List).length);
        return result(call);
      });
      final selection = await DashRouteSelection.query(
        tracks: [...tracks, tracks.first],
        target: target,
      );
      expect(sizes, [128, 1]);
      expect(selection.filter(tracks), tracks);
    },
  );

  test(
    'display revision drift across batches invalidates the combined snapshot',
    () async {
      final tracks = List.generate(
        129,
        (i) => track(width: 1920 + 2 * i, quality: 125),
      );
      var count = 0;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => result(call, revision: '${++count}'),
      );
      final selection = await DashRouteSelection.query(
        tracks: tracks,
        target: target,
      );
      expect(selection.prediction(tracks.first), isNull);
      expect(selection.filter(tracks), isEmpty);
    },
  );

  test(
    'selected source preserves its own specification through request objects',
    () {
      final spec = DashRouteSelection.specification(track())!;
      final request = NetworkSource(
        videoSource: 'https://example.invalid/a',
        audioSource: null,
        videoSpec: spec,
        outputTarget: target,
      );
      expect(request.videoSpec, same(spec));
      expect(request.outputTarget, same(target));
      expect(DirectFileSource('/tmp/example').videoSpec, isNull);
    },
  );
}
