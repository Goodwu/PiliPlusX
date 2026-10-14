import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart';
import 'package:piliplus/plugin/pl_player/route_options.dart';

void main() {
  AppVideoRouteRequest adapt({
    HdrMode mode = HdrMode.auto,
    bool enableHA = true,
    String? hwdec = 'auto',
  }) => AppVideoRouteRequest.fromPreferences(
    hdrMode: mode,
    enableHA: enableHA,
    hardwareDecoding: hwdec,
  );

  for (final request in [
    'videotoolbox',
    'd3d11va-copy',
    'vulkan',
    'vendor-private',
  ]) {
    test('Android rejects unavailable legacy mode $request', () {
      final adapted = AppVideoRouteRequest.fromPreferences(
        hdrMode: HdrMode.auto,
        enableHA: true,
        hardwareDecoding: request,
        android: true,
      );
      expect(adapted.hasUnsupportedLegacyRequest, true);
      expect(adapted.unsupportedReason, contains('Android'));
    });
  }

  for (final entry in {
    'mediacodec-copy,mediacodec': VideoImportPreference.preferCopy,
    // Android always maps to copy import: the direct mediacodec importer
    // needs the MKSURF bridge owner authorization that this build does not
    // ship (see _importPreference). The legacy mediacodec token (including
    // the default) expresses hardware-decode intent; the executable import
    // mode is the route layer's call.
    'mediacodec,mediacodec-copy': VideoImportPreference.preferCopy,
    'auto-copy,auto-safe': VideoImportPreference.preferCopy,
    'auto-safe': VideoImportPreference.preferCopy,
    'mediacodec': VideoImportPreference.preferCopy,
  }.entries) {
    test('ordered Android legacy ${entry.key} applies import preference', () {
      final options = AppVideoRouteRequest.fromPreferences(
        hdrMode: HdrMode.auto,
        enableHA: true,
        hardwareDecoding: entry.key,
        android: true,
      ).resolve();
      expect(options.importPreference, entry.value);
      expect(
        options.origins['importPreference'],
        VideoRouteOptionOrigin.application,
      );
    });
  }

  test('HDR auto and legacy automatic decode remain preferences', () {
    final request = adapt();
    expect(request.options.output?.preference, VideoRoutePreference.auto);
    expect(request.options.decode?.preference, VideoRoutePreference.prefer);
    expect(request.options.decode?.target, VideoDecodeTarget.hardware);
    expect(request.legacyHwdecStatus, LegacyHwdecPolicyStatus.automatic);
    expect(request.legacyHwdec, 'auto');
  });

  test('Android automatic decode prefers copy import until the bridge is authorized', () {
    final androidOptions = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.auto,
      enableHA: true,
      hardwareDecoding: 'auto',
      android: true,
    ).resolve();
    expect(androidOptions.importPreference, VideoImportPreference.preferCopy);
    final otherPlatformOptions = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.auto,
      enableHA: true,
      hardwareDecoding: 'auto',
    ).resolve();
    expect(otherPlatformOptions.importPreference, VideoImportPreference.auto);
  });

  test('Android copy intent becomes a real SDR decoder/import candidate', () {
    final effective = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.auto,
      enableHA: true,
      hardwareDecoding: 'mediacodec',
      android: true,
    ).resolve();
    final caps = HdrCapabilities(
      sdkInt: 29,
      displayHdrTypes: const {2},
      hevcDecoders: const [],
      dolbyVisionDecoders: const [],
      p5PipelineAvailable: true,
      dataSpaceBridgeLoaded: true,
      dataSpaceExt: null,
    );
    final planned = HdrRoutePlanner.plan(
      source: const HdrSourceDescriptor(codec: 'hevc', transfer: 'bt.1886'),
      capabilities: caps,
      options: effective,
    );
    expect(planned.playable, isTrue);
    expect(planned.selected.route!.hwdec, 'mediacodec-copy');
    expect(planned.selected.route!.strategy, HdrStrategy.sdrDirect);
  });

  test('Require software beats Android copy import preference', () {
    final effective = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.auto,
      enableHA: false,
      hardwareDecoding: 'mediacodec',
      android: true,
    ).resolve();
    final planned = HdrRoutePlanner.plan(
      source: const HdrSourceDescriptor(codec: 'hevc', transfer: 'bt.1886'),
      capabilities: const HdrCapabilities(
        sdkInt: 29,
        displayHdrTypes: {2},
        hevcDecoders: [],
        dolbyVisionDecoders: [],
        p5PipelineAvailable: true,
        dataSpaceBridgeLoaded: true,
        dataSpaceExt: null,
      ),
      options: effective,
    );
    expect(effective.decode.isRequired, isTrue);
    expect(planned.playable, isTrue);
    expect(planned.selected.route!.hwdec, 'no');
  });

  test('HDR off requires SDR independently of any flag', () {
    final effective = adapt(mode: HdrMode.off).resolve();
    expect(effective.output.target, VideoOutputIntent.sdr);
    expect(effective.output.isRequired, true);
  });

  test('HA disabled requires software and retains legacy request', () {
    final request = adapt(enableHA: false, hwdec: 'mediacodec');
    expect(request.options.decode?.target, VideoDecodeTarget.software);
    expect(request.options.decode?.isRequired, true);
    expect(request.legacyHwdecStatus, LegacyHwdecPolicyStatus.disabled);
    expect(request.legacyHwdec, 'mediacodec');
    expect(request.hasUnsupportedLegacyRequest, false);
  });

  test('legacy no has explicit software semantics', () {
    final request = adapt(hwdec: 'no');
    expect(request.options.decode?.target, VideoDecodeTarget.software);
    expect(request.options.decode?.isRequired, true);
    expect(request.legacyHwdecStatus, LegacyHwdecPolicyStatus.software);
  });

  for (final hwdec in ['auto-safe', 'auto-copy', ' auto-safe , auto-copy ']) {
    test('automatic $hwdec never becomes require hardware', () {
      final request = adapt(hwdec: hwdec);
      expect(request.options.decode?.preference, VideoRoutePreference.prefer);
      expect(request.legacyHwdec, hwdec);
      expect(request.unsupportedReason, null);
    });
  }

  for (final hwdec in [
    'mediacodec',
    'mediacodec-copy',
    'mediacodec,auto-safe',
    'mediacodec-copy,auto-safe',
    'videotoolbox,auto',
    'd3d11va-copy,auto-safe',
  ]) {
    test(
      'known hardware request $hwdec maps preference and preserves hints',
      () {
        final request = adapt(hwdec: hwdec);
        expect(request.hasUnsupportedLegacyRequest, false);
        expect(request.options.decode?.preference, VideoRoutePreference.prefer);
        expect(request.options.decode?.target, VideoDecodeTarget.hardware);
        expect(
          request.legacyHwdecStatus,
          LegacyHwdecPolicyStatus.hardwarePreference,
        );
        expect(request.legacyHwdec, hwdec);
        expect(request.migrationNotes, isNotEmpty);
      },
    );
  }

  for (final hwdec in [
    null,
    '',
    'vendor-private',
    'auto,',
    'no,auto',
    'AUTO',
  ]) {
    test('unmapped legacy $hwdec has explicit diagnostic and auto policy', () {
      final request = adapt(hwdec: hwdec);
      expect(request.hasUnsupportedLegacyRequest, true);
      expect(request.unsupportedReason, isNotEmpty);
      expect(request.options.decode?.preference, VideoRoutePreference.auto);
      expect(request.options.decode?.target, null);
      expect(request.legacyHwdec, hwdec);
      expect(request.toMap()['legacyHwdecStatus'], 'unsupported');
    });
  }

  test('per-open automatic intent resets application requirements', () {
    final request = adapt(mode: HdrMode.off, enableHA: false);
    final effective = request.resolve(
      openOverride: const VideoRouteOptions(
        decode: VideoRouteSelection<VideoDecodeTarget>.auto(),
        output: VideoRouteSelection<VideoOutputIntent>.auto(),
      ),
    );
    expect(effective.decode.preference, VideoRoutePreference.auto);
    expect(effective.output.preference, VideoRoutePreference.auto);
    expect(effective.origins['output'], VideoRouteOptionOrigin.openOverride);
    expect(request.options.output?.isRequired, true);
  });

  test('failure stop is independent of decode and output', () {
    final request = AppVideoRouteRequest.fromPreferences(
      hdrMode: HdrMode.off,
      enableHA: false,
      hardwareDecoding: 'auto',
      failurePolicy: VideoRouteFailurePolicy.stop,
    );
    final effective = request.resolve();
    expect(effective.failurePolicy, VideoRouteFailurePolicy.stop);
    expect(effective.decode.isRequired, true);
    expect(effective.output.isRequired, true);
  });

  test('request reports are canonical, immutable and value comparable', () {
    final request = adapt(hwdec: 'mediacodec');
    final same = adapt(hwdec: 'mediacodec');
    expect(request, same);
    expect(request.hashCode, same.hashCode);
    expect(jsonDecode(request.key), request.toMap());
    expect(request, isNot(adapt(hwdec: 'mediacodec-copy')));
    final map = request.toMap();
    expect(() => map['legacyHwdec'] = 'auto', throwsUnsupportedError);
    expect(
      () => (map['requested'] as Map<String, Object?>)['failurePolicy'] =
          'stop',
      throwsUnsupportedError,
    );
    expect(() => request.migrationNotes.add('ignored'), throwsUnsupportedError);
  });
}