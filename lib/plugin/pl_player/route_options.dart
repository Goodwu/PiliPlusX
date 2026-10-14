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
/// Android copy/direct order becomes executable route policy; the original
/// hwdec string remains available to diagnose unsupported requests.
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
    bool android = false,
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
    if (android &&
        enableHA &&
        tokens != null &&
        tokens.any(
          (token) => !const {
            'no',
            'auto',
            'auto-safe',
            'auto-copy',
            'mediacodec',
            'mediacodec-copy',
          }.contains(token),
        )) {
      decode = const VideoRouteSelection.auto();
      status = LegacyHwdecPolicyStatus.unsupported;
      unsupportedReason =
          'Legacy hwdec request is unavailable in the Android route catalog';
    } else if (!enableHA) {
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
          'Copy preference is applied to the executable route catalog',
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
        android
            ? 'Copy/direct preference is applied to the executable route catalog'
            : 'Legacy decoder names remain the non-Android backend hint',
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
        importPreference: _importPreference(tokens, android: android),
        failurePolicy: failurePolicy,
      ),
      legacyHwdec: hardwareDecoding,
      legacyHwdecStatus: status,
      migrationNotes: List<String>.unmodifiable(migrationNotes),
      unsupportedReason: unsupportedReason,
    );
  }

  static VideoImportPreference _importPreference(
    List<String>? tokens, {
    required bool android,
  }) {
    // Android direct surface import（hwdec=mediacodec）依赖 MKSURF 桥的
    // owner 授权（lgExperimentOwnerToken → PlatformVideoView
    // .setLgExperimentOwner）。未授权时导入器加载失败（MKSURF: bridge not
    // initialized → Loading failed），视频帧没有合成路径，播放永久停在
    // BUFFERING 黑屏。owner/ACK/lease 拓扑接入之前，Android 一律映射为
    // preferCopy：仍是 mediacodec-copy 硬件解码，只是帧经 CPU 上传合成，
    // 不需要该桥；legacy 的 mediacodec（含默认值）表达的是"硬件解码"意图，
    // 导入方式由路由层按可执行能力落定。
    if (android) return VideoImportPreference.preferCopy;
    for (final token in tokens ?? const <String>[]) {
      if (token == 'auto-copy' || token == 'mediacodec-copy') {
        return VideoImportPreference.preferCopy;
      }
      if (token == 'mediacodec') return VideoImportPreference.preferDirect;
    }
    return VideoImportPreference.auto;
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