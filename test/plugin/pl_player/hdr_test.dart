import 'dart:async';

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

  test(
    'no-op display probe does not treat native output as a display change',
    () {
      const active = HdrCapabilities(
        displayHdr: true,
        headroom: 2.03,
        potentialHeadroom: 10.15,
        nativeOutput: true,
        nativeOutputCapable: true,
        nativeOutputActive: true,
      );
      const probe = HdrCapabilities(
        displayHdr: true,
        headroom: 2.03,
        potentialHeadroom: 10.15,
      );
      expect(probe.displayStateChangedFrom(active), isFalse);
      expect(active.nativeOutputActive, isTrue);
      expect(
        const HdrCapabilities(
          displayHdr: true,
          headroom: 1,
          potentialHeadroom: 10.15,
        ).displayStateChangedFrom(active),
        isTrue,
      );
    },
  );

  test(
    'HDR transaction gate serializes same-generation interleaving',
    () async {
      final gate = HdrOutputTransactionGate();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final order = <String>[];
      var current = true;

      final first = gate.run<void>(
        isCurrent: () => current,
        action: () async {
          order.add('first-start');
          firstStarted.complete();
          await releaseFirst.future;
          order.add('first-end');
        },
      );
      await firstStarted.future;
      final second = gate.run<void>(
        isCurrent: () => current,
        action: () async => order.add('second'),
      );

      expect(order, ['first-start']);
      releaseFirst.complete();
      await Future.wait([first, second]);
      expect(order, ['first-start', 'first-end', 'second']);
    },
  );

  test(
    'HDR transaction gate drops stale completion and recovers after failure',
    () async {
      final gate = HdrOutputTransactionGate();
      var current = true;
      final release = Completer<void>();
      final stale = gate.run<String>(
        isCurrent: () => current,
        action: () async {
          await release.future;
          return 'old-surface';
        },
      );
      current = false;
      release.complete();
      expect(await stale, isNull);

      current = true;
      final failed = gate.run<void>(
        isCurrent: () => current,
        action: () async => throw StateError('native-config-failed'),
      );
      await expectLater(failed, throwsStateError);
      expect(
        await gate.run<String>(
          isCurrent: () => current,
          action: () async => 'next-surface',
        ),
        'next-surface',
      );
    },
  );

  test(
    'source operation gate makes the replacement final after overlap',
    () async {
      final gate = PlayerSourceOperationGate();
      final oldStarted = Completer<void>();
      final releaseOld = Completer<void>();
      var oldCurrent = true;
      var newCurrent = false;
      final nativeState = <String>[];

      final oldOpen = gate.run<bool>(
        isCurrent: () => oldCurrent,
        action: () async {
          oldStarted.complete();
          await releaseOld.future;
          nativeState.add('old');
          return true;
        },
      );
      await oldStarted.future;

      oldCurrent = false;
      newCurrent = true;
      final newOpen = gate.run<bool>(
        isCurrent: () => newCurrent,
        action: () async {
          nativeState.add('new');
          return true;
        },
      );

      releaseOld.complete();
      expect(await oldOpen, isNull);
      expect(await newOpen, isTrue);
      expect(nativeState, ['old', 'new']);
    },
  );

  test(
    'source operation gate skips an operation made stale before its turn',
    () async {
      final gate = PlayerSourceOperationGate();
      final releaseFirst = Completer<void>();
      var firstCurrent = true;
      var secondCurrent = true;
      var secondRan = false;

      final first = gate.run<bool>(
        isCurrent: () => firstCurrent,
        action: () async {
          await releaseFirst.future;
          return true;
        },
      );
      final second = gate.run<bool>(
        isCurrent: () => secondCurrent,
        action: () async {
          secondRan = true;
          return true;
        },
      );
      firstCurrent = false;
      secondCurrent = false;
      releaseFirst.complete();

      expect(await first, isNull);
      expect(await second, isNull);
      expect(secondRan, isFalse);
    },
  );

  test('source operation gate recovers after a failed native open', () async {
    final gate = PlayerSourceOperationGate();
    var current = true;
    final failed = gate.run<bool>(
      isCurrent: () => current,
      action: () async => throw StateError('old-open-failed'),
    );
    await expectLater(failed, throwsStateError);

    expect(
      await gate.run<bool>(
        isCurrent: () => current,
        action: () async => true,
      ),
      isTrue,
    );
  });

  test('native output attempt gate releases stale source completion only', () {
    final gate = HdrNativeOutputAttemptGate();
    final first = gate.start();
    expect(first, isNotNull);
    expect(gate.start(), isNull);

    // A replacement source waits for the dispatched old platform call, then
    // may start its own attempt once that call completes.
    gate.complete(first!);
    expect(gate.inFlight, isFalse);
    final second = gate.start();
    expect(second, isNotNull);

    // A duplicate/late completion from the first source cannot clear second.
    gate.complete(first);
    expect(gate.inFlight, isTrue);
    gate.complete(second!);
    expect(gate.inFlight, isFalse);
  });

  test(
    'output publication gate disposes a stale candidate without publishing',
    () async {
      final gate = VideoOutputPublicationGate();
      final events = <String>[];

      final published = await gate.publishOrDispose<String>(
        candidate: 'stale-output',
        isCurrent: () => false,
        publish: (candidate) => events.add('publish:$candidate'),
        dispose: (candidate) async => events.add('dispose:$candidate'),
      );

      expect(published, isFalse);
      expect(events, ['dispose:stale-output']);
    },
  );

  test(
    'output publication gate publishes a current candidate exactly once',
    () async {
      final gate = VideoOutputPublicationGate();
      final events = <String>[];

      final published = await gate.publishOrDispose<String>(
        candidate: 'current-output',
        isCurrent: () => true,
        publish: (candidate) => events.add('publish:$candidate'),
        dispose: (candidate) async => events.add('dispose:$candidate'),
      );

      expect(published, isTrue);
      expect(events, ['publish:current-output']);
    },
  );

  test(
    'lifecycle orchestrator releases a source made stale during output create',
    () async {
      final lifecycle = PlayerLifecycleOrchestrator<String, String>();
      final outputStarted = Completer<void>();
      final releaseOutput = Completer<void>();
      var current = true;
      final events = <String>[];

      final pending = lifecycle.createProbeOutputOpen(
        isCurrent: () => current,
        createPlayer: () async {
          events.add('create-player');
          return 'player-a';
        },
        probe: () async {
          events.add('probe');
          return const HdrCapabilities();
        },
        createOutput: (_, __) async {
          events.add('create-output');
          outputStarted.complete();
          await releaseOutput.future;
          return 'output-a';
        },
        disposeOutput: (output) async => events.add('dispose-output:$output'),
        disposePlayer: (player) async => events.add('dispose-player:$player'),
        publish: (_, __, ___) => events.add('publish'),
        open: (_) async => events.add('open'),
        rebindListeners: (_) => events.add('rebind'),
      );

      await outputStarted.future;
      current = false;
      releaseOutput.complete();

      final result = await pending;
      expect(result.published, isFalse);
      expect(events, [
        'create-player',
        'probe',
        'create-output',
        'dispose-output:output-a',
        'dispose-player:player-a',
      ]);
    },
  );

  test(
    'lifecycle orchestrator drops a stale codec probe before output',
    () async {
      final lifecycle = PlayerLifecycleOrchestrator<String, String>();
      final probeStarted = Completer<void>();
      final releaseProbe = Completer<void>();
      var current = true;
      final events = <String>[];

      final pending = lifecycle.createProbeOutputOpen(
        isCurrent: () => current,
        createPlayer: () async {
          events.add('create-player');
          return 'player-a';
        },
        probe: () async {
          events.add('probe');
          probeStarted.complete();
          await releaseProbe.future;
          return const HdrCapabilities(decoderHdr: true);
        },
        createOutput: (_, __) async {
          events.add('create-output');
          return 'output-a';
        },
        disposeOutput: (output) async => events.add('dispose-output:$output'),
        disposePlayer: (player) async => events.add('dispose-player:$player'),
        publish: (_, __, ___) => events.add('publish'),
        open: (_) async => events.add('open'),
        rebindListeners: (_) => events.add('rebind'),
      );

      await probeStarted.future;
      current = false;
      releaseProbe.complete();

      final result = await pending;
      expect(result.published, isFalse);
      expect(events, ['create-player', 'probe', 'dispose-player:player-a']);
    },
  );

  test(
    'lifecycle orchestrator serializes stale and replacement opens',
    () async {
      final lifecycle = PlayerLifecycleOrchestrator<String, String>();
      final oldOpenStarted = Completer<void>();
      final releaseOldOpen = Completer<void>();
      var oldCurrent = true;
      var replacementCurrent = false;
      final events = <String>[];

      final old = lifecycle.openCurrent(
        player: 'player-a',
        isCurrent: () => oldCurrent,
        open: (player) async {
          events.add('open:$player');
          oldOpenStarted.complete();
          await releaseOldOpen.future;
        },
        rebindListeners: (player) => events.add('rebind:$player'),
      );
      await oldOpenStarted.future;
      oldCurrent = false;
      replacementCurrent = true;
      final replacement = lifecycle.openCurrent(
        player: 'player-b',
        isCurrent: () => replacementCurrent,
        open: (player) async => events.add('open:$player'),
        rebindListeners: (player) => events.add('rebind:$player'),
      );

      releaseOldOpen.complete();
      expect(await old, isFalse);
      expect(await replacement, isTrue);
      expect(events, ['open:player-a', 'open:player-b', 'rebind:player-b']);
    },
  );

  test('lifecycle orchestrator invalidates before final disposal', () async {
    final lifecycle = PlayerLifecycleOrchestrator<String, String>();
    final events = <String>[];

    await lifecycle.disposeFinal(
      invalidate: () => events.add('invalidate'),
      cancelListeners: () async => events.add('cancel-listeners'),
      resetOutput: () async => events.add('reset-output'),
      disposePlayer: (player) async => events.add('dispose-player:$player'),
      player: 'player-a',
    );

    expect(events, [
      'invalidate',
      'cancel-listeners',
      'reset-output',
      'dispose-player:player-a',
    ]);
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

  test('capability map preserves current and potential display headroom', () {
    final capabilities = HdrCapabilities.fromMap({
      'platform': 'macos',
      'displayHdr': true,
      'headroom': 1.0,
      'potentialHeadroom': 10.1524076461792,
    });
    expect(capabilities.headroom, 1.0);
    expect(capabilities.potentialHeadroom, 10.1524076461792);
    expect(capabilities.canNativeHdr, isFalse);
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

  test('mpv PQ base-layer params preserve a Dolby Vision source hint', () {
    const initial = HdrSourceMetadata(
      kind: HdrSourceKind.dolbyVision,
      transfer: HdrTransfer.pq,
      primaries: HdrPrimaries.bt2020,
      dolbyVisionProfile: '8.4',
    );
    final correction = HdrSourceMetadata.fromMpvProperties({
      'codec': 'hevc',
      'primaries': 'bt.2020',
      'transfer': 'smpte2084',
      'matrix': 'bt.2020-ncl',
    });
    final merged = initial.mergeMpvCorrection(correction);
    expect(merged.kind, HdrSourceKind.dolbyVision);
    expect(merged.dolbyVisionProfile, '8.4');
    expect(merged.hasNativeColorMetadata, isTrue);
  });

  test('reliable SDR params can correct an obsolete HDR hint', () {
    const initial = HdrSourceMetadata(
      kind: HdrSourceKind.dolbyVision,
      transfer: HdrTransfer.pq,
      primaries: HdrPrimaries.bt2020,
    );
    final merged = initial.mergeMpvCorrection(
      HdrSourceMetadata.fromMpvProperties({
        'primaries': 'bt.709',
        'transfer': 'bt.1886',
        'matrix': 'bt.709',
      }),
    );
    expect(merged.kind, HdrSourceKind.sdr);
    expect(merged.transfer, HdrTransfer.sdr);
  });

  test('mpv HLG BT.2020 params preserve a Dolby Vision source hint', () {
    const initial = HdrSourceMetadata(
      kind: HdrSourceKind.dolbyVision,
      transfer: HdrTransfer.pq,
      primaries: HdrPrimaries.bt2020,
    );
    final correction = HdrSourceMetadata.fromMpvProperties({
      'transfer': 'hlg',
      'primaries': 'bt.2020',
      'matrix': 'bt.2020-ncl',
    });

    final merged = initial.mergeMpvCorrection(correction);

    expect(merged.kind, HdrSourceKind.dolbyVision);
    expect(merged.transfer, HdrTransfer.hlg);
    expect(merged.primaries, HdrPrimaries.bt2020);
    expect(merged.matrix, HdrMatrix.bt2020);
  });

  test('missing mpv booleans do not erase source metadata', () {
    const initial = HdrSourceMetadata(
      kind: HdrSourceKind.dolbyVision,
      rpuPresent: true,
      baseLayerPresent: true,
      enhancementLayerPresent: true,
      dynamicMetadataPresent: true,
      bitDepth: 10,
    );
    final correction = HdrSourceMetadata.fromMpvProperties({
      'transfer': 'smpte2084',
      'primaries': 'bt.2020',
    });
    final merged = initial.mergeMpvCorrection(correction);
    expect(merged.rpuPresent, isTrue);
    expect(merged.baseLayerPresent, isTrue);
    expect(merged.enhancementLayerPresent, isTrue);
    expect(merged.dynamicMetadataPresent, isTrue);
    expect(merged.bitDepth, 10);
  });

  test('explicit mpv false values override source metadata', () {
    const initial = HdrSourceMetadata(
      rpuPresent: true,
      baseLayerPresent: true,
      enhancementLayerPresent: true,
      dynamicMetadataPresent: true,
    );
    final correction = HdrSourceMetadata.fromMpvProperties({
      'rpu-present': 'false',
      'base-layer-present': 'absent',
      'enhancement-layer-present': '0',
      'hdr10plus-present': 'disabled',
      'bit-depth': '8',
    });
    final merged = initial.mergeMpvCorrection(correction);
    expect(merged.rpuPresent, isFalse);
    expect(merged.baseLayerPresent, isFalse);
    expect(merged.enhancementLayerPresent, isFalse);
    expect(merged.dynamicMetadataPresent, isFalse);
    expect(merged.bitDepth, 8);
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
    for (final kind in [HdrSourceKind.hdrVivid]) {
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
    final hlgDolbyVisionDecision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: const HdrSourceMetadata(
        kind: HdrSourceKind.dolbyVision,
        transfer: HdrTransfer.hlg,
        primaries: HdrPrimaries.bt2020,
      ),
      capabilities: capabilities,
    );
    expect(hlgDolbyVisionDecision.output, HdrOutputMode.nativeHdr);
    expect(hlgDolbyVisionDecision.surface, 'native-hdr');
    expect(
      hlgDolbyVisionDecision.sourceProcessing,
      'dolby-vision-converted-to-hdr',
    );
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

  test('mpv metadata records Dolby Vision layers and bit depth', () {
    final source = HdrSourceMetadata.fromMpvProperties({
      'codec': 'hevc',
      'dolby-vision-profile': '7.6',
      'transfer': 'smpte2084',
      'primaries': 'bt.2020',
      'matrix': 'bt.2020-ncl',
      'rpu-present': 'true',
      'el': 'present',
      'dv-enhancement': 'FEL',
      'bit-depth': '10',
    });
    expect(source.kind, HdrSourceKind.dolbyVision);
    expect(source.isDolbyVisionP7, isTrue);
    expect(source.requiresHdr10BaseLayerFallback, isTrue);
    expect(source.dvEnhancement, DvEnhancementType.fel);
    expect(source.rpuPresent, isTrue);
    expect(source.enhancementLayerPresent, isTrue);
    expect(source.bitDepth, 10);
  });

  test('P7 is explicitly labelled as HDR10 base-layer fallback', () {
    final decision = HdrDecision.choose(
      mode: HdrMode.auto,
      source: const HdrSourceMetadata(
        kind: HdrSourceKind.dolbyVision,
        dolbyVisionProfile: '7.6',
        transfer: HdrTransfer.pq,
        primaries: HdrPrimaries.bt2020,
        enhancementLayerPresent: true,
        dvEnhancement: DvEnhancementType.fel,
      ),
      capabilities: const HdrCapabilities(
        displayHdr: true,
        decoderHdr: true,
        nativeOutput: true,
      ),
    );
    expect(decision.output, HdrOutputMode.toneMappedSdr);
    expect(decision.reason, 'dolby-vision-p7-hdr10-bl-fallback');
  });

  test(
    'HDR10+ dynamic metadata is recorded but not treated as passthrough',
    () {
      final source = HdrSourceMetadata.fromMpvProperties({
        'transfer': 'pq',
        'primaries': 'bt2020',
        'hdr10plus-present': 'true',
        'max-cll': '1000',
      });
      expect(source.kind, HdrSourceKind.hdr10Plus);
      expect(source.dynamicMetadataPresent, isTrue);
      expect(source.masteringMetadata['max-cll'], '1000');
      final decision = HdrDecision.choose(
        mode: HdrMode.auto,
        source: source,
        capabilities: const HdrCapabilities(
          displayHdr: true,
          decoderHdr: true,
          nativeOutput: true,
        ),
      );
      expect(decision.output, HdrOutputMode.toneMappedSdr);
    },
  );
}
