import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter/services.dart';

/// The macOS 8K gate is deliberately independent from HDR output capability.
/// A failed probe is not evidence that software decoding is unavailable; it
/// only prevents opening an 8K stream which requires a confirmed hardware
/// decoder on this target.
class VideoDecodeCapability {
  const VideoDecodeCapability({
    required this.codec,
    required this.width,
    required this.height,
    required this.hardwareSupported,
    this.reason,
  });

  final String codec;
  final int width;
  final int height;
  final bool? hardwareSupported;
  final String? reason;

  String get key => '$codec/$width/$height';
  bool get isEightK => width >= 7680 || height >= 4320;

  factory VideoDecodeCapability.fromTrack(VideoItem item) =>
      VideoDecodeCapability(
        codec: item.codecs ?? '',
        width: item.width ?? 0,
        height: item.height ?? 0,
        hardwareSupported: null,
      );

  VideoDecodeCapability copyWith({bool? hardwareSupported, String? reason}) =>
      VideoDecodeCapability(
        codec: codec,
        width: width,
        height: height,
        hardwareSupported: hardwareSupported ?? this.hardwareSupported,
        reason: reason ?? this.reason,
      );
}

enum VideoQualityIneligibility {
  none,
  displayHdrUnsupported,
  eightKProbePending,
  eightKProbeFailed,
  eightKHardwareUnsupported,
}

class VideoQualityEligibility {
  const VideoQualityEligibility(this.reason);

  final VideoQualityIneligibility reason;
  bool get enabled => reason == VideoQualityIneligibility.none;

  String get message => switch (reason) {
    VideoQualityIneligibility.displayHdrUnsupported => '当前显示器不支持 HDR 输出',
    VideoQualityIneligibility.eightKProbePending => '正在检测当前设备的 8K 解码能力',
    VideoQualityIneligibility.eightKProbeFailed => '无法确认当前设备的 8K 解码能力',
    VideoQualityIneligibility.eightKHardwareUnsupported => '当前设备不支持对应编码的 8K 硬解',
    VideoQualityIneligibility.none => '',
  };
}

/// `support_formats` is descriptive only. A quality is selectable or shown
/// only when the current part's DASH response actually contains its track.
List<FormatItem> formatsForCurrentDash({
  required List<FormatItem> formats,
  required List<VideoItem> tracks,
}) {
  final availableQualityIds = tracks.map((track) => track.quality.code).toSet();
  return formats
      .where((format) => format.quality != null)
      .where((format) => availableQualityIds.contains(format.quality))
      .toList();
}

VideoQualityEligibility videoQualityEligibility({
  required int quality,
  required List<VideoItem> tracks,
  required bool displaySupportsHdr,
  required bool gateEightKWithHardware,
  required Map<String, VideoDecodeCapability> decodeCapabilities,
}) {
  final isHdr = quality == 125 || quality == 126 || quality == 129;
  if (isHdr && !displaySupportsHdr) {
    return const VideoQualityEligibility(
      VideoQualityIneligibility.displayHdrUnsupported,
    );
  }
  final eightKTracks = tracks
      .where((track) => VideoDecodeCapability.fromTrack(track).isEightK)
      .toList();
  if (!gateEightKWithHardware || eightKTracks.isEmpty) {
    return const VideoQualityEligibility(VideoQualityIneligibility.none);
  }
  final capabilities = eightKTracks
      .map(VideoDecodeCapability.fromTrack)
      .map((track) => decodeCapabilities[track.key])
      .toList();
  if (capabilities.any((capability) => capability?.hardwareSupported == true)) {
    return const VideoQualityEligibility(VideoQualityIneligibility.none);
  }
  if (capabilities.any(
    (capability) =>
        capability == null ||
        (capability.hardwareSupported == null && capability.reason == null),
  )) {
    return const VideoQualityEligibility(
      VideoQualityIneligibility.eightKProbePending,
    );
  }
  if (capabilities.any((capability) => capability?.hardwareSupported == null)) {
    return const VideoQualityEligibility(
      VideoQualityIneligibility.eightKProbeFailed,
    );
  }
  return const VideoQualityEligibility(
    VideoQualityIneligibility.eightKHardwareUnsupported,
  );
}

/// Preserve software decoding below 8K, while making the actual initial/menu
/// track selection use exactly the codec proof which enabled an 8K quality.
List<VideoItem> tracksEligibleForPlayback({
  required List<VideoItem> tracks,
  required bool gateEightKWithHardware,
  required Map<String, VideoDecodeCapability> decodeCapabilities,
}) {
  if (!gateEightKWithHardware) return tracks;
  return tracks.where((track) {
    final capability = VideoDecodeCapability.fromTrack(track);
    return !capability.isEightK ||
        decodeCapabilities[capability.key]?.hardwareSupported == true;
  }).toList();
}

/// The cold-start fallback must make the same distinction as the menu: only
/// 8K needs a confirmed hardware path. Keep the highest remaining quality so
/// a rejected 8K preference does not unnecessarily drop to 1080p.
VideoItem? highestEligibleNonEightKTrack({
  required List<VideoItem> tracks,
  required bool displaySupportsHdr,
  required bool gateEightKWithHardware,
  required Map<String, VideoDecodeCapability> decodeCapabilities,
}) {
  final eligible = tracks.where((track) {
    if (VideoDecodeCapability.fromTrack(track).isEightK) return false;
    final qualityTracks = tracks
        .where((candidate) => candidate.quality.code == track.quality.code)
        .toList();
    return videoQualityEligibility(
      quality: track.quality.code,
      tracks: qualityTracks,
      displaySupportsHdr: displaySupportsHdr,
      gateEightKWithHardware: gateEightKWithHardware,
      decodeCapabilities: decodeCapabilities,
    ).enabled;
  });
  final items = eligible.toList();
  if (items.isEmpty) return null;
  return items.reduce(
    (a, b) => a.quality.code > b.quality.code ? a : b,
  );
}

/// A separate channel method keeps decode support from being accidentally
/// interpreted as `HdrCapabilities.decoderHdr`.
Future<VideoDecodeCapability> probeMacosVideoDecode(
  VideoDecodeCapability track,
) async {
  try {
    final result = await const MethodChannel('piliplusx/hdr_capabilities')
        .invokeMethod<Map<Object?, Object?>>(
          'probeVideoDecode',
          <String, Object?>{
            'codec': track.codec,
            'width': track.width,
            'height': track.height,
          },
        );
    if (result == null || result['supported'] is! bool) {
      return track.copyWith(reason: 'probe-returned-invalid-result');
    }
    return track.copyWith(
      hardwareSupported: result['supported'] as bool,
      reason: result['reason'] as String?,
    );
  } on Object catch (error) {
    return track.copyWith(reason: 'probe-failed:${error.runtimeType}');
  }
}
