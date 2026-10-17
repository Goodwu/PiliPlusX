import 'package:media_kit_video/media_kit_video.dart'
    show VideoSourceSpec, VideoOutputTarget, EffectiveVideoRouteOptions;
import 'package:piliplus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  /// Encoded source dimensions/rate, never viewport geometry. The immutable
  /// choice travels with the URL across asynchronous Player initialization.
  final VideoSourceSpec? videoSpec;
  final VideoOutputTarget? outputTarget;
  final EffectiveVideoRouteOptions? routeOptions;

  DataSource withRouteOptions(EffectiveVideoRouteOptions options);

  DataSource({
    required this.videoSource,
    required this.audioSource,
    this.videoSpec,
    this.outputTarget,
    this.routeOptions,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
    super.videoSpec,
    super.outputTarget,
    super.routeOptions,
  });

  @override
  NetworkSource withRouteOptions(EffectiveVideoRouteOptions options) =>
      NetworkSource(
        videoSource: videoSource,
        audioSource: audioSource,
        videoSpec: videoSpec,
        outputTarget: outputTarget,
        routeOptions: options,
      );
}

class FileSource extends DataSource {
  FileSource._(
    this.dir,
    this.isMp4,
    String video,
    String? audio,
    EffectiveVideoRouteOptions options,
  ) : super(videoSource: video, audioSource: audio, routeOptions: options);

  @override
  FileSource withRouteOptions(EffectiveVideoRouteOptions options) =>
      FileSource._(dir, isMp4, videoSource, audioSource, options);
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
    super.routeOptions,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}

/// An explicitly selected local file used by the opt-in macOS playback
/// diagnostic. Unlike [FileSource], this path is not part of a Bilibili
/// download entry and has no companion audio file.
class DirectFileSource extends DataSource {
  DirectFileSource(String path, {super.routeOptions})
    : super(videoSource: path, audioSource: null);

  @override
  DirectFileSource withRouteOptions(EffectiveVideoRouteOptions options) =>
      DirectFileSource(videoSource, routeOptions: options);
}

/// True only for the explicit local-diagnostic path; ordinary files and
/// network sources must retain their normal playback side effects.
bool isLocalDiagnosticSource(DataSource source) => source is DirectFileSource;
