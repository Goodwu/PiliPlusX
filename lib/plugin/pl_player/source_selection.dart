import 'package:PiliPlus/models/video/play/url.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:PiliPlus/plugin/pl_player/hdr_output.dart';

/// A single target/revision's source declarations. Never a process-global
/// cache. Unknown SDR inputs may be tried explicitly; unknown HDR output
/// does not advertise that the display can present HDR.
class DashRouteSelection {
  const DashRouteSelection.unknown({this.allowUnknown = true})
    : _sources = const {};
  DashRouteSelection._(
    Map<String, VideoRouteCapabilities> sources, {
    this.allowUnknown = true,
  }) : _sources = Map.unmodifiable(sources);
  final Map<String, VideoRouteCapabilities> _sources;
  final bool allowUnknown;

  bool? get displayHdr {
    if (_sources.isEmpty) return null;
    final display = _sources.values.first.display;
    return display.resolved && display.hdrTypes != null
        ? display.hdrTypes!.isNotEmpty
        : null;
  }

  static VideoSourceSpec? specification(VideoItem item) {
    final codec = item.codecs;
    if (codec == null || codec.trim().isEmpty) return null;
    try {
      return VideoSourceSpec(
        codec: codec,
        width: item.width,
        height: item.height,
        frameRate: VideoSourceSpec.parseFrameRate(item.frameRate),
        bitrate: item.bandWidth,
      );
    } on ArgumentError {
      return null; // Missing/malformed server fields are not support evidence.
    }
  }

  static Future<DashRouteSelection> query({
    required Iterable<VideoItem> tracks,
    required VideoOutputTarget target,
    bool allowUnknown = true,
  }) async {
    final specs = <String, VideoSourceSpec>{};
    for (final item in tracks) {
      final spec = specification(item);
      if (spec != null) {
        specs[spec.key] = spec;
      }
    }
    final all = specs.values.toList(growable: false);
    final sources = <String, VideoRouteCapabilities>{};
    String? displayRevision;
    // Respect the library's bounded query API, including unusually large DASH lists.
    for (var start = 0; start < all.length; start += 128) {
      final end = start + 128 < all.length ? start + 128 : all.length;
      final batch = all.sublist(start, end);
      final caps = await HdrOutputSelector.queryCapabilities(
        target: target,
        sources: batch,
      );
      if (caps == null) {
        return DashRouteSelection.unknown(allowUnknown: allowUnknown);
      }
      final revision =
          '${caps.platform}/${caps.display.status}/${caps.display.revision}';
      if (displayRevision != null && displayRevision != revision) {
        return DashRouteSelection.unknown(allowUnknown: allowUnknown);
      }
      displayRevision = revision;
      for (final spec in batch) {
        sources[spec.key] = caps;
      }
    }
    return DashRouteSelection._(sources, allowUnknown: allowUnknown);
  }

  HdrRoutePrediction? prediction(VideoItem item) {
    final spec = specification(item);
    if (spec == null) return null;
    return HdrOutputSelector.predict(
      descriptor:
          HdrOutputSelector.descriptorFromDash(
            quality: item.id,
            codec: item.codecs,
          ) ??
          const HdrSourceDescriptor(),
      specification: spec,
      capabilities: _sources[spec.key],
    );
  }

  VideoSupport decodeSupport(VideoItem item) {
    final spec = specification(item);
    if (spec == null) return VideoSupport.unknown;
    final caps = _sources[spec.key];
    final route = prediction(item)?.selected.route;
    if (caps == null || route == null) return VideoSupport.unknown;
    return caps.forHdrSource(spec).decoderSupportFor(route);
  }

  bool allows(VideoItem item) {
    final hdrTier = item.id == 125 || item.id == 126 || item.id == 129;
    final planned = prediction(item);
    if (planned == null) return allowUnknown && !hdrTier;
    if (!planned.playable) return false;
    if (hdrTier && !HdrOutputSelector.isHdrPresentable(planned)) return false;
    return allowUnknown || decodeSupport(item) == VideoSupport.supported;
  }

  List<VideoItem> filter(Iterable<VideoItem> tracks) =>
      tracks.where(allows).toList();
}
