import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';

HdrRoute route(HdrStrategy strategy, HdrOutputTransfer transfer, {
  HdrMetadataHandling metadata = HdrMetadataHandling.baselineOnly,
}) => HdrRoute(
  strategy: strategy,
  presentation: transfer == HdrOutputTransfer.sdr
      ? HdrPresentation.toneMappedSdr
      : HdrPresentation.nativeHdr,
  outputTransfer: transfer,
  appliesDynamicMetadata: false,
  metadataHandling: metadata,
  topology: HdrTopology.platformView,
  vo: strategy == HdrStrategy.baseLayerDirect
      ? 'mediacodec_embed'
      : 'gpu-next',
  hwdec: 'mediacodec',
  targetPrim: null,
  targetTrc: null,
  surfaceTransfer: strategy == HdrStrategy.baseLayerConvert ? 'pq' : null,
  stripDvRpu: false,
);

HdrOutputReport report({
  required HdrSourceDescriptor source,
  required HdrRoute actual,
  HdrStrategy native = HdrStrategy.nativeHdr10Plus,
}) {
  final selected = HdrCandidate(
    strategy: actual.strategy,
    maturity: HdrStrategyMaturity.experimental,
    sourceClass: HdrSourceClass.of(source),
    stage: actual.strategy == HdrStrategy.baseLayerConvert
        ? HdrRouteStage.c4
        : HdrRouteStage.c3,
    feasible: true,
    route: actual,
  );
  final prediction = HdrRoutePrediction(
    source: source,
    selected: selected,
    candidates: [
      HdrCandidate(
        strategy: native,
        maturity: HdrStrategyMaturity.experimental,
        sourceClass: HdrSourceClass.of(source),
        stage: HdrRouteStage.c1,
        skipReason: HdrDegradeReason.routeNotImplemented,
      ),
      HdrCandidate(
        strategy: HdrStrategy.metadataReshape,
        maturity: HdrStrategyMaturity.experimental,
        sourceClass: HdrSourceClass.of(source),
        stage: HdrRouteStage.c2,
        skipReason: HdrDegradeReason.routeNotImplemented,
      ),
      selected,
    ],
    presentation: actual.presentation,
    confidence: HdrPredictionConfidence.unverified,
    playable: true,
  );
  return HdrOutputReport(
    source: source,
    prediction: prediction,
    actual: actual,
    verified: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HDR10+ C3 PQ label and diagnostics never report dynamic success', () {
    const source = HdrSourceDescriptor(
      codec: 'hevc', transfer: 'pq', primaries: 'bt.2020',
      dynamicMetadata: HdrDynamicMetadata.hdr10Plus,
    );
    final value = report(
      source: source,
      actual: route(HdrStrategy.baseLayerDirect, HdrOutputTransfer.pq),
    );
    expect(HdrOutputSelector.routeLabel(value), 'HDR10+ · 静态 PQ 兼容直出');
    expect(HdrOutputSelector.candidateFailureSummary(value),
        'c1:nativeHdr10Plus:routeNotImplemented|'
        'c2:metadataReshape:routeNotImplemented');
    final line = HdrOutputSelector.dvProfileStatLine(value);
    expect(line, contains('metadataRequest=baselineOnly'));
    expect(line, contains('metadataObserved=unknown'));
    expect(line, contains('candidateFailures=c1:nativeHdr10Plus:routeNotImplemented'));
    expect(value.metadataHandlingObserved, isNull);
  });

  test('Vivid PQ static compatibility label is not C1/C2', () {
    const source = HdrSourceDescriptor(
      codec: 'hevc', transfer: 'pq', primaries: 'bt.2020',
      dynamicMetadata: HdrDynamicMetadata.hdrVivid,
    );
    final value = report(
      source: source,
      native: HdrStrategy.nativeHdrVivid,
      actual: route(HdrStrategy.baseLayerDirect, HdrOutputTransfer.pq),
    );
    expect(HdrOutputSelector.routeLabel(value), 'HDR Vivid · 静态 PQ 兼容直出');
    expect(HdrOutputSelector.candidateFailureSummary(value),
        contains('nativeHdrVivid:routeNotImplemented'));
  });

  test('Vivid HLG and existing HLG→PQ C4 stay clearly static', () {
    const source = HdrSourceDescriptor(
      codec: 'hevc', transfer: 'hlg', primaries: 'bt.2020',
      dynamicMetadata: HdrDynamicMetadata.hdrVivid,
    );
    final direct = report(
      source: source,
      native: HdrStrategy.nativeHdrVivid,
      actual: route(HdrStrategy.baseLayerDirect, HdrOutputTransfer.hlg),
    );
    expect(HdrOutputSelector.routeLabel(direct),
        'HDR Vivid · 静态 HLG 兼容直出');
    final converted = report(
      source: source,
      native: HdrStrategy.nativeHdrVivid,
      actual: route(HdrStrategy.baseLayerConvert, HdrOutputTransfer.pq),
    );
    expect(HdrOutputSelector.routeLabel(converted),
        'HDR Vivid · HLG→PQ 静态兼容转换');
  });

  test('Fallback notice uses actual route, not an assumed SDR tone-map', () {
    final base = route(HdrStrategy.baseLayerDirect, HdrOutputTransfer.hlg);
    final pq = route(HdrStrategy.baseLayerConvert, HdrOutputTransfer.pq);
    final step = HdrDegradedEvent(
      1,
      reason: HdrDegradeReason.metadataMappingFailed,
      from: base,
      to: pq,
    );
    expect(HdrOutputSelector.degradeNotice(step),
        '已改用静态 HDR 兼容输出（metadataMappingFailed）');
    final sdr = route(HdrStrategy.toneMapSdr, HdrOutputTransfer.sdr);
    expect(
      HdrOutputSelector.degradeNotice(HdrDegradedEvent(
        1, reason: HdrDegradeReason.displayLacksTransfer, to: sdr,
      )),
      '已切换到 SDR（displayLacksTransfer）',
    );
    expect(
      HdrOutputSelector.degradeNotice(const HdrDegradedEvent(
        1, reason: HdrDegradeReason.routeOptionsUnsatisfied,
      )),
      'HDR 路由受阻（routeOptionsUnsatisfied）',
    );
  });

  test('Failed open never receives a successful static output label', () {
    const source = HdrSourceDescriptor(
      codec: 'hevc', transfer: 'pq',
      dynamicMetadata: HdrDynamicMetadata.hdr10Plus,
    );
    const blocked = HdrOutputReport(
      source: source,
      degradeReason: HdrDegradeReason.routeOptionsUnsatisfied,
    );
    expect(HdrOutputSelector.routeLabel(blocked), isNull);
    expect(HdrOutputSelector.candidateFailureSummary(blocked), 'unknown');
    expect(
      HdrOutputSelector.blockedNotice(const HdrErrorEvent(
        3, reason: HdrDegradeReason.outputBindTimeout,
      )),
      'HDR 路由失败（outputBindTimeout）',
    );
  });
}
