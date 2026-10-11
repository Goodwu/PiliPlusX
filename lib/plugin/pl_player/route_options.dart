import 'dart:convert';

import 'package:media_kit_video/media_kit_video.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart';
import 'package:piliplus/plugin/pl_player/models/hwdec_type.dart';

enum LegacyHwdecPolicyStatus {
  disabled,
  automatic,
  hardwarePreference,
  software,
  unsupported,
}

/// Pure translation of already-read preferences. No native facts are inferred.
/// The original hwdec string remains available for diagnostics and later wiring.
class AppVideoRouteRequest {
  const AppVideoRouteRequest._({
    required this.options,
    required this.legacyHwdec,
    required this.legacyHwdecStatus,
    required this.migrationNotes,
    this.unsupportedReason,
  });

  final VideoRouteOptions options;
  final String? legacyHwdec;
  final LegacyHwdecPolicyStatus legacyHwdecStatus;
  final List<String> migrationNotes;
  final String? unsupportedReason;

  bool get hasUnsupportedLegacyRequest =>
      legacyHwdecStatus == LegacyHwdecPolicyStatus.unsupported;

  /// Unsupported legacy modes stay explicit; a caller must surface or handle
  /// this result before replacing its existing hwdec command with these options.
  factory AppVideoRouteRequest.fromPreferences({
    required HdrMode hdrMode,
    required bool enableHA,
    required String? hardwareDecoding,
    bool experimental = false,
    VideoRouteFailurePolicy failurePolicy =
        VideoRouteFailurePolicy.allowAlternatives,
  }) {
    VideoRouteSelection<VideoDecodeTarget> decode;
    LegacyHwdecPolicyStatus status;
    String? unsupportedReason;
    final migrationNotes = <String>[];
    final tokens = hardwareDecoding
        ?.split(',')
        .map((token) => token.trim())
        .toList();
    if (!enableHA) {
      decode = const VideoRouteSelection.require(VideoDecodeTarget.software);
      status = LegacyHwdecPolicyStatus.disabled;
    } else if (tokens != null && tokens.length == 1 && tokens.single == 'no') {
      decode = const VideoRouteSelection.require(VideoDecodeTarget.software);
      status = LegacyHwdecPolicyStatus.software;
    } else if (tokens != null &&
        tokens.isNotEmpty &&
        tokens.every(const {'auto', 'auto-safe', 'auto-copy'}.contains)) {
      decode = const VideoRouteSelection.prefer(VideoDecodeTarget.hardware);
      status = LegacyHwdecPolicyStatus.automatic;
      if (tokens.contains('auto-copy')) {
        migrationNotes.add(
          'Copy preference is retained in the legacy hwdec hint',
        );
      }
    } else if (tokens != null &&
        tokens.isNotEmpty &&
        tokens.every(
          (token) => HwDecType.values.any(
            (mode) => mode != HwDecType.no && mode.hwdec == token,
          ),
        )) {
      decode = const VideoRouteSelection.prefer(VideoDecodeTarget.hardware);
      status = LegacyHwdecPolicyStatus.hardwarePreference;
      migrationNotes.add(
        'Decoder names and copy/direct ordering are retained in the legacy hwdec hint',
      );
    } else {
      decode = const VideoRouteSelection.auto();
      status = LegacyHwdecPolicyStatus.unsupported;
      unsupportedReason = 'Legacy hwdec request has no route-policy mapping';
    }
    return AppVideoRouteRequest._(
      options: VideoRouteOptions(
        decode: decode,
        output: hdrMode == HdrMode.off
            ? const VideoRouteSelection.require(VideoOutputIntent.sdr)
            : const VideoRouteSelection.auto(),
        failurePolicy: failurePolicy,
        experimental: experimental,
      ),
      legacyHwdec: hardwareDecoding,
      legacyHwdecStatus: status,
      migrationNotes: List<String>.unmodifiable(migrationNotes),
      unsupportedReason: unsupportedReason,
    );
  }

  EffectiveVideoRouteOptions resolve({
    VideoRouteOptions libraryDefaults = EffectiveVideoRouteOptions.defaults,
    VideoRouteOptions openOverride = const VideoRouteOptions(),
  }) => EffectiveVideoRouteOptions.resolve(
    libraryDefaults: libraryDefaults,
    application: options,
    openOverride: openOverride,
  );

  Map<String, Object?> toMap() => Map<String, Object?>.unmodifiable({
    'requested': options.toMap(),
    'legacyHwdec': legacyHwdec,
    'legacyHwdecStatus': legacyHwdecStatus.name,
    'migrationNotes': migrationNotes,
    'unsupportedReason': unsupportedReason,
  });

  String get key => jsonEncode(toMap());

  @override
  bool operator ==(Object other) =>
      other is AppVideoRouteRequest && key == other.key;

  @override
  int get hashCode => key.hashCode;
}
