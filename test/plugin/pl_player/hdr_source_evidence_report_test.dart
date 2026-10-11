import 'package:piliplus/plugin/pl_player/hdr_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show VideoParams;
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  const source = HdrSourceDescriptor(
    codec: 'hevc',
    transfer: 'hlg',
    primaries: 'bt.2020',
    dynamicMetadata: HdrDynamicMetadata.dolbyVision,
    dvProfile: 8,
    dvCompatibilityId: 4,
    enhancementLayer: false,
  );
  const converted = HdrRoute(
    strategy: HdrStrategy.baseLayerConvert,
    presentation: HdrPresentation.nativeHdr,
    outputTransfer: HdrOutputTransfer.pq,
    appliesDynamicMetadata: false,
    topology: HdrTopology.platformView,
    vo: 'gpu-next',
    hwdec: 'mediacodec',
    targetPrim: 'bt.2020',
    targetTrc: 'pq',
    surfaceTransfer: 'pq',
    stripDvRpu: true,
  );

  test('App label describes original DV, not the decoded PQ frame', () {
    final facts = HdrSourceFacts.fromHint(source).observe(
      dolbyVisionProfile: 8,
      dvCompatibilityId: 4,
      dvElPresent: false,
      codec: 'hevc',
      videoParams: const VideoParams(gamma: 'pq', primaries: 'bt.2020'),
      inferSourceColorFromDecoder: false,
    );
    final report = HdrOutputReport(
      source: facts.source,
      sourceFacts: facts,
      actual: converted,
      verified: true,
    );
    expect(HdrOutputSelector.routeLabel(report), '杜比视界 P8.4 · 转 PQ 输出');
    expect(HdrOutputSelector.dvProfileStatLine(report), contains('compatId=4'));
    expect(report.sourceFacts!.videoParams!.gamma, 'pq');
    expect(report.source!.transfer, 'hlg');
    expect(report.sourceFacts!.initialHint, same(source));
    expect(report.dataSpaceReadbackVerified, isFalse);
  });

  test('missing later decoder metadata cannot change App source statistics', () {
    final first = HdrSourceFacts.fromHint(source).observe(
      dolbyVisionProfile: 8,
      dvCompatibilityId: 4,
      dvElPresent: false,
      inferSourceColorFromDecoder: false,
    );
    final next = first.observe(
      videoParams: const VideoParams(gamma: 'pq'),
      inferSourceColorFromDecoder: true,
    );
    final report = HdrOutputReport(
      source: next.source,
      sourceFacts: next,
      actual: converted,
    );
    expect(HdrOutputSelector.routeLabel(report), '杜比视界 P8.4 · 转 PQ 输出');
    expect(HdrOutputSelector.dvProfileStatLine(report), contains('dvProfile=8'));
    expect(next.origins[HdrSourceField.dvProfile], HdrSourceFactOrigin.track);
    expect(next.reviewCount, 2);
    expect(first.reviewCount, 1);
  });

  test('verified review does not turn retained App hints into track facts', () {
    final facts = HdrSourceFacts.fromHint(source).observe(
      videoParams: const VideoParams(gamma: 'hlg'),
      inferSourceColorFromDecoder: true,
    );
    final report = HdrOutputReport(
      source: facts.source,
      sourceFacts: facts,
      actual: converted,
      verified: true,
    );
    expect(report.sourceFacts!.origins[HdrSourceField.dvProfile],
        HdrSourceFactOrigin.hint);
    expect(report.sourceFacts!.retainsHint, isTrue);
    expect(report.dataSpaceSetterAccepted, isFalse);
    expect(report.dataSpaceReadbackVerified, isFalse);
  });

  test('blocked conflicting source has no App success route label', () {
    final first = HdrSourceFacts.fromHint(source).observe(
      dolbyVisionProfile: 8,
      dvCompatibilityId: 4,
      inferSourceColorFromDecoder: false,
    );
    final conflict = first.observe(
      dvCompatibilityId: 1,
      inferSourceColorFromDecoder: false,
    );
    final error = HdrPlaybackBlocked(
      HdrDegradeReason.sourceMetadataUnknown,
      sourceFacts: conflict,
    );
    final report = HdrOutputReport(
      source: conflict.source,
      sourceFacts: conflict,
      error: error,
      degradeReason: error.reason,
    );
    expect(HdrOutputSelector.routeLabel(report), isNull);
    expect(report.verified, isFalse);
    expect(report.sourceFacts!.hasConflict, isTrue);
    expect(identical(error.sourceFacts, report.sourceFacts), isTrue);
  });
}
