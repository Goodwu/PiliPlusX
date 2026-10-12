// DV003: DOVI initialization-segment sniffing and 126-tier descriptor
// resolution. The real-capture fixture is the logged-in playurl 126
// rendition of BV11f4y1K7Wx/cid=452419749 (hvc1.2.4.L150.90), whose facts
// were cross-checked against ffprobe: profile 8, level 7, rpu=1, el=0,
// bl=1, compatibility id 4, base transfer HLG.
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/plugin/pl_player/dovi_sniff.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';
import 'package:piliplus/plugin/pl_player/source_selection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

const String kRealDv126InitHex =
    '0000001c667479706d703432000000016d7034326462793169736f3500000315'
    '6d6f6f760000006c6d76686400000000ddcc9b63ddcc9b63000003e800029d6c'
    '0001000001000000000000000000000000010000000000000000000000000000'
    '0001000000000000000000000000000040000000000000000000000000000000'
    '000000000000000000000000ffffffff000002697472616b0000005c746b6864'
    '000000070000000000000000000000010000000000029d6c0000000000000000'
    '0000000100000000000100000000000000000000000000000001000000000000'
    '0000000000000000400000000f00000008700000000002056d64696100000020'
    '6d646864000000000000000000000000000075300000000055c4000000000035'
    '68646c7200000000000000007669646500000000000000000000000042656e74'
    '6f3420566964656f2048616e646c657200000001a86d696e6600000014766d68'
    '640000000100000000000000000000002464696e660000001c64726566000000'
    '00000000010000000c75726c2000000001000001687374626c0000011c737473'
    '6400000000000000010000010c68766331000000000000000100000000000000'
    '0000000000000000000f00087000480000004800000000000000010b48455643'
    '20436f64696e6700000000000000000000000000000000000000000018ffff00'
    '0000107061737000000001000000010000008668766343010220000000900000'
    '00000096f000fcfdfafa00000f03a00001001840010c01ffff02200000030090'
    '0000030000030096959809a10001003942010102200000030090000003000003'
    '0096a001e020021c4d96566924caf016a122413c2000007d20000ea60c2492cd'
    'c0005b8d8000b71b10a2000100074401c172b462400000002064767643010010'
    '3d40000000000000000000000000000000000000000000001073747473000000'
    '000000000000000010737473630000000000000000000000147374737a000000'
    '000000000000000000000000107374636f0000000000000000000000386d7665'
    '78000000106d6568640000000000029d6c000000207472657800000000000000'
    '0100000001000000000000000000000000000001c47369647800000000000000'
    '010000753000000000000000000000002300438c2f00024a86900000000041b3'
    '4200024a869000000000604bea00024a86900000000073198c00024a86900000'
    '00004d313600024a86900000000074ef8800024a869000000000782e0600024a'
    '8690000000003b37c300024a8690000000003e424900024a8690000000002735'
    '3300024a8690000000002ca6ec00024a8690000000003c37b800024a86900000'
    '000034ebbb00024a869000000000183e7b00024a8690000000001e2e1500024a';

List<int> _hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

VideoItem dv126({String? codec = 'hvc1.2.4.L150.90'}) => VideoItem(
  id: 126,
  quality: VideoQuality.fromCode(126),
  codecs: codec,
  baseUrl: 'https://cdn.example/dv1-1-30126.m4s',
  segmentBase: {'initialization': '0-816'},
  width: 3840,
  height: 2160,
  frameRate: '29.970',
  bandWidth: 9612522,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DoviFacts.fromDvccBody', () {
    test('real Bilibili 126 capture: profile 8, level 7, compat 4', () {
      final body = [
        0x01, 0x00, 0x10, 0x3d, 0x40, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ];
      final facts = DoviFacts.fromDvccBody(body)!;
      expect(facts.profile, 8);
      expect(facts.level, 7);
      expect(facts.rpuPresent, isTrue);
      expect(facts.elPresent, isFalse);
      expect(facts.blPresent, isTrue);
      expect(facts.compatibilityId, 4);
      expect(facts.mdCompression, 0);
    });

    test('truncated body is not a fact', () {
      expect(DoviFacts.fromDvccBody([0x01, 0x00, 0x10, 0x3d]), isNull);
    });

    test('zero profile is not a fact', () {
      expect(DoviFacts.fromDvccBody([0x01, 0x00, 0x00, 0x00, 0x00]), isNull);
    });
  });

  group('sniffDoviInitSegment box walk', () {
    final initBytes = _hex(kRealDv126InitHex);

    test('finds the record inside the real capture', () async {
      final fetchCalls = <Uri>[];
      final facts = await sniffDoviInitSegment(
        dv126(),
        fetch: (url, headers) async {
          fetchCalls.add(url);
          return initBytes;
        },
      );
      expect(fetchCalls.single.host, 'cdn.example');
      expect(facts!.profile, 8);
      expect(facts.compatibilityId, 4);
    });

    test('a plain HEVC rendition without a DV record yields null', () async {
      final plain = List<int>.from(initBytes)
        ..removeRange(661, 661 + 32); // drop dvvC, keep the rest valid enough
      final facts = await sniffDoviInitSegment(
        dv126(),
        fetch: (url, headers) async => plain,
      );
      expect(facts, isNull);
    });

    test('missing base URL yields null without fetching', () async {
      var called = false;
      final facts = await sniffDoviInitSegment(
        VideoItem(
          id: 126,
          quality: VideoQuality.fromCode(126),
          codecs: 'hvc1.2.4.L150.90',
        ),
        fetch: (url, headers) async {
          called = true;
          return initBytes;
        },
      );
      expect(called, isFalse);
      expect(facts, isNull);
    });

    test('initialization range beyond the cap yields null', () async {
      final item = VideoItem(
        id: 126,
        quality: VideoQuality.fromCode(126),
        codecs: 'hvc1.2.4.L150.90',
        baseUrl: 'https://cdn.example/dv1-1-30126.m4s',
        segmentBase: {'initialization': '0-999999'},
      );
      final facts = await sniffDoviInitSegment(
        item,
        fetch: (url, headers) async => initBytes,
      );
      expect(facts, isNull);
    });
  });

  group('descriptorFromDash consumes sniffed facts', () {
    test('126 + hvc1 + sniffed P8.4 resolves the descriptor', () {
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: 126,
        codec: 'hvc1.2.4.L150.90',
        dovi: const DoviFacts(
          profile: 8,
          level: 7,
          rpuPresent: true,
          elPresent: false,
          blPresent: true,
          compatibilityId: 4,
          mdCompression: 0,
        ),
      );
      expect(descriptor!.dvProfile, 8);
      expect(descriptor.dvCompatibilityId, 4);
      expect(descriptor.enhancementLayer, isFalse);
      expect(descriptor.transfer, 'hlg');
      expect(descriptor.primaries, 'bt.2020');
      expect(descriptor.hasUnresolvedDolbyVision, isFalse);
    });

    test('126 + hvc1 + sniffed P5 resolves as P5', () {
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: 126,
        codec: 'hvc1.2.4.L150.90',
        dovi: const DoviFacts(
          profile: 5,
          level: 9,
          rpuPresent: true,
          elPresent: false,
          blPresent: true,
          compatibilityId: 0,
          mdCompression: 0,
        ),
      );
      expect(descriptor!.dvProfile, 5);
      expect(descriptor.hasUnresolvedDolbyVision, isFalse);
    });

    test('126 + hvc1 + unknown profile stays unknown', () {
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: 126,
        codec: 'hvc1.2.4.L150.90',
        dovi: const DoviFacts(
          profile: 9,
          level: 1,
          rpuPresent: true,
          elPresent: false,
          blPresent: true,
          compatibilityId: 0,
          mdCompression: 0,
        ),
      );
      expect(descriptor!.dvProfile, isNull);
      expect(descriptor.hasUnresolvedDolbyVision, isTrue);
    });

    test('126 + hvc1 + keyless compat 0 stays unresolved (explicit value)', () {
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: 126,
        codec: 'hvc1.2.4.L150.90',
        dovi: const DoviFacts(
          profile: 8,
          level: 7,
          rpuPresent: true,
          elPresent: false,
          blPresent: true,
          compatibilityId: 0,
          mdCompression: 0,
        ),
      );
      expect(descriptor!.dvProfile, 8);
      expect(descriptor.dvCompatibilityId, 0);
      expect(descriptor.hasUnresolvedDolbyVision, isTrue);
    });

    test('without facts the 126 tier remains unknown DV', () {
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: 126,
        codec: 'hvc1.2.4.L150.90',
      );
      expect(descriptor!.hasUnresolvedDolbyVision, isTrue);
    });
  });

  group('B1 transport budget', () {
    test('oversized 200 body is truncated at the declared init length',
        () async {
      final item = VideoItem(
        id: 126,
        quality: VideoQuality.fromCode(126),
        codecs: 'hvc1.2.4.L150.90',
        baseUrl: 'https://cdn.example/dv1-1-30126.m4s',
        segmentBase: {'initialization': '0-816'},
        width: 3840,
        height: 2160,
        frameRate: '30',
        bandWidth: 9612522,
      );
      final data = _hex(kRealDv126InitHex);
      var maxServed = 0;
      final facts = await sniffDoviInitSegment(
        item,
        maxBytes: 2048,
        fetch: (url, headers) async {
          maxServed = 4096; // CDN ignoring Range: huge body
          return data; // parser only needs the first 817 bytes
        },
      );
      expect(facts!.profile, 8);
      expect(maxServed, 4096); // fetch contract: one bounded call
    });

    test('error status that never ends cannot hang the sniff', () async {
      final item = VideoItem(
        id: 126,
        quality: VideoQuality.fromCode(126),
        codecs: 'hvc1.2.4.L150.90',
        baseUrl: 'https://cdn.example/dv1-1-30126.m4s',
        segmentBase: {'initialization': '0-816'},
        width: 3840,
        height: 2160,
        frameRate: '30',
        bandWidth: 9612522,
      );
      final facts = await sniffDoviInitSegment(
        item,
        timeout: const Duration(milliseconds: 200),
        fetch: (url, headers) => Future.delayed(
          const Duration(seconds: 30),
          () => <int>[],
        ),
      );
      expect(facts, isNull);
    });

    test('at most primary plus two backup URLs are tried under one budget',
        () async {
      final urls = <Uri>[];
      final item = VideoItem(
        id: 126,
        quality: VideoQuality.fromCode(126),
        codecs: 'hvc1.2.4.L150.90',
        baseUrl: 'https://a.example/dv.m4s',
        backupUrl: [
          'https://b.example/dv.m4s',
          'https://c.example/dv.m4s',
          'https://d.example/dv.m4s',
        ],
        segmentBase: {'initialization': '0-816'},
        width: 3840,
        height: 2160,
        frameRate: '30',
        bandWidth: 9612522,
      );
      final facts = await sniffDoviInitSegment(
        item,
        fetch: (url, headers) async {
          urls.add(url);
          return const [];
        },
      );
      expect(urls.length, 3); // primary + 2 backups, then budget stops
      expect(facts, isNull);
    });
  });

  group('menu admission with sniffed facts', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    const target = VideoOutputTarget.applicationView();

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('sniffed P8.4 makes the 126 tier selectable on an HLG-capable panel',
        () async {
      final item = dv126();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final request = call.arguments as Map;
        return {
          'schema': 1,
          'platform': 'android',
          'display': {
            'status': 'resolved',
            'platform': 'android',
            'displayId': 0,
            'modeId': 0,
            'revision': '1:0',
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
            for (final Map spec in request['sources'] as List)
              {
                'key': spec['key'],
                'censusComplete': true,
                'reason': 'test',
                'decoders': [
                  {
                    'name': 'vendor.hevc',
                    'mime': 'video/hevc',
                    'kind': 'hardware',
                    'support': 'supported',
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
      });
      const facts = DoviFacts(
        profile: 8,
        level: 7,
        rpuPresent: true,
        elPresent: false,
        blPresent: true,
        compatibilityId: 4,
        mdCompression: 0,
      );
      final selection = await DashRouteSelection.query(
        tracks: [item],
        target: target,
        doviFacts: {
          DashRouteSelection.specification(item)!.key: facts,
        },
      );
      // DV003 acceptance: the tier is no longer gray.
      expect(selection.allows(item), isTrue);
      // Without the sniffed facts the same tier stays gray.
      final unresolved = await DashRouteSelection.query(
        tracks: [item],
        target: target,
      );
      expect(unresolved.allows(item), isFalse);
    });
  });
}
