import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';

void main() {
  const hdr10 = HdrSourceMetadata(
    kind: HdrSourceKind.hdr10,
    transfer: HdrTransfer.pq,
    primaries: HdrPrimaries.bt2020,
  );

  test('SDR remains SDR', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: const HdrSourceMetadata(kind: HdrSourceKind.sdr),
      capabilities: const HdrCapabilities(),
      hwdec: 'mediacodec-copy',
    );
    expect(decision.output, HdrOutputMode.sdr);
    expect(decision.hwdec, 'mediacodec-copy');
  });

  test('auto selects native HDR only with complete capability proof', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: const HdrCapabilities(
        displayHdr: true,
        decoderHdr: true,
        nativeOutput: true,
      ),
    );
    expect(decision.output, HdrOutputMode.nativeHdr);
    expect(decision.surface, 'native-hdr');
  });

  test('missing display or decoder falls back to tone-mapped SDR', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: const HdrCapabilities(
        displayHdr: true,
        decoderHdr: false,
        unsupportedReason: 'decoder-profile-not-supported',
      ),
    );
    expect(decision.output, HdrOutputMode.toneMappedSdr);
    expect(decision.reason, 'decoder-profile-not-supported');
  });

  test('incomplete HDR color metadata stays tone-mapped', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: const HdrSourceMetadata(
        kind: HdrSourceKind.unknown,
        transfer: HdrTransfer.pq,
      ),
      capabilities: const HdrCapabilities(
        displayHdr: true,
        decoderHdr: true,
        nativeOutput: true,
      ),
    );
    expect(
      const HdrSourceMetadata(
        transfer: HdrTransfer.pq,
        primaries: HdrPrimaries.bt2020,
      ).hasNativeColorMetadata,
      isTrue,
    );
    expect(
      const HdrSourceMetadata(transfer: HdrTransfer.pq).hasNativeColorMetadata,
      isFalse,
    );
    expect(decision.output, HdrOutputMode.toneMappedSdr);
    expect(decision.surface, 'texture');
  });

  test('user off always tone maps HDR', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.off,
      source: hdr10,
      capabilities: const HdrCapabilities(
        displayHdr: true,
        decoderHdr: true,
        nativeOutput: true,
      ),
    );
    expect(decision.output, HdrOutputMode.toneMappedSdr);
  });

  test('color processing changes do not change texture topology', () {
    final sdr = HdrDecision.choose(
      mode: HdrMode.auto,
      source: const HdrSourceMetadata(kind: HdrSourceKind.sdr),
      capabilities: const HdrCapabilities(),
    );
    final toneMapped = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: const HdrCapabilities(),
    );
    expect(sdr.output, HdrOutputMode.sdr);
    expect(toneMapped.output, HdrOutputMode.toneMappedSdr);
    expect(
      sdr.outputTopologySignature,
      toneMapped.outputTopologySignature,
    );
  });

  test('HCPP topology differs from texture but not from HDR activation', () {
    const pendingCapabilities = HdrCapabilities(
      androidApi: 34,
      displayHdr: true,
      decoderHdr: true,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    const activeCapabilities = HdrCapabilities(
      androidApi: 34,
      displayHdr: true,
      decoderHdr: true,
      nativeOutput: true,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    final texture = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: const HdrCapabilities(),
    );
    final pending = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: pendingCapabilities,
    );
    final active = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: activeCapabilities,
    );
    expect(
      texture.outputTopologySignature,
      isNot(pending.outputTopologySignature),
    );
    expect(pending.outputTopologySignature, active.outputTopologySignature);
  });

  test(
    'HCPP requires the decoder capability as well as display capabilities',
    () {
      const capabilities = HdrCapabilities(
        androidApi: 34,
        displayHdr: true,
        decoderHdr: false,
        nativeOutput: true,
        vulkan: true,
        platformView: true,
        hcpp: true,
      );
      expect(capabilities.canHcpp, isFalse);
    },
  );

  test('HCPP is disabled when the active display is SDR', () {
    const capabilities = HdrCapabilities(
      androidApi: 35,
      displayHdr: false,
      decoderHdr: true,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    expect(capabilities.canHcpp, isFalse);
    expect(capabilities.canNativeHdrCandidate, isFalse);
  });

  test('HCPP remains tone-mapped before dataspace proof', () {
    const capabilities = HdrCapabilities(
      androidApi: 34,
      displayHdr: true,
      decoderHdr: true,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: capabilities,
    );
    expect(capabilities.canNativeHdr, isFalse);
    expect(capabilities.canNativeHdrCandidate, isTrue);
    expect(decision.output, HdrOutputMode.toneMappedSdr);
    expect(decision.surface, 'native-hdr-candidate');
    expect(decision.useHcpp, isTrue);
  });

  test('capability diagnostics can record an HCPP initialization fallback', () {
    const capabilities = HdrCapabilities(
      androidApi: 34,
      displayHdr: true,
      decoderHdr: true,
      nativeOutput: false,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    final fallback = capabilities.copyWith(
      hcpp: false,
      unsupportedReason: 'hcpp-init-failed:PlatformException',
    );
    expect(fallback.canHcpp, isFalse);
    expect(fallback.unsupportedReason, 'hcpp-init-failed:PlatformException');
  });

  test('HCPP initialization failure forces the playable texture fallback', () {
    const capabilities = HdrCapabilities(
      androidApi: 34,
      displayHdr: true,
      decoderHdr: true,
      nativeOutput: false,
      vulkan: true,
      platformView: true,
      hcpp: false,
      unsupportedReason: 'hcpp-init-failed:PlatformException',
    );
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: hdr10,
      capabilities: capabilities,
    );
    expect(decision.output, HdrOutputMode.toneMappedSdr);
    expect(decision.surface, 'texture');
    expect(decision.useHcpp, isFalse);
    expect(decision.reason, 'hcpp-init-failed:PlatformException');
  });

  test('capability map preserves native output proof and decoder profiles', () {
    final capabilities = HdrCapabilities.fromMap({
      'platform': 'android',
      'androidApi': 35,
      'displayHdr': true,
      'decoderHdr': true,
      'nativeOutput': true,
      'vulkan': true,
      'platformView': true,
      'hcpp': true,
      'displayFormats': ['hdr10', 'hlg'],
      'decoderProfiles': ['video/hevc:profile=2'],
    });
    expect(capabilities.canNativeHdr, isTrue);
    expect(capabilities.canHcpp, isTrue);
    expect(capabilities.displayFormats, contains('hdr10'));
    expect(capabilities.decoderProfiles, contains('video/hevc:profile=2'));
  });

  test('capability state separates attemptability from active output', () {
    final capabilities = HdrCapabilities.fromMap({
      'platform': 'android',
      'nativeOutputCapable': true,
      'nativeOutputActive': false,
    });
    expect(capabilities.nativeOutputCapable, isTrue);
    expect(capabilities.nativeOutputActive, isFalse);
    expect(capabilities.canNativeHdr, isFalse);
  });

  test('active output state requires explicit capability updates', () {
    const capabilities = HdrCapabilities(
      nativeOutputCapable: true,
      nativeOutputActive: true,
      nativeOutput: true,
    );
    final reset = capabilities.copyWith(nativeOutput: false);
    expect(reset.nativeOutput, isFalse);
    expect(reset.nativeOutputCapable, isTrue);
    expect(reset.nativeOutputActive, isTrue);
    final inactive = capabilities.copyWith(
      nativeOutput: false,
      nativeOutputCapable: false,
      nativeOutputActive: false,
    );
    expect(inactive.nativeOutputActive, isFalse);
  });

  test('native output configuration serializes complete stream metadata', () {
    const config = HdrOutputConfiguration(
      transfer: HdrTransfer.pq,
      primaries: HdrPrimaries.bt2020,
      matrix: HdrMatrix.bt2020,
      codec: 'hevc',
      profile: 'main10',
      hdrType: 'hdr10',
      surfaceId: '42',
      surfaceGeneration: 4,
    );
    expect(config.toMap(), containsPair('bitDepth', 10));
    expect(config.toMap(), containsPair('surfaceGeneration', 4));
    expect(config.toMap()['transfer'], 'pq');
    expect(config.toMap()['surfaceId'], '42');
  });

  test('mpv video-params correct an initial source guess', () {
    final source = HdrSourceMetadata.fromMpvProperties({
      'codec': 'hevc',
      'primaries': 'bt.2020',
      'transfer': 'smpte2084',
      'matrix': 'bt.2020-ncl',
    });
    expect(source.kind, HdrSourceKind.hdr10);
    expect(source.isHdr, isTrue);
    expect(source.matrix, HdrMatrix.bt2020);
  });

  test('Bilibili HDR quality tiers provide an initial hint', () {
    expect(
      HdrSourceMetadata.fromBilibiliHints(quality: 125).kind,
      HdrSourceKind.hdr10,
    );
    expect(
      HdrSourceMetadata.fromBilibiliHints(quality: 126).kind,
      HdrSourceKind.dolbyVision,
    );
    expect(
      HdrSourceMetadata.fromBilibiliHints(quality: 129).kind,
      HdrSourceKind.hdrVivid,
    );
    expect(
      HdrSourceMetadata.fromBilibiliHints(quality: 80).isHdr,
      isFalse,
    );
  });

  test('matrix metadata can identify HDR when primaries are absent', () {
    final source = HdrSourceMetadata.fromMpvProperties({
      'matrix': 'bt2020-ncl',
    });
    expect(source.matrix, HdrMatrix.bt2020);
    expect(source.isHdr, isTrue);
  });

  test('HLG, Dolby Vision and HDR Vivid are classified', () {
    expect(
      HdrSourceMetadata.fromMpvProperties({
        'transfer': 'arib-std-b67',
        'primaries': 'bt.2020',
      }).kind,
      HdrSourceKind.hlg,
    );
    expect(
      HdrSourceMetadata.fromMpvProperties({'codec': 'dolby vision'}).kind,
      HdrSourceKind.dolbyVision,
    );
    expect(
      HdrSourceMetadata.fromMpvProperties({'codec': 'hdr vivid'}).kind,
      HdrSourceKind.hdrVivid,
    );
  });

  test('Dolby Vision and HDR Vivid stay tone-mapped without format proof', () {
    const capabilities = HdrCapabilities(
      androidApi: 35,
      displayHdr: true,
      decoderHdr: true,
      nativeOutput: true,
      vulkan: true,
      platformView: true,
      hcpp: true,
    );
    for (final kind in [HdrSourceKind.dolbyVision, HdrSourceKind.hdrVivid]) {
      final decision = HdrDecision.choose(
        mode: HdrMode.auto,
        source: HdrSourceMetadata(
          kind: kind,
          transfer: HdrTransfer.pq,
          primaries: HdrPrimaries.bt2020,
        ),
        capabilities: capabilities,
      );
      expect(decision.output, HdrOutputMode.toneMappedSdr);
      expect(decision.surface, 'texture');
    }
  });

  test(
    'Windows DXGI probe stays tone-mapped until native output is proven',
    () {
      final capabilities = HdrCapabilities.fromMap({
        'platform': 'windows',
        'nativeBackend': 'none',
        'displayHdr': true,
        'decoderHdr': false,
        'nativeOutput': false,
        'toneMapping': true,
        'displayFormats': ['PQ', '10-bit'],
        'unsupportedReason': 'windows-native-swapchain-not-integrated',
      });
      final decision = HdrDecision.choose(
        mode: HdrMode.auto,
        source: hdr10,
        capabilities: capabilities,
      );
      expect(capabilities.displayFormats, containsAll(['PQ', '10-bit']));
      expect(decision.output, HdrOutputMode.toneMappedSdr);
      expect(decision.reason, 'windows-native-swapchain-not-integrated');
    },
  );
}
